import XCTest
@testable import QAudionApp
import QAudionEngine

/// The coordinate rule of the log redactors (WIRE_SPEC section 14.10) through BOTH paths of `LogRedactor`: `redact` (the stdout tee and the
/// text export) and `redactStructured` (the live-log shipper and the telemetry attributes). No log line may carry a position, an accuracy,
/// a share id, a share key, a `geo:` URI, a map link or a GPX waypoint: for every `redaction_cases` vector of `location-kat.json` (a
/// byte-for-byte copy of the server's file, pinned by the engine tests) the listed substrings must not survive, whatever placeholder the
/// redactor writes in their place. The rule itself is `LocationLogScrub` of the engine, which `QAudionEngineTests` runs on the same vectors.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class LogRedactorLocationTests: XCTestCase {

    private func katBytes() throws -> Data {
        let relativePath = "QAudionEngine/Tests/QAudionEngineTests/Resources/kat/location-kat.json"
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }
        throw XCTSkip("\(relativePath) not found")
    }

    private func redactionCases() throws -> [(name: String, line: String, mustNotSurvive: [String])] {
        let object = try JSONSerialization.jsonObject(with: try katBytes())
        let root = try XCTUnwrap(object as? [String: Any])
        let cases = try XCTUnwrap(root["redaction_cases"] as? [[String: Any]])
        return try cases.map { entry in
            (name: try XCTUnwrap(entry["name"] as? String), line: try XCTUnwrap(entry["line"] as? String),
             mustNotSurvive: try XCTUnwrap(entry["must_not_survive"] as? [String]))
        }
    }

    func test_everyRedactionCaseLosesItsCoordinatesInTheTextPath() throws {
        let cases = try redactionCases()
        XCTAssertEqual(cases.count, 20)
        for entry in cases {
            let out = LogRedactor.redact(entry.line)
            for needle in entry.mustNotSurvive {
                XCTAssertFalse(out.contains(needle), "\(entry.name): \(needle) survived redact")
            }
        }
    }

    func test_everyRedactionCaseLosesItsCoordinatesInTheEgressPath() throws {
        let cases = try redactionCases()
        XCTAssertEqual(cases.count, 20)
        for entry in cases {
            let out = LogRedactor.redactStructured(entry.line)
            for needle in entry.mustNotSurvive {
                XCTAssertFalse(out.contains(needle), "\(entry.name): \(needle) survived redactStructured")
            }
        }
    }

    /// A coordinate inside a longer, otherwise ordinary diagnostic line is removed and the rest of the line stays readable.
    func test_theRestOfALineWithAPositionSurvives() {
        let line = "ice connected role=caller position lat=45.464211 lon=9.189982 acc=12 retries=2"
        for out in [LogRedactor.redact(line), LogRedactor.redactStructured(line)] {
            XCTAssertFalse(out.contains("45.464211"))
            XCTAssertFalse(out.contains("9.189982"))
            XCTAssertTrue(out.contains("role=caller"), out)
            XCTAssertTrue(out.contains("retries=2"), out)
        }
    }

    /// A latency written `lat=12ms` is not a position and is not touched; neither is a version.
    func test_aLatencyAndAVersionAreNotPositions() {
        for (line, kept) in [("abr loss=1% lat=12ms jitter=3ms", "lat=12ms"), ("app version 1.0.1223 build 4821", "1.0.1223")] {
            XCTAssertTrue(LogRedactor.redact(line).contains(kept), line)
            XCTAssertTrue(LogRedactor.redactStructured(line).contains(kept), line)
        }
    }

    /// The share id and the share key written with their member names are removed even when the text holds no digit at all.
    func test_aShareKeyWithoutADigitIsRemoved() {
        let line = "start sid=\"AAAAAAAAAAAAAAAAAAAAAA==\" k=\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\""
        XCTAssertFalse(LogRedactor.redact(line).contains("AAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(LogRedactor.redactStructured(line).contains("AAAAAAAAAAAAAAAAAAAAAA"))
    }
}
