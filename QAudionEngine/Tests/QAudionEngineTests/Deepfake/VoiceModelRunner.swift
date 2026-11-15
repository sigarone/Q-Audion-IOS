import Foundation
import OnnxRuntimeBindings

/// Test-only runner for the two voice models (Silero VAD and CAM++): a plain ONNX Runtime CPU session with one
/// intra-op thread and no execution provider. It belongs to the test target only, so it has no simulator gate and
/// nothing of it is compiled into the app.
final class VoiceModelRunner {
    enum RunnerError: Error {
        case tensor(String)
        case missingOutput(String)
    }

    private let env: ORTEnv
    private let session: ORTSession

    init(modelPath: String) throws {
        let newEnv = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: newEnv, modelPath: modelPath, sessionOptions: options)
        env = newEnv
    }

    static func floatTensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let byteCount = values.count * MemoryLayout<Float>.size
        guard let data = NSMutableData(length: byteCount) else {
            throw RunnerError.tensor("allocation failed")
        }
        values.withUnsafeBytes { src in
            if let base = src.baseAddress {
                memcpy(data.mutableBytes, base, byteCount)
            }
        }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    /// A rank-0 int64 tensor (the sample-rate input of Silero).
    static func int64Scalar(_ value: Int64) throws -> ORTValue {
        var copy = value
        let data = NSMutableData(bytes: &copy, length: MemoryLayout<Int64>.size)
        return try ORTValue(tensorData: data, elementType: .int64, shape: [])
    }

    /// Runs the session and returns each named float output as an array.
    func run(_ inputs: [String: ORTValue], outputs names: [String]) throws -> [String: [Float]] {
        let result = try session.run(withInputs: inputs, outputNames: Set(names), runOptions: nil)
        var floats: [String: [Float]] = [:]
        for name in names {
            guard let value = result[name] else { throw RunnerError.missingOutput(name) }
            let data = try value.tensorData() as Data
            let count = data.count / MemoryLayout<Float>.size
            let values: [Float] = data.withUnsafeBytes { raw in
                (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
            }
            floats[name] = values
        }
        return floats
    }
}

/// Silero VAD at 16 kHz: every step takes a chunk of 512 samples, prefixed by the last 64 samples of the previous
/// chunk (zeros at the start), together with the recurrent state of shape [2, 1, 128].
final class SileroStepper {
    static let chunkLength = 512
    static let historyLength = 64
    static let stateLength = 2 * 128

    private let runner: VoiceModelRunner
    private var state = [Float](repeating: 0, count: SileroStepper.stateLength)
    private var history = [Float](repeating: 0, count: SileroStepper.historyLength)

    init(runner: VoiceModelRunner) {
        self.runner = runner
    }

    func step(_ chunk: [Float]) throws -> (probability: Float, state: [Float]) {
        let input = try VoiceModelRunner.floatTensor(history + chunk, shape: [1, history.count + chunk.count])
        let stateTensor = try VoiceModelRunner.floatTensor(state, shape: [2, 1, 128])
        let rate = try VoiceModelRunner.int64Scalar(16_000)
        let out = try runner.run(["input": input, "state": stateTensor, "sr": rate], outputs: ["output", "stateN"])
        guard let probability = out["output"]?.first else { throw VoiceModelRunner.RunnerError.missingOutput("output") }
        guard let next = out["stateN"] else { throw VoiceModelRunner.RunnerError.missingOutput("stateN") }
        state = next
        history = Array(chunk.suffix(Self.historyLength))
        return (probability, next)
    }
}

/// CAM++ speaker model: input "x" of shape [1, frames, 80] (log-mel features), output "embedding".
final class CamPlusModel {
    private let runner: VoiceModelRunner

    init(runner: VoiceModelRunner) {
        self.runner = runner
    }

    func embedding(features: [[Float]]) throws -> [Float] {
        let bins = features.first?.count ?? 0
        let input = try VoiceModelRunner.floatTensor(features.flatMap { $0 }, shape: [1, features.count, bins])
        let out = try runner.run(["x": input], outputs: ["embedding"])
        guard let embedding = out["embedding"] else { throw VoiceModelRunner.RunnerError.missingOutput("embedding") }
        return embedding
    }
}
