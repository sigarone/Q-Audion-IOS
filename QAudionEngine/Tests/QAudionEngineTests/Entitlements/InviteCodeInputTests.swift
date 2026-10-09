import XCTest
@testable import QAudionEngine

/// Local handling of the invite code on the registration screens, and the
/// mapping of the server's 403 text. The valid code below is built from the
/// checksum vector `("QA1", "7K3M9PXTVYR2HN5") -> "ZZ"` pinned in
/// `ActivationCodeTests` (Go reference table).
final class InviteCodeInputTests: XCTestCase {

    private let valid = "QA1-7K3M9-PXTVY-R2HN5-ZZ"
    private let badChecksum = "QA1-7K3M9-PXTVY-R2HN5-ZY"

    // MARK: - format

    func testFormatUppercasesAndInsertsDashes() {
        XCTAssertEqual(InviteCodeInput.format("qa17k3m9pxtvyr2hn5zz"), valid)
    }

    func testFormatDropsCharactersOutsideTheAlphabetAndCapsLength() {
        XCTAssertEqual(InviteCodeInput.format(" qa1-7k3m9 pxtvy/r2hn5-zz-EXTRA"), valid)
    }

    func testFormatIsStableOnAlreadyFormattedInput() {
        XCTAssertEqual(InviteCodeInput.format(valid), valid)
    }

    func testFormatOfPartialInputKeepsPartialShape() {
        XCTAssertEqual(InviteCodeInput.format("qa17k3"), "QA1-7K3")
        XCTAssertEqual(InviteCodeInput.format(""), "")
    }

    // MARK: - validity

    func testValidCodeIsAccepted() {
        XCTAssertTrue(InviteCodeInput.isValid(valid))
        XCTAssertTrue(InviteCodeInput.isValid("qa1 7k3m9 pxtvy r2hn5 zz"))
    }

    func testEmptyAndPartialCodesAreRejected() {
        XCTAssertFalse(InviteCodeInput.isValid(""))
        XCTAssertFalse(InviteCodeInput.isValid("QA1-7K3M9"))
        XCTAssertFalse(InviteCodeInput.isValid("QA1-7K3M9-PXTVY-R2HN5"))
    }

    func testWrongChecksumIsRejected() {
        XCTAssertFalse(InviteCodeInput.isValid(badChecksum))
    }

    func testCompleteButInvalidFlagsOnlyFullLengthWrongChecksum() {
        XCTAssertTrue(InviteCodeInput.isCompleteButInvalid(badChecksum))
        XCTAssertFalse(InviteCodeInput.isCompleteButInvalid(valid))
        XCTAssertFalse(InviteCodeInput.isCompleteButInvalid("QA1-7K3M9"))
        XCTAssertFalse(InviteCodeInput.isCompleteButInvalid(""))
    }

    // MARK: - wire value

    func testWireValueIsTheNormalisedDashedForm() {
        XCTAssertEqual(InviteCodeInput.wireValue(valid), valid)
        XCTAssertEqual(InviteCodeInput.wireValue("  qa17k3m9pxtvyr2hn5zz "), valid)
    }

    func testWireValueIsNilForInvalidInput() {
        XCTAssertNil(InviteCodeInput.wireValue(""))
        XCTAssertNil(InviteCodeInput.wireValue(badChecksum))
        XCTAssertNil(InviteCodeInput.wireValue("QA1-7K3M9"))
    }

    // MARK: - server 403 mapping

    private func classify(_ json: String) -> BCryptoInviteCodeError? {
        BCryptoInviteCodeError(forbiddenBody: Data(json.utf8))
    }

    func testRequiredMessagesMapToRequired() {
        XCTAssertEqual(classify(#"{"error":"invite code required"}"#)?.reason, .required)
        XCTAssertEqual(classify(#"{"error":"invite_code required"}"#)?.reason, .required)
    }

    func testInvalidOrExpiredMessageMapsToInvalid() {
        XCTAssertEqual(classify(#"{"error":"invalid or expired invite code"}"#)?.reason, .invalid)
    }

    func testOtherMessagesAreNotInviteErrors() {
        XCTAssertNil(classify(#"{"error":"forbidden"}"#))
        XCTAssertNil(classify(#"{"error":"device revoked"}"#))
        XCTAssertNil(classify(#"{"message":"invite code required"}"#))
        XCTAssertNil(classify("not json"))
        XCTAssertNil(classify(""))
    }

    func testUserFacingMessagesAreTheItalianSourceTexts() {
        XCTAssertEqual(BCryptoInviteCodeError(reason: .required).userFacingMessage, "Serve un codice invito")
        XCTAssertEqual(BCryptoInviteCodeError(reason: .invalid).userFacingMessage, "Codice invito non valido o scaduto")
    }
}
