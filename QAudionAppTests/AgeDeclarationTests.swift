import XCTest
@testable import QAudionApp

/// The age declaration gate on the registration screen, and the URLs of the
/// app Terms and Privacy pages for each language.
final class AgeDeclarationTests: XCTestCase {

    func testRegisterRequiresAgeDeclaration() {
        XCTAssertFalse(PhoneEntryScreen.ageOk(mode: .register, ageDeclared: false))
        XCTAssertTrue(PhoneEntryScreen.ageOk(mode: .register, ageDeclared: true))
    }

    func testLoginDoesNotRequireAgeDeclaration() {
        XCTAssertTrue(PhoneEntryScreen.ageOk(mode: .login, ageDeclared: false))
    }

    func testTermsUrlItalianUsesItalianPrefix() {
        XCTAssertEqual(LegalLinks.appTerms(languageCode: "it").absoluteString,
                       "https://bcrypto.com/it/legal/qaudion-terms")
    }

    func testPrivacyUrlEnglishHasNoLocalePrefix() {
        XCTAssertEqual(LegalLinks.appPrivacy(languageCode: "en").absoluteString,
                       "https://bcrypto.com/legal/qaudion-privacy")
    }

    func testTermsUrlUsesPrimaryLanguageSubtag() {
        XCTAssertEqual(LegalLinks.appTerms(languageCode: "pt-BR").absoluteString,
                       "https://bcrypto.com/legal/qaudion-terms")
    }
}
