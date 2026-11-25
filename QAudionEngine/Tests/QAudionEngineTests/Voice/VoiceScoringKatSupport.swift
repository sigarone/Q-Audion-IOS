import XCTest
import Foundation
@testable import QAudionEngine

extension KatJSON {
    /// The members of an object (empty for any other kind of value).
    var members: [String: KatJSON] {
        if case .object(let o) = self { return o }
        return [:]
    }

    /// The text of a string value, nil for any other kind of value (a missing key included).
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// What the scoring and evidence vectors need besides `VoiceKat`: the back-end constants, the cohort, the model file.
enum VoiceScoringKat {
    static let camPlusSha256 = "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"

    /// The constants of the runtime bundle (the file the app ships).
    static func constants() throws -> VoiceScoringConstants {
        let directory = try XCTUnwrap(VoiceBundle.moduleDirectory(), "voice bundle not found in the module resources")
        return try VoiceScoringConstants.decode(try Data(contentsOf: directory.appendingPathComponent(VoiceBundle.constantsFile)))
    }

    /// The bytes of the cohort file of the runtime bundle.
    static func cohortData() throws -> Data {
        let directory = try XCTUnwrap(VoiceBundle.moduleDirectory(), "voice bundle not found in the module resources")
        return try Data(contentsOf: directory.appendingPathComponent("cohort.bin"))
    }

    /// The pinned cohort of the runtime bundle.
    static func cohort() throws -> VoiceCohort {
        try VoiceCohort.parse(try cohortData(), constants: try constants().cohort)
    }

    /// A file of the engine's own resource folder, found from this source file (the tests already read repository files by path).
    static func engineResource(_ name: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("Sources/QAudionEngine/Resources/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("\(name) not found next to the test sources")
        throw CocoaError(.fileNoSuchFile)
    }

    static func assertFloatsAbs(_ what: String, _ got: [Float], _ want: [Float], _ tolerance: Double) {
        XCTAssertEqual(got.count, want.count, "\(what): length")
        guard got.count == want.count else { return }
        var worst = 0.0
        for i in 0..<got.count {
            worst = max(worst, abs(Double(got[i]) - Double(want[i])))
        }
        XCTAssertLessThanOrEqual(worst, tolerance, "\(what): largest component difference")
    }
}
