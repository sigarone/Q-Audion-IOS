import XCTest
import CryptoKit
@testable import QAudionEngine

/// One real ONNX Runtime inference per voice model, on whatever runtime the test job runs on (the iOS Simulator in CI).
/// Silero VAD (MIT, see Resources/voice/silero_vad_LICENSE.txt) and CAM++ are both read from the copies the app bundle
/// already carries (QAudionEngine/Sources/QAudionEngine/Resources), so neither is duplicated.
final class VoiceModelRunnerTests: XCTestCase {

    private static let sileroSha256 = "7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49"
    private static let camPlusSha256 = "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"

    /// Three tones at 220, 1100 and 3300 Hz, sampled at 16 kHz.
    private static func testSignal(count: Int) -> [Float] {
        let twoPi: Double = 2 * Double.pi
        var samples = [Float]()
        samples.reserveCapacity(count)
        for n in 0..<count {
            let t: Double = Double(n) / 16_000.0
            let low: Double = 0.30 * sin(twoPi * 220 * t)
            let mid: Double = 0.20 * sin(twoPi * 1100 * t)
            let high: Double = 0.10 * sin(twoPi * 3300 * t)
            samples.append(Float(low + mid + high))
        }
        return samples
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// The engine's own resource folder, found from this source file (the tests already read repository files by path).
    private func engineResource(_ name: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("Sources/QAudionEngine/Resources/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("\(name) not found next to the test sources")
        throw CocoaError(.fileNoSuchFile)
    }

    func testSileroRunsEightChunks() throws {
        let url = try engineResource("voice/silero_vad_16k_op15.onnx")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(sha256Hex(bytes), Self.sileroSha256)

        let loadStart = Date()
        let runner = try VoiceModelRunner(modelPath: url.path)
        let loadMs = milliseconds(since: loadStart)
        let silero = SileroStepper(runner: runner)

        let chunks = 8
        let signal = Self.testSignal(count: chunks * SileroStepper.chunkLength)
        var probabilities: [Float] = []
        let runStart = Date()
        for k in 0..<chunks {
            let lower = k * SileroStepper.chunkLength
            let result = try silero.step(Array(signal[lower..<(lower + SileroStepper.chunkLength)]))
            XCTAssertTrue(result.probability.isFinite, "chunk \(k)")
            XCTAssertGreaterThanOrEqual(result.probability, 0, "chunk \(k)")
            XCTAssertLessThanOrEqual(result.probability, 1, "chunk \(k)")
            XCTAssertEqual(result.state.count, SileroStepper.stateLength, "chunk \(k)")
            XCTAssertTrue(result.state.allSatisfy { $0.isFinite }, "chunk \(k)")
            probabilities.append(result.probability)
        }

        // Probabilities for this signal: equal to six digits on onnxruntime 1.24.2 (arm64 simulator) and an x86 reference run.
        let golden: [Float] = [0.04029283, 0.029173732, 0.013520926, 0.004807234, 0.0052649975, 0.0036943853, 0.0026042461, 0.002551645]
        XCTAssertEqual(probabilities.count, golden.count)
        for (k, expected) in golden.enumerated() where k < probabilities.count {
            XCTAssertEqual(probabilities[k], expected, accuracy: 1e-3, "chunk \(k)")
        }
        print("voice-model-runner silero load_ms=\(loadMs) run_ms=\(milliseconds(since: runStart)) p=\(probabilities)")
    }

    func testCamPlusEmbedsTwoSeconds() throws {
        let url = try engineResource("campplus_sv_voxceleb_16k.onnx")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(sha256Hex(bytes), Self.camPlusSha256)

        let loadStart = Date()
        let runner = try VoiceModelRunner(modelPath: url.path)
        let loadMs = milliseconds(since: loadStart)

        let signal = Self.testSignal(count: 2 * KaldiFbankExtractor.sampleRate)
        let frames = KaldiFbankExtractor().extract(signal)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertEqual(frames.first?.count, KaldiFbankExtractor.numMelBins)

        let runStart = Date()
        let embedding = try CamPlusModel(runner: runner).embedding(features: frames)
        let runMs = milliseconds(since: runStart)

        XCTAssertEqual(embedding.count, CamPlusSpeakerEmbedder.embeddingDimension)
        XCTAssertTrue(embedding.allSatisfy { $0.isFinite })
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        XCTAssertGreaterThan(norm, 1e-3)
        print("voice-model-runner campplus load_ms=\(loadMs) run_ms=\(runMs) frames=\(frames.count) dim=\(embedding.count) norm=\(norm)")
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// What the embedder gives the shipped model: a 4 s window (400 frames) whole, and of a 3 s window (300 frames) the
    /// first 200, with the mean of those 200 removed.
    func testCamPlusEmbedsTheFramesTheEmbedderKeeps() throws {
        let url = try engineResource("campplus_sv_voxceleb_16k.onnx")
        let model = CamPlusModel(runner: try VoiceModelRunner(modelPath: url.path))
        let extractor = KaldiFbankExtractor()

        let four = extractor.extract(Self.testSignal(count: 4 * KaldiFbankExtractor.sampleRate))
        XCTAssertEqual(four.count, 400)
        let keptFour = try XCTUnwrap(CamPlusSpeakerEmbedder.modelFrames(from: four))
        let embeddingOfKeptFour = try model.embedding(features: keptFour)
        let embeddingOfFour = try model.embedding(features: four)
        XCTAssertGreaterThanOrEqual(cosine(embeddingOfKeptFour, embeddingOfFour), 1 - 1e-6)

        let three = extractor.extract(Self.testSignal(count: 3 * KaldiFbankExtractor.sampleRate))
        XCTAssertEqual(three.count, 300)
        let keptThree = try XCTUnwrap(CamPlusSpeakerEmbedder.modelFrames(from: three))
        XCTAssertEqual(keptThree.count, 200)
        var first = Array(three.prefix(200))
        var mean = [Float](repeating: 0, count: KaldiFbankExtractor.numMelBins)
        for row in first { for m in 0..<mean.count { mean[m] += row[m] / 200 } }
        for t in 0..<first.count { for m in 0..<mean.count { first[t][m] -= mean[m] } }
        let embeddingOfKeptThree = try model.embedding(features: keptThree)
        let embeddingOfFirst = try model.embedding(features: first)
        XCTAssertGreaterThanOrEqual(cosine(embeddingOfKeptThree, embeddingOfFirst), 1 - 1e-6)
    }
}
