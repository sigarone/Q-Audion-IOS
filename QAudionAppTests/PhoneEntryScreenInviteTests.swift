import XCTest
@testable import QAudionApp

/// The invite code field of the phone registration screen uses the same
/// format + checksum check as the interno+email screen (`InviteCodeInput`),
/// and hands the OTP step the normalised dashed form.
final class PhoneEntryScreenInviteTests: XCTestCase {

    private let valid = "QA1-7K3M9-PXTVY-R2HN5-ZZ"
    private let badChecksum = "QA1-7K3M9-PXTVY-R2HN5-ZY"

    func testRegisterRequiresValidFormatAndChecksum() {
        XCTAssertTrue(PhoneEntryScreen.inviteOk(mode: .register, inviteCode: valid))
        XCTAssertTrue(PhoneEntryScreen.inviteOk(mode: .register, inviteCode: " qa17k3m9pxtvyr2hn5zz "))
        XCTAssertFalse(PhoneEntryScreen.inviteOk(mode: .register, inviteCode: ""))
        XCTAssertFalse(PhoneEntryScreen.inviteOk(mode: .register, inviteCode: "x"))
        XCTAssertFalse(PhoneEntryScreen.inviteOk(mode: .register, inviteCode: "QA1-7K3M9"))
        XCTAssertFalse(PhoneEntryScreen.inviteOk(mode: .register, inviteCode: badChecksum))
    }

    func testLoginIgnoresInviteCode() {
        XCTAssertTrue(PhoneEntryScreen.inviteOk(mode: .login, inviteCode: ""))
        XCTAssertNil(PhoneEntryScreen.inviteWireValue(mode: .login, inviteCode: valid))
    }

    func testRegisterSendsNormalisedCode() {
        XCTAssertEqual(PhoneEntryScreen.inviteWireValue(mode: .register, inviteCode: valid), valid)
        XCTAssertEqual(PhoneEntryScreen.inviteWireValue(mode: .register, inviteCode: " qa17k3m9pxtvyr2hn5zz "), valid)
        XCTAssertNil(PhoneEntryScreen.inviteWireValue(mode: .register, inviteCode: badChecksum))
        XCTAssertNil(PhoneEntryScreen.inviteWireValue(mode: .register, inviteCode: ""))
    }
}
