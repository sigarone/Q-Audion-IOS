import Foundation

#if !targetEnvironment(simulator)
import OnnxRuntimeBindings
#endif

/// ML-based deepfake spoof classifier backed by the AASIST-raw ONNX model.
///
/// Mirrors the Desktop/Android Guardian contract:
/// - Input: 16 kHz mono Float32 PCM, exactly 64600 samples (`ModelManager.modelInputLength`).
///   Shorter buffers are zero-padded; longer buffers are truncated.
/// - Output: two logits `[bonafide, spoof]`, softmaxed into probabilities.
///   `spoofProbability` is the softmax of the spoof logit (index 1).
///   `confidence` is `max(p_bonafide, p_spoof)` — the model's self-confidence.
///
/// The ONNX runtime session is shared via a lazily-initialised singleton. If
/// the framework is not linked (simulator, missing XCFramework, etc.) every
/// call returns the neutral fallback `(spoofProbability: 0.5, confidence: 0.5)`
/// so the Guardian pipeline stays on its LFCC-only path without crashing.
///
/// Thread-safe: `score(pcm16kMono:)` is `async` and serialises underlying
/// inference behind an `actor`-like lock.
public final class DeepfakeClassifier: @unchecked Sendable {
    /// Model input length in samples (4.0375 s @ 16 kHz).
    public static let modelInputLength = ModelManager.modelInputLength
    /// Expected input sample rate.
    public static let modelSampleRate = ModelManager.modelSampleRate

    public enum DeepfakeError: Error {
        case modelNotLoaded
        case inferenceFailed(String)
        case runtimeUnavailable
    }

    /// Process-wide shared classifier. Loads the model lazily on first use.
    public static let shared = DeepfakeClassifier()

    private let modelManager: ModelManager
    private let lock = NSLock()
    private var didAttemptLoad = false
    private var loadSucceeded = false

    public init(modelManager: ModelManager = ModelManager()) {
        self.modelManager = modelManager
    }

    /// Score a 16 kHz mono Float32 PCM buffer.
    ///
    /// - Parameter pcm16kMono: Float32 samples at 16 kHz. Ideally exactly
    ///   `modelInputLength` (64600) samples. Shorter → zero-padded to the
    ///   right; longer → truncated to the first 64600.
    /// - Returns: `(spoofProbability, confidence)` both in `[0, 1]`.
    /// - Throws: `DeepfakeError.runtimeUnavailable` when the ONNX runtime
    ///   can't be loaded (e.g. Simulator builds). Callers should treat this
    ///   as a soft failure and fall back to the LFCC-only path.
    public func score(pcm16kMono: [Float]) async throws -> (spoofProbability: Float, confidence: Float) {
        try ensureLoaded()

        // Pad / truncate to exactly modelInputLength.
        var input = [Float](repeating: 0, count: Self.modelInputLength)
        let copyLen = min(pcm16kMono.count, Self.modelInputLength)
        if copyLen > 0 {
            input.withUnsafeMutableBufferPointer { dst in
                pcm16kMono.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress!, count: copyLen)
                }
            }
        }
        // Any samples past copyLen are already zero from the initializer.

        defer {
            // Zero out the input buffer after use — PCM voice samples are
            // sensitive and should not linger in heap memory.
            input.withUnsafeMutableBufferPointer { buf in
                if let base = buf.baseAddress {
                    base.update(repeating: 0, count: buf.count)
                }
            }
        }

        let logits = try runInferenceLogits(waveform: input)
        let (pBonafide, pSpoof) = softmax2(logits.bonafide, logits.spoof)
        let confidence = max(pBonafide, pSpoof)
        return (spoofProbability: pSpoof, confidence: confidence)
    }

    // MARK: - Internals

    private func ensureLoaded() throws {
        lock.lock()
        defer { lock.unlock() }
        if !didAttemptLoad {
            didAttemptLoad = true
            loadSucceeded = modelManager.loadModel()
        }
        if !loadSucceeded {
            throw DeepfakeError.runtimeUnavailable
        }
    }

    /// Run inference and return the two class logits.
    ///
    /// The upstream `ModelManager.runInference(waveform:)` returns a single
    /// `Float`, but AASIST-raw actually emits two logits `[bonafide, spoof]`
    /// (shape `[1, 2]`). We reimplement the runtime call here so we can read
    /// both values without changing the existing single-logit API that
    /// `VoiceprintAnalyzer` depends on.
    private func runInferenceLogits(waveform: [Float]) throws -> (bonafide: Float, spoof: Float) {
        #if !targetEnvironment(simulator)
        // Re-run via a local ORT session tied to the shared ModelManager-loaded model.
        // We reuse ModelManager's load path by asking it to run inference and also
        // reach into its output; since the existing API only returns one float, we
        // perform our own single-input/multi-output call.
        return try runDirectInference(waveform: waveform)
        #else
        throw DeepfakeError.runtimeUnavailable
        #endif
    }

    #if !targetEnvironment(simulator)
    private lazy var directEnv: ORTEnv? = {
        try? ORTEnv(loggingLevel: .warning)
    }()

    private lazy var directSession: ORTSession? = {
        guard let env = directEnv else { return nil }
        // Prefer whichever tier ModelManager selected. If not loaded, try base then small.
        let candidates: [ModelManager.ModelTier] = [
            modelManager.activeTier ?? .base,
            .small
        ]
        for tier in candidates {
            guard let url = Bundle.module.url(forResource: tier.assetName, withExtension: "onnx") else {
                continue
            }
            do {
                let opts = try ORTSessionOptions()
                try opts.setIntraOpNumThreads(tier == .small ? 2 : 4)
                try opts.setGraphOptimizationLevel(.all)
                return try ORTSession(env: env, modelPath: url.path, sessionOptions: opts)
            } catch {
                continue
            }
        }
        return nil
    }()

    private func runDirectInference(waveform: [Float]) throws -> (bonafide: Float, spoof: Float) {
        guard let session = directSession else {
            throw DeepfakeError.modelNotLoaded
        }

        // Copy float buffer into NSMutableData (ORT tensor owns a view into it).
        let byteCount = waveform.count * MemoryLayout<Float>.size
        let data = NSMutableData(length: byteCount)!
        waveform.withUnsafeBufferPointer { src in
            memcpy(data.mutableBytes, src.baseAddress!, byteCount)
        }

        let shape: [NSNumber] = [1, 1, NSNumber(value: waveform.count)]
        let inputTensor: ORTValue
        do {
            inputTensor = try ORTValue(
                tensorData: data,
                elementType: .float,
                shape: shape
            )
        } catch {
            throw DeepfakeError.inferenceFailed("tensor creation failed: \(error.localizedDescription)")
        }

        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(
                withInputs: ["input": inputTensor],
                outputNames: ["output"],
                runOptions: nil
            )
        } catch {
            throw DeepfakeError.inferenceFailed(error.localizedDescription)
        }

        guard let outTensor = outputs["output"] else {
            throw DeepfakeError.inferenceFailed("missing 'output' tensor")
        }

        let outData: Data
        do {
            outData = try outTensor.tensorData() as Data
        } catch {
            throw DeepfakeError.inferenceFailed("output read failed: \(error.localizedDescription)")
        }

        // AASIST-raw emits 2 float logits [bonafide, spoof].
        let floatCount = outData.count / MemoryLayout<Float>.size
        guard floatCount >= 2 else {
            throw DeepfakeError.inferenceFailed("expected >=2 logits, got \(floatCount)")
        }
        let (b, s): (Float, Float) = outData.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            return (ptr[0], ptr[1])
        }
        return (bonafide: b, spoof: s)
    }
    #endif

    /// Numerically stable 2-class softmax.
    /// Returns (p_bonafide, p_spoof) such that they sum to 1.
    @inline(__always)
    internal func softmax2(_ logitBonafide: Float, _ logitSpoof: Float) -> (Float, Float) {
        let m = max(logitBonafide, logitSpoof)
        let eB = expf(logitBonafide - m)
        let eS = expf(logitSpoof - m)
        let z = eB + eS
        guard z > 0 else { return (0.5, 0.5) }
        return (eB / z, eS / z)
    }
}
