import XCTest
@testable import QAudionEngine

/// What a backup holds for a location row (docs/LOCATION_SHARING.md 1.3): a valid pin as it is, a live row in its local form (never the
/// key, never a position), anything unreadable as the fixed placeholder. A body that is not a location is left alone.
final class LocationBackupBodyTests: XCTestCase {

    private let sid = Data((0..<16).map { UInt8($0 + 1) })
    private let key = Data((32..<64).map { UInt8($0) })

    private func fix() -> LocationFix {
        LocationFix(latitude: 45.4642110, longitude: 9.1899820, horizontalAccuracy: 12, elapsedMs: 3_000, approximate: false)
    }

    private func pin() throws -> String {
        guard case .success(let text) = LocationCodec.buildPin(fix: fix()) else { throw XCTSkip("builder refused") }
        return text
    }

    private func live() throws -> String {
        guard case .success(let text) = LocationCodec.buildLiveStart(fix: fix(), sid: sid, key: key, startedAt: 1_000, duration: 3_600) else {
            throw XCTSkip("builder refused")
        }
        return text
    }

    func testAPinStaysAsItIs() throws {
        let body = try pin()
        XCTAssertEqual(LocationBackupBody.normalised(body), body)
    }

    /// The row of a share whose start has not been acknowledged yet still holds the full start body, key included.
    func testTheFullStartBodyOfALiveShareBecomesItsLocalFormWithoutTheKey() throws {
        let body = try live()
        XCTAssertTrue(body.contains(key.base64EncodedString()))
        let saved = LocationBackupBody.normalised(body)
        XCTAssertEqual(saved, LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600))
        XCTAssertFalse(saved.contains(key.base64EncodedString()), "k is never in a backup")
        XCTAssertFalse(saved.contains("454642110"), "no position either")
        XCTAssertFalse(saved.contains("\"lat\""))
    }

    func testTheLocalFormOfALiveRowIsKept() {
        let local = LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600)
        XCTAssertEqual(LocationBackupBody.normalised(local), local)
    }

    func testAnythingUnreadableBecomesThePlaceholderAndNothingOfItSurvives() {
        let bodies: [String] = [
            #"{"qa_loc":1,"m":"pin","lat":454642110,"lon":91899820}"#,                         // members missing
            #"{"qa_loc":2,"m":"pin","lat":454642110,"lon":91899820,"acc":0,"age":3,"ap":0}"#,  // a version this build cannot read
            #"{"qa_loc":1,"m":"live","k":"AAAA","lat":454642110}"#,                            // a key and a position, no valid start
            #"{"qa_loc":1,"m":"pin","lat":454642110,"lon":91899820,"acc":0,"age":3,"ap":0,"sid":"AAAA"}"#, // a pin that carries a share member
        ]
        for body in bodies {
            let saved = LocationBackupBody.normalised(body)
            XCTAssertEqual(saved, LocationBodyPlaceholder.text(.unavailable), body)
            XCTAssertFalse(saved.contains("454642110"), body)
            XCTAssertFalse(saved.contains("qa_loc"), body)
        }
    }

    func testTextThatIsNotALocationIsLeftAlone() {
        for text in ["", "ciao", #"{"qa_reply":1}"#, "  {\"qa_loc\":1}", "x{\"qa_loc\":1,\"m\":\"pin\"}"] {
            XCTAssertEqual(LocationBackupBody.normalised(text), text)
        }
    }
}
