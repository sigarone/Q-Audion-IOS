import XCTest
import Foundation
import OnnxRuntimeBindings
@testable import QAudionEngine

/// Stage 5 through the engine's own runner: the speaker model on the nine stored stage 4 windows (400 x 80), the raw 512
/// vector with cosine at least 0.999999 and the norm within 0.1 % (relative), using the app's copy of the model after its
/// SHA-256 check. Plus what the runner promises: exactly 400 frames, a model that does not match its pin is refused and not
/// retried, a failed session creation is retried, and a model output that is not usable gives no embedding.
final class VoiceKatStage5EmbedderTests: XCTestCase {

    private struct OpenFailure: Error {}

    private func modelURL() throws -> URL {
        try VoiceScoringKat.engineResource("campplus_sv_voxceleb_16k.onnx")
    }

    func testTheAppModelMatchesThePinOfTheConstantsAndOfTheVectors() throws {
        let stage5 = try VoiceKat.json("stage5_embedding/stage5.json")
        let constants = try VoiceScoringKat.constants()
        XCTAssertEqual(stage5["model"]["sha256"].string, constants.model.embedderSha256)
        XCTAssertEqual(constants.model.embedderSha256, VoiceScoringKat.camPlusSha256)
        XCTAssertEqual(constants.model.embedderFile, "campplus_sv_voxceleb_16k.onnx")
        let bytes = try Data(contentsOf: try modelURL())
        XCTAssertEqual(Int64(bytes.count), stage5["model"]["bytes"].int64)
        XCTAssertEqual(VoiceHash.sha256Hex(bytes), constants.model.embedderSha256)
    }

    func testAllNineWindowsGiveTheStoredRawEmbeddingAndNorm() throws {
        let stage5 = try VoiceKat.json("stage5_embedding/stage5.json")
        let cosineMin = stage5["tolerance"]["cosine_min"].double
        let normRel = stage5["tolerance"]["norm_rel"].double
        XCTAssertEqual(cosineMin, 0.999999)
        XCTAssertEqual(normRel, 1e-3)
        XCTAssertEqual(stage5["windows"].count, 9)

        let embedder = try OrtCamPlusEmbedder.load(
            modelURL: try modelURL(), expectedSha256: try VoiceScoringKat.constants().model.embedderSha256)
        defer { embedder.close() }
        for entry in stage5["windows"].array {
            let name = "clip \(entry["clip"].string) window \(entry["window"].int)"
            let fbank = try VoiceKat.floats(entry["input"].string)
            XCTAssertEqual(fbank.count, VoiceEmbedderShape.frames * VoiceEmbedderShape.mel, "\(name): input")
            let want = try VoiceKat.floats(entry["raw_file"].string)
            let wantNorm = entry["norm"].double
            XCTAssertEqual(VoiceMath.norm(want), wantNorm, accuracy: 1e-6 * wantNorm, "\(name): stored norm")
            guard let got = try embedder.embed(fbank: fbank) else {
                XCTFail("\(name): no embedding")
                continue
            }
            XCTAssertEqual(got.raw.count, 512, "\(name): dimension")
            XCTAssertEqual(got.norm, VoiceMath.norm(got.raw), accuracy: 0, "\(name): the norm is the Euclidean norm of the raw vector")
            var dot = 0.0
            for i in 0..<want.count { dot += Double(got.raw[i]) * Double(want[i]) }
            let cosine = dot / (got.norm * VoiceMath.norm(want))
            XCTAssertGreaterThanOrEqual(cosine, cosineMin, "\(name): cosine")
            XCTAssertLessThanOrEqual(abs(got.norm - wantNorm), normRel * wantNorm, "\(name): norm \(got.norm) against \(wantNorm)")
            XCTAssertEqual(VoiceMath.norm(got.unit()), 1.0, accuracy: 1e-6, "\(name): unit vector")
        }
    }

    func testAnyOtherNumberOfFramesIsRefused() throws {
        let embedder = try OrtCamPlusEmbedder.load(modelURL: try modelURL(), expectedSha256: VoiceScoringKat.camPlusSha256)
        defer { embedder.close() }
        for frames in [0, 1, 399, 401, 408] {
            XCTAssertThrowsError(try embedder.embed(fbank: [Float](repeating: 0, count: frames * 80)), "\(frames) frames") { error in
                XCTAssertEqual(error as? VoiceEmbedderError, VoiceEmbedderError.badInputLength(frames * 80))
            }
        }
        XCTAssertThrowsError(try embedder.embed(fbank: [Float](repeating: 0, count: 400 * 80 + 1)))
    }

    func testAModelThatDoesNotMatchItsPinIsRefusedAndNotRetried() throws {
        var bytes = try Data(contentsOf: try modelURL())
        bytes[bytes.count / 2] ^= 0x01
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("voice-model-\(UUID().uuidString).onnx")
        try bytes.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        var opens = 0
        XCTAssertThrowsError(
            try OrtCamPlusEmbedder.load(modelURL: copy, expectedSha256: VoiceScoringKat.camPlusSha256, attempts: 3) { _ in
                opens += 1
                throw OpenFailure()
            }
        ) { error in
            XCTAssertEqual(error as? VoiceBundleError, VoiceBundleError.hashMismatch("embedder model"))
        }
        XCTAssertEqual(opens, 0)
    }

    func testAFailedSessionCreationIsRetriedAndTheLastAttemptCanSucceed() throws {
        var opens = 0
        let embedder = try OrtCamPlusEmbedder.load(
            modelURL: try modelURL(), expectedSha256: VoiceScoringKat.camPlusSha256, attempts: 3
        ) { url in
            opens += 1
            if opens < 3 { throw OpenFailure() }
            return try OrtCamPlusEmbedder.openSession(at: url)
        }
        defer { embedder.close() }
        XCTAssertEqual(opens, 3)
        let fbank = try VoiceKat.floats("stage4_fbank/clip_a_w0.f32")
        XCTAssertNotNil(try embedder.embed(fbank: fbank))
    }

    func testWhenEveryAttemptFailsTheModelIsReportedUnavailable() throws {
        var opens = 0
        XCTAssertThrowsError(
            try OrtCamPlusEmbedder.load(modelURL: try modelURL(), expectedSha256: VoiceScoringKat.camPlusSha256, attempts: 3) { _ in
                opens += 1
                throw OpenFailure()
            }
        ) { error in
            XCTAssertEqual(error as? VoiceBundleError, VoiceBundleError.malformed("embedder model: cannot be loaded"))
        }
        XCTAssertEqual(opens, 3)
    }

    func testAClosedEmbedderGivesNoEmbedding() throws {
        let embedder = try OrtCamPlusEmbedder.load(modelURL: try modelURL(), expectedSha256: VoiceScoringKat.camPlusSha256)
        embedder.close()
        let fbank = try VoiceKat.floats("stage4_fbank/clip_a_w0.f32")
        XCTAssertNil(try embedder.embed(fbank: fbank))
        embedder.close()
    }

    func testAModelOutputThatIsNotFiniteOrHasNoNormGivesNoEmbedding() {
        XCTAssertNil(VoiceMath.rawEmbedding([Float](repeating: 0, count: 512)))
        var nan = [Float](repeating: 1, count: 512)
        nan[7] = .nan
        XCTAssertNil(VoiceMath.rawEmbedding(nan))
        var inf = [Float](repeating: 1, count: 512)
        inf[7] = .infinity
        XCTAssertNil(VoiceMath.rawEmbedding(inf))
        let ok = VoiceMath.rawEmbedding([Float](repeating: 1, count: 512))
        XCTAssertEqual(ok?.norm ?? 0, 512.0.squareRoot(), accuracy: 1e-12)
    }
}
