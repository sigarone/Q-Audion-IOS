import XCTest
@testable import QAudionApp

/// The neutral grey note of the call screen (the post-quantum check of the handshake did not complete in this call).
final class PqVerifyNoteTests: XCTestCase {

    /// With the note up and the identity verified there is nothing to confirm: no confirm button. Otherwise the panel is as before.
    func testTheNoteHidesTheConfirmButtonOnlyForAVerifiedIdentity() {
        XCTAssertTrue(PqVerifyNoteRow.hidesSasConfirm(noteShown: true, identityVerified: true))
        XCTAssertFalse(PqVerifyNoteRow.hidesSasConfirm(noteShown: true, identityVerified: false))
        XCTAssertFalse(PqVerifyNoteRow.hidesSasConfirm(noteShown: false, identityVerified: true))
        XCTAssertFalse(PqVerifyNoteRow.hidesSasConfirm(noteShown: false, identityVerified: false))
    }

    /// The note asks for nothing: it never carries the safety-code sentence.
    func testTheNoteTextDoesNotAskToVerifyTheCode() {
        let text = PqVerifyNoteRow.text.lowercased()
        XCTAssertFalse(text.contains("codice"))
        XCTAssertFalse(text.contains("code"))
        XCTAssertFalse(text.isEmpty)
    }
}
