import Foundation

/// Tier 1 deepfake score of one window, using AASIST-raw via ONNX Runtime.
///
/// Pipeline (per window handed out by `GuardianWindowAccumulator`):
/// 1. 48 kHz Float window (already VAD-gated and contiguous) → 16 kHz (factor 3, averaging)
/// 2. Pad/trim to the model's 64 600 samples (~4.04 s)
/// 3. ONNX Runtime inference → logit → sigmoid
/// 4. `calibrate` → confidence [0.0 = deepfake, 1.0 = genuine]
///
/// W-GUARDIAN1CONTIG (2026-10-07) — accumulation and the VAD gate moved to `GuardianWindowAccumulator`, and the
/// call to `score` moved off the RX analysis queue onto `GuardianMode`'s own inference queue (one job in
/// flight). This class only scores. It is used from that one serial queue, never concurrently, which is what
/// the `@unchecked Sendable` relies on.
public final class VoiceprintAnalyzer: @unchecked Sendable {
    private let modelManager = ModelManager()

    private static let downsampleFactor = 48_000 / ModelManager.modelSampleRate // 3

    /// Same calibration shape as Android's `DeepfakeMonitor.calibrate()` and this engine's own
    /// `ContactVoiceVerifier.calibrate()` — raw AASIST output for genuine speech does not cluster near 1.0 by
    /// design (live-observed on this exact model: ~0.46 for ordinary speech), so leaving it unremapped reads as
    /// alarmingly low for a perfectly genuine caller. Below `genuineFloor` is left unchanged (deepfake zone —
    /// never inflate a real attack signal); at/above it, linearly remapped to `[displayFloor, 1.0]`.
    private static let genuineFloor: Float = 0.20
    private static let displayFloor: Float = 0.95

    public init() {
        _ = modelManager.loadModel()
    }

    /// Confidence [0.0 = fake, 1.0 = genuine] for one 48 kHz window, or `nil` when there is no real score:
    /// model not loaded (always the case on the Simulator) or an inference error. Never a fabricated
    /// placeholder — `GuardianMode` skips the EMA update on `nil` (2026-08-21: a placeholder 0.5 used to anchor
    /// the EMA near 0.5 for genuine voice).
    public func score(window48k: [Float]) -> Float? {
        guard modelManager.isLoaded() else { return nil }

        let factor = Self.downsampleFactor
        let inputLength = ModelManager.modelInputLength
        var input = [Float](repeating: 0, count: inputLength)
        let available = min(window48k.count / factor, inputLength)
        let scale = 1 / Float(factor)
        for i in 0..<available {
            let offset = i * factor
            var sum: Float = 0
            for j in 0..<factor { sum += window48k[offset + j] }
            input[i] = sum * scale
        }

        do {
            let logit = try modelManager.runInference(waveform: input)
            return Self.calibrate(1.0 / (1.0 + exp(-logit)))
        } catch {
            return nil
        }
    }

    /// See `genuineFloor`/`displayFloor`'s doc. Verbatim port of the same remap Android's
    /// `DeepfakeMonitor.calibrate()` and this engine's `ContactVoiceVerifier.calibrate()` already use.
    static func calibrate(_ raw: Float) -> Float {
        guard raw >= genuineFloor else { return raw }
        return displayFloor + (raw - genuineFloor) / (1 - genuineFloor) * (1 - displayFloor)
    }
}
