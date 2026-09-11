import Foundation

/// Core deepfake detection engine using AASIST-raw model via ONNX Runtime.
///
/// Pipeline:
/// 1. PCM 16-bit → Float normalization (-1.0 to 1.0)
/// 2. Downsample 48kHz → 16kHz (factor 3, anti-alias averaging)
/// 3. Accumulate 64600 samples (~4.04s at 16kHz)
/// 4. ONNX Runtime inference → binary logit
/// 5. Sigmoid → confidence score [0.0=deepfake, 1.0=genuine]
public final class VoiceprintAnalyzer {
    private let modelManager = ModelManager()

    private static let inputSampleRate = 48000
    private static let modelSampleRate = ModelManager.modelSampleRate // 16000
    private static let downsampleFactor = inputSampleRate / modelSampleRate // 3
    private static let samplesPerFrame = 960 // 20ms at 48kHz
    private static let framesNeeded = 202 // ~4.04s at 48kHz / 20ms

    /// W-GUARDIANVAD (2026-09-11) — same normalized-float RMS threshold as
    /// `SpeakerVerifier.voiceActivityRmsThreshold` (360.0/32768.0), reused
    /// here for the identical reason: a live incident showed this badge
    /// reading 0.14 with the mic MUTED — AASIST was never trained on
    /// silence, so feeding it silence swings the score toward "not
    /// bonafide" for reasons that have nothing to do with a real deepfake.
    /// Android's `DeepfakeMonitor`/`OnnxDeepfakeClassifier` and this
    /// engine's own `ContactVoiceVerifier` (Tier 2) both gate the ENTIRE
    /// scoring tick on this same check; this class — Tier 1, a much older,
    /// single-signal pipeline — never did.
    private static let vadRmsThreshold: Float = 360.0 / 32_768.0
    /// Same calibration shape as Android's `DeepfakeMonitor.calibrate()`
    /// and this engine's own `ContactVoiceVerifier.calibrate()` — raw
    /// AASIST output for genuine speech does not cluster near 1.0 by
    /// design (live-observed on this exact model: ~0.46 for ordinary
    /// speech), so leaving it unremapped reads as alarmingly low for a
    /// perfectly genuine caller. Below `genuineFloor` is left unchanged
    /// (deepfake zone — never inflate a real attack signal); at/above it,
    /// linearly remapped to `[displayFloor, 1.0]`.
    private static let genuineFloor: Float = 0.20
    private static let displayFloor: Float = 0.95

    private var sampleBuffer: [Float]
    private var sampleCount = 0
    private let bufferLock = NSLock()

    public init() {
        sampleBuffer = [Float](repeating: 0, count: Self.samplesPerFrame * Self.framesNeeded)
        _ = modelManager.loadModel()
    }

    /// Analyze PCM frame for deepfake. Returns confidence [0.0=fake,
    /// 1.0=genuine], or `nil` when there is no real score yet (model not
    /// loaded, or the ~4s inference window hasn't filled).
    ///
    /// 2026-08-21 — this used to return a fabricated `0.5` for the "not
    /// ready" cases. The ~4s window only produces a fresh inference every
    /// ~2s (half the buffer is kept for overlap after each run, so it
    /// takes ~2s of new audio to refill); `GuardianMode` samples this every
    /// 100ms, so roughly 19 of every 20 calls landed on "not ready" and fed
    /// that fabricated 0.5 straight into `ConfidenceIndex`'s EMA (alpha
    /// 0.1) — which anchors an EMA fed mostly-0.5 close to 0.5 regardless
    /// of how high the real, infrequent inferences score. Reported live:
    /// genuine human voice held the on-screen confidence near 50 instead
    /// of the 0.7-0.99 the model is calibrated for. `nil` here, and
    /// `GuardianMode` skipping the EMA update on `nil` (mirrors
    /// `SpeakerVerifier.computeVerificationScore()`'s own established
    /// "nil, never a fabricated placeholder" discipline for the identical
    /// class of problem), fixes it at the source instead of retuning EMA
    /// constants that were never the actual defect.
    public func analyze(pcmFrame: Data) -> Float? {
        guard modelManager.isLoaded() else { return nil }

        let floatSamples = pcmBytesToFloat(pcmFrame)

        // W-GUARDIANVAD — silence/muted-mic frames contribute NOTHING: not
        // to the inference window, not to a score this tick. Mirrors the
        // "hold the last value, never fabricate/degrade on silence"
        // discipline this class's own `analyze`/`performInference` kdoc
        // already applies to the "not ready yet" and "inference failed"
        // cases — this is the same contract extended to "no real audio to
        // judge in the first place".
        guard rms(floatSamples) >= Self.vadRmsThreshold else { return nil }

        bufferLock.lock()
        let spaceLeft = sampleBuffer.count - sampleCount
        let toCopy = min(floatSamples.count, spaceLeft)
        for i in 0..<toCopy {
            sampleBuffer[sampleCount + i] = floatSamples[i]
        }
        sampleCount += toCopy
        let ready = sampleCount >= Self.samplesPerFrame * Self.framesNeeded
        bufferLock.unlock()

        guard ready else { return nil }

        let score = performInference().map(Self.calibrate)

        // Slide buffer: keep last half for overlap
        bufferLock.lock()
        let keepFrom = sampleCount / 2
        let remaining = sampleCount - keepFrom
        for i in 0..<remaining {
            sampleBuffer[i] = sampleBuffer[keepFrom + i]
        }
        sampleCount = remaining
        bufferLock.unlock()

        return score
    }

    /// Downsample 48kHz → 16kHz and run ONNX inference. `nil` on an
    /// inference error — never a fabricated placeholder, same reasoning as
    /// `analyze`'s own kdoc above.
    private func performInference() -> Float? {
        bufferLock.lock()
        let samples48k = Array(sampleBuffer[0..<sampleCount])
        bufferLock.unlock()

        // Downsample: average groups of 3
        let num16k = samples48k.count / Self.downsampleFactor
        var samples16k = [Float](repeating: 0, count: num16k)
        let factor = Float(Self.downsampleFactor)
        for i in 0..<num16k {
            let offset = i * Self.downsampleFactor
            var sum: Float = 0
            for j in 0..<Self.downsampleFactor {
                sum += samples48k[offset + j]
            }
            samples16k[i] = sum / factor
        }

        // Pad/trim to model input length
        let inputLength = ModelManager.modelInputLength
        var input = [Float](repeating: 0, count: inputLength)
        let copyLen = min(samples16k.count, inputLength)
        for i in 0..<copyLen { input[i] = samples16k[i] }

        do {
            let logit = try modelManager.runInference(waveform: input)
            return sigmoid(logit)
        } catch {
            return nil
        }
    }

    private func sigmoid(_ x: Float) -> Float {
        1.0 / (1.0 + exp(-x))
    }

    private func rms(_ pcm: [Float]) -> Float {
        guard !pcm.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for v in pcm { sumSquares += v * v }
        return (sumSquares / Float(pcm.count)).squareRoot()
    }

    /// See `genuineFloor`/`displayFloor`'s kdoc. Verbatim port of the same
    /// remap Android's `DeepfakeMonitor.calibrate()` and this engine's
    /// `ContactVoiceVerifier.calibrate()` already use.
    private static func calibrate(_ raw: Float) -> Float {
        guard raw >= genuineFloor else { return raw }
        return displayFloor + (raw - genuineFloor) / (1 - genuineFloor) * (1 - displayFloor)
    }

    private func pcmBytesToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { buf in
            let shorts = buf.bindMemory(to: Int16.self)
            for i in 0..<count {
                result[i] = Float(shorts[i]) / 32768.0
            }
        }
        return result
    }

    public func reset() {
        bufferLock.lock()
        sampleCount = 0
        bufferLock.unlock()
    }
}
