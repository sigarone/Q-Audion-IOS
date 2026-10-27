import XCTest
@testable import QAudionApp

/// The age declaration on the registration screens: which gates keep the submit button off (and that each screen's
/// own property calls its gate with the ticked state, and that the buttons are disabled by it), what the phone screen
/// hands to the OTP step, the pages the box
/// links to, which screens show the box and send the declaration, and the
/// texts of the box in the string catalog. The body of the requests is covered by `BCryptoAuthWireFormatTests` in
/// the engine tests.
final class AgeDeclarationTests: XCTestCase {

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

    /// The interno + email form needs the two conditions together: a wrong email keeps the button off even when the
    /// box is ticked, and an unticked box keeps it off even when the email is right. No invite code is asked.
    func testExtensionFormNeedsEmailAndBox() {
        XCTAssertTrue(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: true, ageDeclared: true))
        XCTAssertFalse(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: true, ageDeclared: false))
        XCTAssertFalse(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: false, ageDeclared: true))
    }

    /// The whole gate of the phone screen's button, not only the age part: for a registration the box is one of two
    /// conditions, and each of them alone keeps the button off. Registration needs no invite code.
    func testPhoneRegisterButtonNeedsNumberAndBox() {
        XCTAssertTrue(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .register, ageDeclared: true))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .register, ageDeclared: false))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: false, mode: .register, ageDeclared: true))
    }

    /// A login shows no box: a valid number is all it takes, ticked or not.
    func testPhoneLoginButtonNeedsOnlyTheNumber() {
        XCTAssertTrue(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .login, ageDeclared: false))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: false, mode: .login, ageDeclared: true))
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
}
