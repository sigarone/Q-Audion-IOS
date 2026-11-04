import XCTest
@testable import QAudionApp

/// The approval sheet shows what the new device calls itself between quotes. A literal "(value)" instead of the
/// name once shipped because nothing read the rendered text.
final class LoginApprovalSheetTests: XCTestCase {
    func test_quotedLabel_containsTheName() {
        let text = LoginApprovalSheet.quoted("iPhone di Maria")
        XCTAssertTrue(text.contains("iPhone di Maria"))
        XCTAssertFalse(text.contains("(value)"))
        XCTAssertEqual(text, "\u{201C}iPhone di Maria\u{201D}")
    }

    func test_emptyName_isADash_notTheRowLabelAgain() {
        let text = LoginApprovalSheet.quoted("")
        XCTAssertEqual(text, "\u{2014}")
        XCTAssertFalse(text.contains(DeviceApprovalTexts.sheetLabelDevice))
    }
}
