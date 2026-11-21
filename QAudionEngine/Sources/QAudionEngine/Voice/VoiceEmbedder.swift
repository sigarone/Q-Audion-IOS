import Foundation
import OnnxRuntimeBindings

/// Fixed shape of the speaker model's input and output.
enum VoiceEmbedderShape {
    static let dim = 512
    static let mel = 80
    static let frames = 400
}

/// Why the embedder refused its input.
enum VoiceEmbedderError: Error, Equatable {
    /// The input did not hold exactly 400 x 80 values.
    case badInputLength(Int)
}

/// The raw `embedding` output of the speaker model (512 floats) and its Euclidean norm (float64).
struct RawEmbedding {
    let raw: [Float]
    let norm: Double

    /// e = raw / norm: the division in float64, rounded once to float32.
    func unit() -> [Float] {
        VoiceMath.unit(raw, norm: norm)
    }
}

/// Runs the speaker model on one window of fbank features.
protocol VoiceEmbedder: AnyObject {
    /// The raw embedding of `fbank`, 400 x 80 float32 row major after CMN. Exactly 400 x 80: the shipped graph is right only
    /// at 200 k frames, so any other length throws `VoiceEmbedderError.badInputLength`. Returns nil when the model fails or
    /// its output is not 512 finite values with a norm above zero: the window is then not scored, never a zero vector.
    func embed(fbank: [Float]) throws -> RawEmbedding?
}

/// The speaker model on ONNX Runtime for the contact-voice engine: CPU execution provider only (no execution provider is
/// appended), one intra-op thread, sequential execution (the default; the inter-op pool stays unused), the options the
/// tolerance of the stored vectors was measured with. The model file is hashed against the pin before the runtime sees it.
///
/// It is a session of its own and not the one of the owner-voice path: that one appends the CoreML provider and uses two
/// threads, and sharing would force one of the two paths to change. The cost is a second copy of the graph in memory while a
/// call is verified. Runs are serialised by a lock that `close()` also takes, so a close never frees the session under a run.
final class OrtCamPlusEmbedder: VoiceEmbedder, @unchecked Sendable {
    /// Attempts to create the session before the model is reported unavailable (a transient failure, low memory).
    static let loadAttempts = 3
    static let inputName = "x"
    static let outputName = "embedding"

    /// Creates the runtime environment and the session of a verified model file.
    typealias SessionOpener = (URL) throws -> (ORTEnv, ORTSession)

    private let lock = NSLock()
    private var env: ORTEnv?
    private var session: ORTSession?

    private init(env: ORTEnv, session: ORTSession) {
        self.env = env
        self.session = session
    }

    /// Checks the file against `expectedSha256` and opens the session, retrying a failed creation up to `attempts` times (a
    /// hash mismatch is permanent and is not retried). Throws `VoiceBundleError` when the model is not usable: the engine
    /// then reports Cannot verify (model).
    static func load(
        modelURL: URL,
        expectedSha256: String,
        attempts: Int = OrtCamPlusEmbedder.loadAttempts,
        opener: SessionOpener = OrtCamPlusEmbedder.openSession
    ) throws -> OrtCamPlusEmbedder {
        guard attempts >= 1 else { throw VoiceBundleError.malformed("embedder model: attempts") }
        let data: Data
        do {
            data = try Data(contentsOf: modelURL)
        } catch {
            throw VoiceBundleError.missingFile(modelURL.lastPathComponent)
        }
        guard VoiceHash.sha256Hex(data) == expectedSha256.lowercased() else {
            throw VoiceBundleError.hashMismatch("embedder model")
        }
        for _ in 0..<attempts {
            if let pair = try? opener(modelURL) {
                return OrtCamPlusEmbedder(env: pair.0, session: pair.1)
            }
        }
        throw VoiceBundleError.malformed("embedder model: cannot be loaded")
    }

    static func openSession(at url: URL) throws -> (ORTEnv, ORTSession) {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        let session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
        return (env, session)
    }

    func embed(fbank: [Float]) throws -> RawEmbedding? {
        guard fbank.count == VoiceEmbedderShape.frames * VoiceEmbedderShape.mel else {
            throw VoiceEmbedderError.badInputLength(fbank.count)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let session = session else { return nil }
        do {
            let byteCount = fbank.count * MemoryLayout<Float>.size
            guard let data = NSMutableData(length: byteCount) else { return nil }
            fbank.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    memcpy(data.mutableBytes, base, byteCount)
                }
            }
            let shape: [NSNumber] = [1, NSNumber(value: VoiceEmbedderShape.frames), NSNumber(value: VoiceEmbedderShape.mel)]
            let input = try ORTValue(tensorData: data, elementType: .float, shape: shape)
            let result = try session.run(
                withInputs: [Self.inputName: input],
                outputNames: Set([Self.outputName]),
                runOptions: nil
            )
            guard let output = result[Self.outputName] else { return nil }
            let out = try output.tensorData() as Data
            guard out.count == VoiceEmbedderShape.dim * MemoryLayout<Float>.size else { return nil }
            let raw: [Float] = out.withUnsafeBytes { buffer in
                (0..<VoiceEmbedderShape.dim).map {
                    buffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
                }
            }
            return VoiceMath.rawEmbedding(raw)
        } catch {
            // A runtime error: no window, never a made-up vector.
            return nil
        }
    }

    /// Takes the run lock: a close never frees the session under a run that is still inside `embed`. Afterwards `embed`
    /// returns nil.
    func close() {
        lock.lock()
        session = nil
        env = nil
        lock.unlock()
    }
}

/// Vector helpers shared by the embedder, the scorer and the tests; pure.
enum VoiceMath {
    /// The raw vector and its float64 Euclidean norm, or nil when a value is not finite or the norm is not above zero.
    static func rawEmbedding(_ raw: [Float]) -> RawEmbedding? {
        var sum = 0.0
        for v in raw {
            guard v.isFinite else { return nil }
            sum += Double(v) * Double(v)
        }
        let norm = sum.squareRoot()
        return norm > 0 && norm.isFinite ? RawEmbedding(raw: raw, norm: norm) : nil
    }

    /// raw / norm, divided in float64 and rounded once to float32.
    static func unit(_ raw: [Float], norm: Double) -> [Float] {
        raw.map { Float(Double($0) / norm) }
    }

    /// The float64 Euclidean norm of a float32 vector.
    static func norm(_ v: [Float]) -> Double {
        var s = 0.0
        for x in v { s += Double(x) * Double(x) }
        return s.squareRoot()
    }
}
