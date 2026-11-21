import XCTest
import Foundation
import CryptoKit
@testable import QAudionEngine

/// The shipped CAM++ model on the stored stage 4 windows (400 x 80 after CMN): the raw 512-vector must match the stored one
/// (cosine and norm). One real ONNX Runtime inference per window on whatever runtime the test job runs on.
final class VoiceKatStage5Tests: XCTestCase {

    private static let camPlusSha256 = "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"

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

    func testEmbeddingOfEveryStoredWindow() throws {
        let stage5 = try VoiceKat.json("stage5_embedding/stage5.json")
        XCTAssertEqual(stage5["model"]["sha256"].string, Self.camPlusSha256)
        XCTAssertEqual(stage5["windows"].count, 9)
        let cosineMin = stage5["tolerance"]["cosine_min"].double
        let normRel = stage5["tolerance"]["norm_rel"].double

        let url = try engineResource("campplus_sv_voxceleb_16k.onnx")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), Self.camPlusSha256)
        let model = CamPlusModel(runner: try VoiceModelRunner(modelPath: url.path))

        let bins = VoiceFbankTables.numMel
        for entry in stage5["windows"].array {
            let name = entry["raw_file"].string
            let flat = try VoiceKat.floats(entry["input"].string)
            XCTAssertEqual(flat.count, 400 * bins, name)
            guard flat.count == 400 * bins else { continue }
            let frames = (0..<400).map { Array(flat[($0 * bins)..<(($0 + 1) * bins)]) }
            let got = try model.embedding(features: frames)
            let want = try VoiceKat.floats(name)
            XCTAssertEqual(got.count, want.count, name)
            guard got.count == want.count else { continue }

            var dot = 0.0
            var normGot = 0.0
            var normWant = 0.0
            for i in 0..<got.count {
                dot += Double(got[i]) * Double(want[i])
                normGot += Double(got[i]) * Double(got[i])
                normWant += Double(want[i]) * Double(want[i])
            }
            normGot = normGot.squareRoot()
            normWant = normWant.squareRoot()
            XCTAssertGreaterThanOrEqual(dot / (normGot * normWant), cosineMin, "\(name) cosine")
            XCTAssertEqual(normWant, entry["norm"].double, accuracy: 1e-3 * entry["norm"].double, "\(name) stored norm")
            XCTAssertEqual(normGot, entry["norm"].double, accuracy: normRel * entry["norm"].double, "\(name) norm")
        }
    }
}
