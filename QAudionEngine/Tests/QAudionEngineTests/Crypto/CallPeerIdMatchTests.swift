import XCTest
@testable import QAudionEngine

final class CallPeerIdMatchTests: XCTestCase {
    func testSameContactInDifferentForms() {
        XCTAssertTrue(CallPeerIdMatch.same("ABCD-1234", "abcd-1234"))
        XCTAssertTrue(CallPeerIdMatch.same("abcd-1234|dev9", "abcd-1234"))
        XCTAssertTrue(CallPeerIdMatch.same(" abcd-1234 ", "ABCD-1234|dev1"))
    }

    func testDifferentContactsAndEmptyIdsDoNotMatch() {
        XCTAssertFalse(CallPeerIdMatch.same("abcd-1234", "abcd-1235"))
        XCTAssertFalse(CallPeerIdMatch.same("", ""))
        XCTAssertFalse(CallPeerIdMatch.same("|dev", "|dev"))
    }
}
