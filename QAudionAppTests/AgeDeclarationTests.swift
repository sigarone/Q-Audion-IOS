import XCTest
@testable import QAudionApp

/// The age declaration on the registration screens: which gates keep the submit button off (and that each screen's
/// own property calls its gate with the ticked state, and that the buttons are disabled by it), what the phone screen
/// hands to the OTP step, the pages the box
/// links to, which screens show the box and send the declaration, and the
/// texts of the box in the string catalog. The body of the requests is covered by `BCryptoAuthWireFormatTests` in
/// the engine tests.
final class AgeDeclarationTests: XCTestCase {

    private let validInvite = "QA1-7K3M9-PXTVY-R2HN5-ZZ"

    // MARK: - Gates
    func testPhoneRegisterNeedsTheBoxTicked() {
        XCTAssertFalse(PhoneEntryScreen.ageOk(mode: .register, ageDeclared: false))
        XCTAssertTrue(PhoneEntryScreen.ageOk(mode: .register, ageDeclared: true))
    }
    func testPhoneLoginNeedsNoBox() {
        XCTAssertTrue(PhoneEntryScreen.ageOk(mode: .login, ageDeclared: false))
    }
    func testPhoneScreenHandsTheOtpStepWhatWasTickedForRegisterAndNothingForLogin() {
        XCTAssertTrue(PhoneEntryScreen.ageWireValue(mode: .register, ageDeclared: true))
        XCTAssertFalse(PhoneEntryScreen.ageWireValue(mode: .register, ageDeclared: false))
        XCTAssertFalse(PhoneEntryScreen.ageWireValue(mode: .login, ageDeclared: true))
    }

    /// The interno + email form needs the three conditions together: a wrong one keeps the button off even when the
    /// box is ticked, and an unticked box keeps it off even when the rest is right.    func testExtensionFormNeedsEmailInviteAndBox() {
        XCTAssertTrue(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: true, inviteCode: validInvite, ageDeclared: true))
        XCTAssertFalse(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: true, inviteCode: validInvite, ageDeclared: false))
        XCTAssertFalse(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: false, inviteCode: validInvite, ageDeclared: true))
        XCTAssertFalse(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: true, inviteCode: "QA1-7K3M9", ageDeclared: true))
    }

    /// The whole gate of the phone screen's button, not only the age part: for a registration the box is one of three
    /// conditions, and each of them alone keeps the button off.    func testPhoneRegisterButtonNeedsNumberInviteAndBox() {
        XCTAssertTrue(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .register, inviteCode: validInvite, ageDeclared: true))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .register, inviteCode: validInvite, ageDeclared: false))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: false, mode: .register, inviteCode: validInvite, ageDeclared: true))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .register, inviteCode: "QA1-7K3M9", ageDeclared: true))
    }

    /// A login shows no box and no invite field: a valid number is all it takes, ticked or not.    func testPhoneLoginButtonNeedsOnlyTheNumber() {
        XCTAssertTrue(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .login, inviteCode: "", ageDeclared: false))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: false, mode: .login, inviteCode: "", ageDeclared: true))
    }

    // MARK: - Links
    func testTermsAndPrivacyPagesForItalianUseTheItalianRoute() {
        XCTAssertEqual(LegalLinks.appTerms(languageCode: "it").absoluteString, "https://bcrypto.com/it/legal/qaudion-terms")
        XCTAssertEqual(LegalLinks.appPrivacy(languageCode: "it").absoluteString, "https://bcrypto.com/it/legal/qaudion-privacy")
    }
    func testTermsAndPrivacyPagesForEveryOtherLanguageHaveNoPrefix() {
        for language in ["en", "de", "es", "fr", "pt-BR"] {
            XCTAssertEqual(LegalLinks.appTerms(languageCode: language).absoluteString,
                           "https://bcrypto.com/legal/qaudion-terms", language)
            XCTAssertEqual(LegalLinks.appPrivacy(languageCode: language).absoluteString,
                           "https://bcrypto.com/legal/qaudion-privacy", language)
        }
    }

    // MARK: - Screens

    /// The box is on both registration screens, and each sends what was ticked: the phone screen to the OTP step,
    /// which hands it to the server with the code; the interno + email screen straight to the server. Dropping the box
    /// from a screen, or the argument from a call, would let the flag on the server block people.
}
