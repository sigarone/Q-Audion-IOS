import Foundation
import OnnxRuntimeBindings

/// Silero VAD on ONNX Runtime's CPU execution provider with one intra-op thread (no other provider is appended, and the
/// sequential execution mode leaves the inter-op pool unused). Each step takes 512 samples prefixed with the last 64
/// samples of the previous chunk, plus the recurrent state of shape [2, 1, 128].
final class SileroVadRunner: VoiceVadModel {
    enum RunnerError: Error {
        case tensor(String)
        case missingOutput(String)
    }

    static let stateLength = 2 * 128

    private let env: ORTEnv
    private let session: ORTSession
    private var state = [Float](repeating: 0, count: SileroVadRunner.stateLength)
    private var context = [Float](repeating: 0, count: SileroVadContext.length)

    /// Creates the session from the (already verified) model file.
    init(modelURL: URL) throws {
        let newEnv = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: newEnv, modelPath: modelURL.path, sessionOptions: options)
        env = newEnv
    }

    func reset() {
        for i in 0..<state.count {
            state[i] = 0
        }
        for i in 0..<context.count {
            context[i] = 0
        }
    }

    func step(_ chunk: [Float]) throws -> Float {
        let input = try Self.floatTensor(context + chunk, shape: [1, context.count + chunk.count])
        let stateTensor = try Self.floatTensor(state, shape: [2, 1, 128])
        let rate = try Self.int64Scalar(16_000)
        let result = try session.run(
            withInputs: ["input": input, "state": stateTensor, "sr": rate],
            outputNames: Set(["output", "stateN"]),
            runOptions: nil
        )
        guard let outputValue = result["output"] else { throw RunnerError.missingOutput("output") }
        guard let stateValue = result["stateN"] else { throw RunnerError.missingOutput("stateN") }
        let probabilities = try Self.floats(outputValue)
        let nextState = try Self.floats(stateValue)
        guard let probability = probabilities.first else { throw RunnerError.missingOutput("output") }
        guard nextState.count == state.count else { throw RunnerError.missingOutput("stateN") }
        state = nextState
        context = Array(chunk.suffix(SileroVadContext.length))
        return probability
    }

    private static func floatTensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
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

    /// A rank-0 int64 tensor (the sample-rate input).
    private static func int64Scalar(_ value: Int64) throws -> ORTValue {
        var copy = value
        let data = NSMutableData(bytes: &copy, length: MemoryLayout<Int64>.size)
        return try ORTValue(tensorData: data, elementType: .int64, shape: [])
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
    }
}
