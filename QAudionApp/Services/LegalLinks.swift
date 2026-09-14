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
/// Locale rule: the site is served under /en, /it, /fr, /de, /es (see
/// qaudion-website/i18n/routing.ts). The in-app language is mapped onto
/// that set; anything the site does not have falls back to English, which
/// is also the canonical URL entered in App Store Connect.
enum LegalLinks {
    private static let host = "https://www.q-audion.com"
    private static let siteLocales: Set<String> = ["en", "it", "fr", "de", "es"]

    /// Hosts the app is allowed to open from server-provided links
    /// (admin banner CTA). Everything else is dropped.
    private static let allowedExternalHosts: Set<String> = [
        "q-audion.com", "www.q-audion.com",
        "bcrypto.com", "www.bcrypto.com",
    ]

    static func privacyPolicy(languageCode: String = AppLanguageManager.effectiveLanguageCode) -> URL {
        page("privacy", languageCode: languageCode)
    }

    static func deleteAccount(languageCode: String = AppLanguageManager.effectiveLanguageCode) -> URL {
        page("delete-account", languageCode: languageCode)
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
