import Foundation

#if !targetEnvironment(simulator)
import OnnxRuntimeBindings
#endif

/// LCNN (Light CNN) deepfake spoof detector — placeholder for Sprint 21.
///
/// **Status:** Sprint 21 ships the iOS-side API surface only. The Android
/// engine bundles `lcnn_deepfake_v1_int8.onnx` (INT8 quantised, EER ≈10.1% on
/// ASVspoof 2019 LA) under `qaudion-engine/src/main/assets/models/`. The iOS
/// engine currently bundles only the AASIST-raw artefacts; the LCNN model
/// will be deployed in Sprint 22 once the artefact has been validated against
/// the iOS ONNX Runtime build (see TODO below).
///
/// Until the model artefact lands, every detect call returns
/// `LcnnScore(score: -1.0, confidence: 0, ...)` — matching the firmware
/// convention of `-1.0f` when the NPU model is unavailable
/// (`portable/src/deepfake/npu_classifier.c`). Callers must treat
/// `score < 0` as "model unavailable" and fall back to AASIST / heuristic
/// paths without surfacing a spurious spoof alert.
///
/// Mirrors the contract of the Android `OnnxDeepfakeClassifier` (LCNN path)
/// so cross-platform `ConfidenceIndexProducer` can fuse both detector scores
/// once the model is live.
///
/// - SeeAlso: ``DeepfakeClassifier`` (AASIST-raw, primary on iOS today).
/// - SeeAlso: ``ConfidenceIndex`` (consumer of the fused score).
///
/// TODO(Sprint 22): Bundle `lcnn_deepfake_v1_int8.onnx` into
/// `QAudionEngine/Sources/QAudionEngine/Resources/`. Two deployment options:
///   1. Direct ONNX Runtime — re-use the existing
///      `onnxruntime-swift-package-manager` binding already wired up for the
///      AASIST detector. Requires the ORT mobile build to support the LCNN
///      operator set (Conv1d + GroupNorm + GLU activations); validate via
///      `ORTSession` warm-up on iPhone 14+.
///   2. Core ML conversion via `coremltools.converters.onnx` — yields ANE
///      acceleration on A14+ but adds a build-time conversion step. Defer
///      unless ONNX Runtime inference exceeds the 50 ms budget per window.
public final class LcnnDetector: @unchecked Sendable {

    // MARK: - Public types

    /// Errors surfaced from ``LcnnDetector`` initialisation and inference.
    public enum LcnnError: Error {
        /// The ONNX model file could not be located at the requested URL or
        /// inside the engine resource bundle. In Sprint 21 this is the
        /// expected state — every initialiser logs a warning and continues
        /// in unavailable mode rather than throwing, so this error is
        /// reserved for future explicit-path initialisers (e.g. a custom
        /// trained model dropped in via Files).
        case modelNotFound(String)
        /// The runtime stack (ONNX Runtime XCFramework) could not be loaded.
        /// Always raised when running under the iOS Simulator, which does
        /// not ship the ORT binary.
        case runtimeUnavailable
        /// Inference failed mid-flight (tensor allocation, session run, or
        /// output decoding). Carries the underlying description.
        case inferenceFailed(String)
    }

    /// Score returned by ``LcnnDetector/detect(audio:sampleRate:)`` and
    /// ``LcnnDetector/detect(features:)``.
    public struct LcnnScore: Sendable, Equatable {
        /// Spoof probability in `[0.0, 1.0]`, or **`-1.0`** when the model
        /// is unavailable (Sprint 21 placeholder, simulator builds, missing
        /// XCFramework). Callers MUST check `score >= 0` before fusing this
        /// into the Confidence Index.
        ///
        /// - `0.0` → bonafide / genuine speech.
        /// - `1.0` → confident deepfake / replay attack.
        /// - `-1.0` → model unavailable; ignore this detector for this
        ///   window.
        public let score: Float

        /// Model self-confidence in `[0, 1]` (typically `max(p_bonafide,
        /// p_spoof)` after softmax). `0` when the model is unavailable.
        public let confidence: Float

        /// Wall-clock inference time for the call, in milliseconds. `0`
        /// when the model is unavailable.
        public let inferenceTimeMs: Double

        /// Free-form model version tag, e.g. `"v1-int8"` or
        /// `"unavailable"`. Forwarded to the Confidence Index for
        /// telemetry / HUD display.
        public let modelVersion: String

        public init(
            score: Float,
            confidence: Float,
            inferenceTimeMs: Double,
            modelVersion: String
        ) {
            self.score = score
            self.confidence = confidence
            self.inferenceTimeMs = inferenceTimeMs
            self.modelVersion = modelVersion
        }
    }

    // MARK: - Constants

    /// Sample rate the LCNN graph expects (Hz). Matches the Android counterpart
    /// and the firmware LFCC extractor.
    public static let modelSampleRate: Int = 16_000

    /// Expected feature tensor shape per window: 60 features × 300 frames
    /// (20 LFCC + 20 Δ + 20 ΔΔ, 25 ms frame / 10 ms hop, ≈3 s window).
    /// Matches `OnnxDeepfakeClassifier.LCNN_COEFFS` × `LCNN_FRAMES` on Android.
    public static let featureCount: Int = 18_000

    /// Version label returned when the model artefact is missing. Sprint 22
    /// will swap this to `"v1-int8"` once `lcnn_deepfake_v1_int8.onnx` is
    /// bundled into the engine resources.
    public static let unavailableVersion: String = "unavailable"

    /// Resource name (sans extension) the bundle initialiser searches for.
    /// Mirrors the Android asset path `models/lcnn_deepfake_v1_int8.onnx`.
    internal static let bundledResourceName: String = "lcnn_deepfake_v1_int8"

    // MARK: - State

    /// `true` once the LCNN ONNX session has been successfully loaded.
    /// Sprint 21: always `false` — the model artefact ships in Sprint 22.
    public private(set) var modelLoaded: Bool = false

    /// Loaded model version, e.g. `"v1-int8"`. Returns
    /// ``unavailableVersion`` when ``modelLoaded`` is `false`.
    public private(set) var modelVersion: String = LcnnDetector.unavailableVersion

    private let lock = NSLock()

    // MARK: - Initialisers

    /// Load the LCNN detector from an explicit on-disk model path.
    ///
    /// In Sprint 21 the model file is not yet provisioned, so this
    /// initialiser logs a warning and constructs the detector in
    /// "unavailable" mode rather than throwing. Sprint 22 will tighten this
    /// to a hard throw when a caller-supplied URL is invalid.
    ///
    /// - Parameter modelPath: Absolute URL to a `.onnx` file produced by the
    ///   Q-Audion trainer pipeline.
    /// - Throws: ``LcnnError/runtimeUnavailable`` if the ONNX Runtime
    ///   binding is missing entirely (e.g. simulator builds). Sprint 21
    ///   does not throw ``LcnnError/modelNotFound`` — see TODO above.
    public init(modelPath: URL) throws {
        try bootstrap(modelURL: modelPath, source: "explicit path \(modelPath.lastPathComponent)")
    }

    /// Load the LCNN detector from the QAudionEngine resource bundle.
    ///
    /// In Sprint 21 the bundle does **not** include
    /// `lcnn_deepfake_v1_int8.onnx`; the initialiser succeeds in
    /// "unavailable" mode so callers can construct the detector
    /// unconditionally and the Confidence Index simply ignores its output
    /// (`score == -1.0`) until Sprint 22 deploys the artefact.
    ///
    /// Load the LCNN detector from the QAudionEngine resource bundle.
    ///
    /// - Throws: ``LcnnError/runtimeUnavailable`` on simulator builds where
    ///   the ONNX Runtime XCFramework is not linked.
    public convenience init() throws {
        try self.init(bundle: Bundle.module)
    }

    /// Load the LCNN detector from a specific bundle (for testing / custom deployments).
    ///
    /// - Parameter bundle: Bundle containing `lcnn_deepfake_v1_int8.onnx`.
    /// - Throws: ``LcnnError/runtimeUnavailable`` on simulator builds where
    ///   the ONNX Runtime XCFramework is not linked.
    public init(bundle: Bundle) throws {
        let url = bundle.url(
            forResource: LcnnDetector.bundledResourceName,
            withExtension: "onnx"
        )
        try bootstrap(modelURL: url, source: "bundle \(bundle.bundleIdentifier ?? "module")")
    }

    // MARK: - Public API

    /// Score a window of 16-bit PCM samples.
    ///
    /// Sprint 21 placeholder: always returns
    /// `LcnnScore(score: -1.0, confidence: 0, inferenceTimeMs: 0,
    /// modelVersion: "unavailable")`. Sprint 22 will resample to 16 kHz
    /// (if required), run LFCC feature extraction via ``LfccExtractor``,
    /// and invoke the ONNX session.
    ///
    /// - Parameters:
    ///   - audio: Int16 PCM samples (any sample rate; resampling is
    ///     deferred to Sprint 22).
    ///   - sampleRate: Source sample rate in Hz.
    /// - Returns: ``LcnnScore`` — caller MUST check `score >= 0` before
    ///   using it.
    public func detect(audio: [Int16], sampleRate: Int) async throws -> LcnnScore {
        // Argument-validation only — no inference path until Sprint 22.
        _ = audio
        _ = sampleRate
        return unavailableScore()
    }

    /// Score pre-extracted LFCC features (bypasses feature extraction).
    ///
    /// Sprint 21 placeholder: always returns the unavailable score. The
    /// Sprint 22 implementation will validate `features.count` against
    /// ``LcnnDetector/featureCount`` (18 000 = 60 × 300), build an
    /// `ORTValue` of shape `[1, 60, 300]`, and run the session.
    ///
    /// - Parameter features: Row-major `[coefficient, frame]` tensor —
    ///   60 features × 300 frames, flattened. Must equal
    ///   ``LcnnDetector/featureCount`` once the real model lands.
    /// - Returns: ``LcnnScore`` — caller MUST check `score >= 0`.
    public func detect(features: [Float]) async throws -> LcnnScore {
        _ = features
        return unavailableScore()
    }

    // MARK: - Internals

    /// Build the canonical "model unavailable" score. Centralised so the
    /// Sprint 22 migration only needs to touch the inference path.
    private func unavailableScore() -> LcnnScore {
        LcnnScore(
            score: -1.0,
            confidence: 0,
            inferenceTimeMs: 0,
            modelVersion: LcnnDetector.unavailableVersion
        )
    }

    /// Shared initialiser body — locates the model and updates
    /// ``modelLoaded`` / ``modelVersion``. In Sprint 21 the URL is expected
    /// to be `nil`; the warning is emitted via `Foundation.NSLog` (the iOS
    /// engine does not yet adopt `os.Logger`) and the detector stays in
    /// unavailable mode.
    private func bootstrap(modelURL: URL?, source: String) throws {
        lock.lock()
        defer { lock.unlock() }

        #if targetEnvironment(simulator)
        // ONNX Runtime XCFramework is not available on the iOS Simulator.
        // We still allow construction in unavailable mode so unit tests can
        // exercise the API surface, but flag the limitation explicitly via
        // the dedicated error so callers that *do* want a hard failure can
        // opt in.
        NSLog(
            "[LcnnDetector] runtime unavailable on simulator (source=%@); detector running in unavailable mode",
            source
        )
        modelLoaded = false
        modelVersion = LcnnDetector.unavailableVersion
        throw LcnnError.runtimeUnavailable
        #else
        guard let url = modelURL else {
            NSLog(
                "[LcnnDetector] model not bundled (source=%@); detector running in unavailable mode — Sprint 22 will deploy %@.onnx",
                source,
                LcnnDetector.bundledResourceName
            )
            modelLoaded = false
            modelVersion = LcnnDetector.unavailableVersion
            return
        }
        // Sprint 21: even if a URL is supplied, we don't open the session —
        // wiring is deferred to Sprint 22 so the ORT op-set validation can
        // be exercised under the real model artefact. The detector reports
        // unavailable so the Confidence Index ignores it.
        NSLog(
            "[LcnnDetector] model artefact located at %@ but inference disabled until Sprint 22 (source=%@)",
            url.path,
            source
        )
        modelLoaded = false
        modelVersion = LcnnDetector.unavailableVersion
        #endif
    }
}
