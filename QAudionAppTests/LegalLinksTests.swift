import XCTest
@testable import QAudionApp

/// Where the app sends the user for the legal pages.
///
///   - One privacy URL for the app: `privacyPolicy()` (Settings, About, Welcome) is the same page as `appPrivacy()` (the age
///     declaration at registration), in every language, on the document host and not on the product site.
///   - The account-deletion page is not on the document host, so it stays on the product site, per language.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class LegalLinksTests: XCTestCase {

    private let languages = ["it", "en", "de", "es", "fr", "pt-BR", "ja", "it-IT", ""]

    func test_thePrivacyLinkIsTheSamePageAsTheOneAtRegistrationInEveryLanguage() {
        for language in languages {
            XCTAssertEqual(LegalLinks.privacyPolicy(languageCode: language),
                           LegalLinks.appPrivacy(languageCode: language),
                           "language \"\(language)\"")
        }
    }

    func test_thePrivacyLinkIsOnTheDocumentHostWithItalianUnderItsOwnRoute() {
        XCTAssertEqual(LegalLinks.privacyPolicy(languageCode: "it").absoluteString,
                       "https://bcrypto.com/it/legal/qaudion-privacy")
        XCTAssertEqual(LegalLinks.privacyPolicy(languageCode: "it-IT").absoluteString,
                       "https://bcrypto.com/it/legal/qaudion-privacy")
        for language in ["en", "de", "es", "fr", "pt-BR", "ja", ""] {
            XCTAssertEqual(LegalLinks.privacyPolicy(languageCode: language).absoluteString,
                           "https://bcrypto.com/legal/qaudion-privacy", "language \"\(language)\"")
        }
    }

    func test_thePrivacyLinkNeverPointsAtTheProductSite() {
        for language in languages {
            let host = LegalLinks.privacyPolicy(languageCode: language).host ?? ""
            XCTAssertFalse(host.contains("q-audion.com"), "language \"\(language)\": \(host)")
        }
    }

    func test_theAccountDeletionPageStaysOnTheProductSiteWithTheSiteLocales() {
        for language in ["en", "it", "fr", "de", "es"] {
            XCTAssertEqual(LegalLinks.deleteAccount(languageCode: language).absoluteString,
                           "https://www.q-audion.com/" + language + "/legal/delete-account", language)
        }
        XCTAssertEqual(LegalLinks.deleteAccount(languageCode: "pt-BR").absoluteString,
                       "https://www.q-audion.com/en/legal/delete-account", "a language the site lacks falls back to English")
        XCTAssertEqual(LegalLinks.deleteAccount(languageCode: "de-AT").absoluteString,
                       "https://www.q-audion.com/de/legal/delete-account")
    }

    func test_theHostsTheAppMayOpenFromAServerLinkAreUnchanged() throws {
        XCTAssertTrue(LegalLinks.isAllowedExternalLink(try XCTUnwrap(URL(string: "https://bcrypto.com/legal/qaudion-privacy"))))
        XCTAssertTrue(LegalLinks.isAllowedExternalLink(try XCTUnwrap(URL(string: "https://www.q-audion.com/en/legal/delete-account"))))
        XCTAssertFalse(LegalLinks.isAllowedExternalLink(try XCTUnwrap(URL(string: "http://bcrypto.com/legal/qaudion-privacy"))),
                       "plain http is refused")
        XCTAssertFalse(LegalLinks.isAllowedExternalLink(try XCTUnwrap(URL(string: "https://example.org/privacy"))))
    }
}
