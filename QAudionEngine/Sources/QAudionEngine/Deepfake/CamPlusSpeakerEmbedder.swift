import Foundation
import CryptoKit

#if !targetEnvironment(simulator)
import OnnxRuntimeBindings
#endif

/// ONNX Runtime-backed speaker-embedding extractor — CAM++ (Alibaba
/// 3D-Speaker / ModelScope, Apache-2.0), the model behind the "voce remota"
/// (per-contact) and "voce storica" (owner Voice-as-Key) continuity shields.
///
/// 2026-08-01 iOS port of the already-shipped Android integration
/// (`qaudion-engine/.../deepfake/CamPlusSpeakerEmbedder.kt`). REPLACES the
/// classical LFCC-mean embedding `SpeakerVerifier` used before (128-dim,
/// arithmetic mean of stacked per-frame LFCC vectors, L2-normalized) — the
/// same category of classical statistical embedding Android's own real-device
/// test proved unable to reliably distinguish two related speakers.
///
/// Follows `ModelManager`'s exact asset-loading/integrity/session pattern
/// (SPM `.copy()` resource, `Bundle.module` lookup, SHA-256-pinned
/// `trustedHashes`-style check, `ORTEnv`/`ORTSessionOptions`, CoreML EP
/// appended in a non-fatal nested `do`/`catch`, gated
/// `#if !targetEnvironment(simulator)`) — SAME asset Android already uses
/// (`campplus_sv_voxceleb_16k.onnx`, identical SHA-256), loaded through the
/// same generic `ORTSession` API, no CoreML `.mlmodel` conversion needed.
///
/// Thread-safety: mirrors `DeepfakeClassifier`'s pattern exactly — an
/// `NSLock` guards only the cheap "is the session loaded" state, never the
/// expensive `session.run()` call itself. This is deliberate and load-bearing:
/// the Android port hit TWO confirmed real-device regressions (call audio
/// blocking, deepfake-UI freezing) from an earlier version that held a lock
/// across ONNX inference while a differently-dispatched caller needed the
/// same lock — never repeat that here. `embed(pcm16kMono:)` may be called
/// concurrently from multiple callers (Tier-1 TX-side owner-continuity AND
/// Tier-2 RX-side per-contact verification both share this ONE instance);
/// `ORTSession.run()` is documented thread-safe for concurrent invocation
/// (microsoft/onnxruntime#114) so no additional external serialization is
/// added around it — only around session (re)load.
public final class CamPlusSpeakerEmbedder: @unchecked Sendable {
    public static let embeddingDimension = 512

    public enum CamPlusError: Error {
        case modelNotLoaded
        case inferenceFailed(String)
        case runtimeUnavailable
        case integrityCheckFailed
    }

    /// Process-wide shared embedder — Tier 1 (Voice-as-Key/owner-continuity)
    /// and Tier 2 (per-contact verification) both inject THIS instance,
    /// never construct their own. A second independently-loaded session
    /// would double the ~30MB resident model footprint for no benefit — the
    /// exact "processing weight / overload" outcome the Android port was
    /// explicitly asked to avoid when it grew a second Tier-1 consumer.
    public static let shared = CamPlusSpeakerEmbedder()

    private static let modelAssetName = "campplus_sv_voxceleb_16k"

    /// SHA-256 of the model asset — SAME file, SAME hash Android pinned
    /// (`CamPlusSpeakerEmbedder.kt`'s `TRUSTED_HASH`), computed at Android
    /// integration time (2026-07-31) from github.com/k2-fsa/sherpa-onnx's
    /// "speaker-recongition-models" release. Any mismatch (corrupted asset,
    /// tampered build) refuses to load rather than silently running an
    /// unverified model.
    private static let trustedHash = "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"

    private let fbank = KaldiFbankExtractor()
    private let lock = NSLock()
    private var didAttemptLoad = false
    private var loadSucceeded = false
    public private(set) var integrityVerified = false

    /// The model's real ONNX input name — confirmed via `onnx.load()`
    /// inspection of this exact asset at Android integration time
    /// (2026-07-31): input `"x"` shape `[N, T, 80]`, output `"embedding"`
    /// shape `[batch, 512]`. Hardcoded (not introspected at load time via an
    /// `ORTSession` API) to match this codebase's own established pattern —
    /// `ModelManager`/`DeepfakeClassifier` both hardcode fixed
    /// `"input"`/`"output"` literals rather than querying session metadata;
    /// no session-introspection API is used anywhere else in this repo, and
    /// this file cannot be compiled/verified on the machine that wrote it
    /// (no Xcode), so it deliberately does not introduce an unverified one.
    private static let inputName = "x"

    #if !targetEnvironment(simulator)
    private var ortEnv: ORTEnv?
    private var session: ORTSession?
    #endif

    public init() {}

    /// Compute an L2-normalized 512-dim CAM++ speaker embedding from PCM
    /// already at `KaldiFbankExtractor.sampleRate` (16kHz) — resample BEFORE
    /// calling this, same contract as the Android `embed(pcm16k:)`.
    ///
    /// Expensive — callers MUST throttle their own call cadence (never
    /// per-audio-frame); see `SpeakerVerifier`'s continuous-verification
    /// wiring for the throttled cadence this is designed for.
    public func embed(pcm16kMono: [Float]) throws -> [Float] {
        try ensureLoaded()

        let frames = fbank.extract(pcm16kMono)
        guard !frames.isEmpty else {
            throw CamPlusError.inferenceFailed("fbank extraction produced zero frames (input too short)")
        }

        #if !targetEnvironment(simulator)
        guard let session = session else {
            throw CamPlusError.modelNotLoaded
        }

        let numFrames = frames.count
        let numMel = frames[0].count
        var flat = [Float](repeating: 0, count: numFrames * numMel)
        for t in 0..<numFrames {
            for m in 0..<numMel {
                flat[t * numMel + m] = frames[t][m]
            }
        }

        let byteCount = flat.count * MemoryLayout<Float>.size
        guard let data = NSMutableData(length: byteCount) else {
            throw CamPlusError.inferenceFailed("tensor buffer allocation failed")
        }
        flat.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            memcpy(data.mutableBytes, base, byteCount)
        }

        let shape: [NSNumber] = [1, NSNumber(value: numFrames), NSNumber(value: numMel)]
        let inputTensor: ORTValue
        do {
            inputTensor = try ORTValue(tensorData: data, elementType: .float, shape: shape)
        } catch {
            throw CamPlusError.inferenceFailed("tensor creation failed: \(error.localizedDescription)")
        }

        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(
                withInputs: [Self.inputName: inputTensor],
                outputNames: ["embedding"],
                runOptions: nil
            )
        } catch {
            throw CamPlusError.inferenceFailed(error.localizedDescription)
        }

        guard let outTensor = outputs["embedding"] else {
            throw CamPlusError.inferenceFailed("missing 'embedding' output tensor")
        }

        let outData: Data
        do {
            outData = try outTensor.tensorData() as Data
        } catch {
            throw CamPlusError.inferenceFailed("output read failed: \(error.localizedDescription)")
        }

        let floatCount = outData.count / MemoryLayout<Float>.size
        guard floatCount >= Self.embeddingDimension else {
            throw CamPlusError.inferenceFailed("expected \(Self.embeddingDimension) dims, got \(floatCount)")
        }
        var embedding = [Float](repeating: 0, count: Self.embeddingDimension)
        outData.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            for i in 0..<Self.embeddingDimension { embedding[i] = ptr[i] }
        }
        return l2Normalize(embedding)
        #else
        throw CamPlusError.runtimeUnavailable
        #endif
    }

    // MARK: - Internals

    private func ensureLoaded() throws {
        lock.lock()
        defer { lock.unlock() }
        if !didAttemptLoad {
            didAttemptLoad = true
            loadSucceeded = loadModel()
        }
        if !loadSucceeded {
            throw CamPlusError.runtimeUnavailable
        }
    }

    /// MUST be called with `lock` held (only from `ensureLoaded`).
    private func loadModel() -> Bool {
        #if !targetEnvironment(simulator)
        guard let modelURL = Bundle.module.url(forResource: Self.modelAssetName, withExtension: "onnx") else {
            return false
        }
        guard let data = try? Data(contentsOf: modelURL) else { return false }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        integrityVerified = (hex == Self.trustedHash)
        guard integrityVerified else { return false }

        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            try options.setGraphOptimizationLevel(.all)
            // CoreML EP: routes eligible ops to the Apple Neural Engine;
            // unsupported ops fall back to CPU automatically within the same
            // session (standard ORT partitioning behavior) — nested
            // do/catch so an append failure (no CoreML EP in this runtime
            // build, older device, etc.) never blocks the CPU-only path.
            do {
                try options.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())
            } catch {
                // CoreML EP unavailable — continue CPU-only.
            }
            let newSession = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            ortEnv = env
            session = newSession
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sqrt(sumSq)
        guard norm > 1e-9 else { return v }
        return v.map { $0 / norm }
    }
}
