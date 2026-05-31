import Foundation
import CryptoKit

#if !targetEnvironment(simulator)
import OnnxRuntimeBindings
#endif

/// Adaptive ONNX Runtime model manager for AASIST-raw deepfake detection.
///
/// Automatically selects the best model based on device capabilities:
/// - High-end devices (≥6 GB RAM): AASIST-raw-base-maxdata (EER 2.63%, 686 KB)
/// - Low-end devices (<6 GB RAM):  AASIST-raw-small-distill (EER 8.0%, 351 KB)
///
/// Both models accept raw waveform input at 16kHz.
public final class ModelManager {
    public enum ModelState { case notLoaded; case loading; case loaded; case error(String) }

    public enum ModelTier: String {
        case base = "BASE"
        case small = "SMALL"

        var assetName: String {
            switch self {
            case .base:  return "aasist_raw_base_maxdata_int8"
            case .small: return "aasist_raw_small_distill_int8"
            }
        }
        var eer: Float {
            switch self {
            case .base:  return 0.0263  // 2.63% EER — upgraded 2026-05-29
            case .small: return 0.080
            }
        }
        var sizeKb: Int {
            switch self {
            case .base:  return 686
            case .small: return 351
            }
        }
    }

    public static let modelSampleRate: Int = 16000
    public static let modelInputLength: Int = 64600

    /// RAM threshold in bytes: ≥6 GB → base, otherwise → small
    private static let highEndRamThreshold: UInt64 = 6 * 1024 * 1024 * 1024

    private static let trustedHashes: [String: String] = [
        // 2.63% EER model — replaced 2026-05-29 (was 8.15% EER)
        "aasist_raw_base_maxdata_int8": "ec3468a2bbfb82f0385f3a024319424990c883363b273d734557368c8f04c78e",
        "aasist_raw_small_distill_int8": "3a675ee542eccedaf1535e8298285986b99858ebafe46caa22aa3d23aae20a0b",
    ]

    private var state: ModelState = .notLoaded

    #if !targetEnvironment(simulator)
    private var ortEnv: ORTEnv?
    private var session: ORTSession?
    #endif

    public private(set) var activeTier: ModelTier?
    public private(set) var modelIntegrityVerified = false

    public init() {}

    /// Load the optimal model based on device capabilities.
    @discardableResult
    public func loadModel() -> Bool {
        let tier = selectModelTier()
        return loadModelTier(tier)
    }

    /// Force-load a specific model tier.
    @discardableResult
    public func loadModelTier(_ tier: ModelTier) -> Bool {
        guard case .notLoaded = state else { return isLoaded() }
        state = .loading

        #if !targetEnvironment(simulator)
        guard let modelURL = Bundle.module.url(
            forResource: tier.assetName, withExtension: "onnx"
        ) else {
            state = .error("Model file not found: \(tier.assetName).onnx")
            return false
        }

        guard verifyIntegrity(at: modelURL, name: tier.assetName) else {
            state = .error("Model integrity check failed")
            return false
        }

        do {
            ortEnv = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(tier == .small ? 2 : 4)
            try options.setGraphOptimizationLevel(.all)
            // CoreML EP: Apple Neural Engine acceleration where available,
            // auto-fallback to GPU/CPU on older iPhones. Nested do/catch so an
            // append failure never blocks the CPU path.
            do {
                try options.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())
            } catch {
                // CoreML EP unavailable — continue CPU-only.
            }
            session = try ORTSession(env: ortEnv!, modelPath: modelURL.path, sessionOptions: options)
            activeTier = tier
            state = .loaded
            return true
        } catch {
            // Fallback: if base fails, try small
            if tier == .base {
                state = .notLoaded
                return loadModelTier(.small)
            }
            state = .error(error.localizedDescription)
            return false
        }
        #else
        state = .error("ONNX Runtime not available on iOS Simulator")
        return false
        #endif
    }

    /// Select model tier based on device RAM.
    private func selectModelTier() -> ModelTier {
        let totalRam = ProcessInfo.processInfo.physicalMemory
        let tier: ModelTier = totalRam >= Self.highEndRamThreshold ? .base : .small
        return tier
    }

    /// Run inference on raw waveform.
    public func runInference(waveform: [Float]) throws -> Float {
        #if !targetEnvironment(simulator)
        guard let session = session, ortEnv != nil else {
            throw NSError(domain: "ModelManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }

        let inputData = Data(bytes: waveform, count: waveform.count * MemoryLayout<Float>.size)
        let shape: [NSNumber] = [1, 1, NSNumber(value: waveform.count)]
        let inputTensor = try ORTValue(
            tensorData: NSMutableData(data: inputData),
            elementType: .float,
            shape: shape
        )

        let outputs = try session.run(
            withInputs: ["input": inputTensor],
            outputNames: ["output"],
            runOptions: nil
        )

        guard let outputTensor = outputs["output"] else {
            throw NSError(domain: "ModelManager", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No output tensor"])
        }

        let outputData = try outputTensor.tensorData() as Data
        return outputData.withUnsafeBytes { $0.load(as: Float.self) }
        #else
        throw NSError(domain: "ModelManager", code: 3,
                       userInfo: [NSLocalizedDescriptionKey: "ONNX Runtime not available on Simulator"])
        #endif
    }

    public func getState() -> ModelState { state }
    public func isLoaded() -> Bool { if case .loaded = state { return true }; return false }

    public func unloadModel() {
        #if !targetEnvironment(simulator)
        session = nil
        ortEnv = nil
        #endif
        state = .notLoaded
        activeTier = nil
        modelIntegrityVerified = false
    }

    private func verifyIntegrity(at url: URL, name: String) -> Bool {
        guard let expectedHash = Self.trustedHashes[name] else { return false }
        guard let data = try? Data(contentsOf: url) else { return false }
        let hash = sha256(data)
        modelIntegrityVerified = (hash == expectedHash)
        return modelIntegrityVerified
    }

    private func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
