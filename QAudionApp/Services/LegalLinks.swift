import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// App Store 5.1.1(i) / 5.1.1(v) — the ONE place that knows where the
/// privacy policy and the account-deletion page live, so the in-app links
/// (Settings > Info, Informazioni > Assistenza, the Welcome footer, the
/// Account screen) and the URLs typed into App Store Connect can never
/// drift apart. Same pages the Play listing already uses.
///
/// One privacy URL for the whole app: `privacyPolicy()` is the same page as
/// `appPrivacy()` (the one linked from the age declaration at registration),
/// so every place that shows the policy shows the same text.
///
/// Locale rule: the app's documents (terms, privacy) are served with Italian
/// under `/it` and every other language from the route without a prefix. The
/// account-deletion page is served by the product site under /en, /it, /fr,
/// /de, /es; the in-app language is mapped onto that set and anything the site
/// does not have falls back to English, which is also the canonical URL entered
/// in App Store Connect.
enum LegalLinks {
    private static let host = "https://www.q-audion.com"
    private static let siteLocales: Set<String> = ["en", "it", "fr", "de", "es"]

    /// Hosts the app is allowed to open from server-provided links
    /// (admin banner CTA). Everything else is dropped.
    private static let allowedExternalHosts: Set<String> = [
        "q-audion.com", "www.q-audion.com",
        "bcrypto.com", "www.bcrypto.com",
    ]

    /// The privacy policy of the app (Settings, About, Welcome): the same page as `appPrivacy`, one URL for the app.
    static func privacyPolicy(languageCode: String = AppLanguageManager.effectiveLanguageCode) -> URL {
        appPrivacy(languageCode: languageCode)
    }

    /// The account-deletion page. It lives on the product site: the document host has no deletion page for the app.
    static func deleteAccount(languageCode: String = AppLanguageManager.effectiveLanguageCode) -> URL {
        page("delete-account", languageCode: languageCode)
    }

    /// The Terms and the Privacy Policy linked from the age declaration at registration. Same pages and same
    /// rule as Android: Italian is served under `/it`, every other language from the route without a prefix.
    static func appTerms(languageCode: String = AppLanguageManager.effectiveLanguageCode) -> URL {
        appDocument("qaudion-terms", languageCode: languageCode)
    }

    static func appPrivacy(languageCode: String = AppLanguageManager.effectiveLanguageCode) -> URL {
        appDocument("qaudion-privacy", languageCode: languageCode)
    }

    private static func appDocument(_ section: String, languageCode: String) -> URL {
        let base = languageCode.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        let prefix = base == "it" ? "/it" : ""
        // Constant host and path segments: the force-unwrap can only fail on a typo in this file.
        return URL(string: "https://bcrypto.com" + prefix + "/legal/" + section)!
    }

    private static func page(_ section: String, languageCode: String) -> URL {
        let base = languageCode.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        let locale = siteLocales.contains(base) ? base : "en"
        // Both segments are compile-time constants from a fixed set, so the
        // force-unwrap can only fail on a typo in this file.
        return URL(string: host + "/" + locale + "/legal/" + section)!
    }

    static func isAllowedExternalLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let h = url.host?.lowercased() else { return false }
        return allowedExternalHosts.contains(h)
    }

    @MainActor
    static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}
