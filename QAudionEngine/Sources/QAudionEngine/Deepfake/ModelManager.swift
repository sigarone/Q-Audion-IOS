import Foundation
import OnnxRuntimeBindings

/// ONNX Runtime model manager for AASIST-raw deepfake detection.
///
/// Model: aasist_raw_base_int8.onnx (~755 KB)
/// Input: [1, 1, 64600] raw waveform at 16kHz
/// Output: [1, 1] binary logit (positive=bonafide, negative=spoof)
/// EER: 2.83% on ASVspoof2019 dev set
public final class ModelManager {
    public enum ModelState { case notLoaded; case loading; case loaded; case error(String) }

    public static let modelSampleRate: Int = 16000
    public static let modelInputLength: Int = 64600

    private static let modelName = "aasist_raw_base_int8"
    private static let trustedHash = "06f6d7d84e94ac40258419c440b0feda76daba63677ea098af1f88e647804ec4"

    private var state: ModelState = .notLoaded
    private var ortEnv: ORTEnv?
    private var session: ORTSession?

    public private(set) var modelIntegrityVerified = false

    public init() {}

    /// Load the ONNX model from the bundle.
    @discardableResult
    public func loadModel() -> Bool {
        guard case .notLoaded = state else { return isLoaded() }
        state = .loading

        guard let modelURL = Bundle.module.url(
            forResource: Self.modelName, withExtension: "onnx"
        ) else {
            state = .error("Model file not found in bundle")
            return false
        }

        // Verify integrity
        guard verifyIntegrity(at: modelURL) else {
            state = .error("Model integrity check failed")
            return false
        }

        do {
            ortEnv = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(4)
            try options.setGraphOptimizationLevel(.all)
            session = try ORTSession(env: ortEnv!, modelPath: modelURL.path, sessionOptions: options)
            state = .loaded
            return true
        } catch {
            state = .error(error.localizedDescription)
            return false
        }
    }

    /// Run inference on raw waveform.
    /// - Parameter waveform: Float array normalized [-1, 1], length = modelInputLength
    /// - Returns: Raw logit (positive = bonafide, negative = spoof)
    public func runInference(waveform: [Float]) throws -> Float {
        guard let session = session, let env = ortEnv else {
            throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
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
            throw NSError(domain: "ModelManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No output tensor"])
        }

        let outputData = try outputTensor.tensorData() as Data
        let logit = outputData.withUnsafeBytes { $0.load(as: Float.self) }
        return logit
    }

    public func getState() -> ModelState { state }
    public func isLoaded() -> Bool { if case .loaded = state { return true }; return false }

    public func unloadModel() {
        session = nil
        ortEnv = nil
        state = .notLoaded
        modelIntegrityVerified = false
    }

    /// Verify SHA-256 hash of model file.
    private func verifyIntegrity(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let hash = sha256(data)
        modelIntegrityVerified = (hash == Self.trustedHash)
        return modelIntegrityVerified
    }

    private func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// CommonCrypto bridge
import CommonCrypto
