import XCTest
@testable import QAudionEngine

final class ProfileStatusUpdateTests: XCTestCase {

    func testEmptiedAfterNonEmptyLoadIsSentAsEmptyString() {
        XCTAssertEqual(ProfileStatusUpdate.statusToSend(loadedStatus: "Disponibile", draftStatus: ""), "")
    }

    func testAlreadyEmptyLoadedStatusIsLeftUnchanged() {
        XCTAssertNil(ProfileStatusUpdate.statusToSend(loadedStatus: "", draftStatus: ""))
    }

    func testNeverLoadedStatusIsLeftUnchanged() {
        XCTAssertNil(ProfileStatusUpdate.statusToSend(loadedStatus: nil, draftStatus: ""))
    }

    func testEditedNonEmptyDraftIsSent() {
        XCTAssertEqual(ProfileStatusUpdate.statusToSend(loadedStatus: "Disponibile", draftStatus: "In riunione"), "In riunione")
    }

    func testNonEmptyDraftIsSentEvenWhenNeverLoaded() {
        XCTAssertEqual(ProfileStatusUpdate.statusToSend(loadedStatus: nil, draftStatus: "Ciao"), "Ciao")
    }

    func testUnchangedNonEmptyDraftIsSent() {
        XCTAssertEqual(ProfileStatusUpdate.statusToSend(loadedStatus: "Ciao", draftStatus: "Ciao"), "Ciao")
    }
}
