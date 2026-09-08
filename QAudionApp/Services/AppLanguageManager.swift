import Foundation
import ObjectiveC

/// In-app language override, independent of iOS's own per-app-language
/// picker (Settings.app -> General -> Language & Region -> per-app
/// language) — that OS-level control exists but is not discoverable
/// enough on its own, so this gives the same outcome from inside the app.
///
/// Primitives + closures only, NEVER an `AppState` parameter — see
/// CLAUDE.md §16 "NEVER take AppState as a direct parameter type in a NEW
/// Swift file" (a documented silent Build-IPA failure, 13 build cycles to
/// bisect). Shape mirrors `CarPlayBridge`/`LiveLogStreamer`.
///
/// The bundle-swizzle below relies on Xcode's build system producing a
/// `<code>.lproj`-shaped lookup bundle for each declared language — true
/// for a String-Catalog-based project too: Xcode compiles `.xcstrings`
/// back into `.strings`/`.stringsdict` resources per language at build
/// time (documented Xcode 15+ behavior, same lookup-bundle shape a classic
/// strings-file project produces), so `Bundle(path:)` on a `<code>.lproj`
/// folder inside the built app resolves correctly once
/// `Localizable.xcstrings` is populated and the app is actually built.
@MainActor
public final class AppLanguageManager {

    public static let shared = AppLanguageManager()

    private init() {}

    // MARK: - Supported languages

    /// `nonisolated` — same reasoning as the block below: read from a
    /// non-isolated `Bundle` override, and a plain array-of-Strings
    /// literal has no actor-isolation-relevant state to protect anyway.
    public nonisolated static let supportedLanguages: [(code: String, nativeName: String)] = [
        ("it", "Italiano"),
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("pt-BR", "Português (Brasil)"),
    ]

    private nonisolated static let defaultsKey = "QAudionAppLanguageOverride"

    /// The app's real base language (`CFBundleDevelopmentRegion` in
    /// Info.plist). Fallback target when the system language isn't one of
    /// the 6 supported codes — deliberately NOT "en", since this app's
    /// actual authored-in-source strings are Italian.
    private nonisolated static let appBaseLanguage = "it"

    // MARK: - Override state
    //
    // `nonisolated` deliberately: `QAudionLocalizedBundle.localizedString`
    // below overrides a plain, non-isolated, synchronous Foundation API —
    // Swift does not allow re-isolating that override to @MainActor, so it
    // must call these from a non-isolated context. Every read here is
    // UserDefaults/Locale/array-literal access, none of it actually
    // requires main-thread exclusivity; only `setOverride` and the swizzle
    // install/revert (which fire UI callbacks and mutate the Bundle
    // runtime class) stay MainActor-isolated below.

    /// `nil` means "follow system" — the default, unset state.
    public nonisolated static var currentOverride: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// The override if one is set and still supported, else the closest
    /// supported match to the system's preferred language, else the app's
    /// own base language.
    public nonisolated static var effectiveLanguageCode: String {
        if let override = currentOverride,
           supportedLanguages.contains(where: { $0.code == override }) {
            return override
        }
        return closestSupportedCode(from: Locale.preferredLanguages.first) ?? appBaseLanguage
    }

    /// Exact match first (covers "pt-BR" itself); otherwise strips the
    /// region/script subtag and retries on the bare language subtag (e.g.
    /// "en-GB" -> "en"), and ALSO checks whether a supported code's own
    /// bare-language prefix matches (e.g. system "pt" or "pt-PT" must still
    /// resolve to the supported "pt-BR", not fall through to the Italian
    /// base language just because "pt-BR" isn't a bare 2-letter code).
    /// No match at all -> nil, caller falls back to `appBaseLanguage`.
    private nonisolated static func closestSupportedCode(from preferred: String?) -> String? {
        guard let preferred else { return nil }
        let supportedCodes = Set(supportedLanguages.map(\.code))
        if supportedCodes.contains(preferred) { return preferred }
        let bareLanguage = String(preferred.prefix(while: { $0 != "-" }))
        if supportedCodes.contains(bareLanguage) { return bareLanguage }
        if let match = supportedLanguages.first(where: { $0.code.hasPrefix(bareLanguage + "-") }) {
            return match.code
        }
        return nil
    }

    /// Fired after `setOverride(_:)` changes the effective language.
    /// UI layer hook — same pattern as `CarPlayBridge.onCarPlayConnected`.
    public static var onLanguageChanged: (() -> Void)?

    // MARK: - Bundle swizzle

    private static var isSwizzled = false

    /// Call once at app launch, before any UI renders. No-op if no
    /// override is stored — system locale resolution is untouched.
    public static func installOverrideIfNeeded() {
        guard currentOverride != nil else { return }
        installSwizzledBundle()
    }

    /// Persist the new override, (un)install the bundle swizzle to match,
    /// and notify the UI layer to rebuild its view tree.
    public static func setOverride(_ code: String?) {
        currentOverride = code
        if code != nil {
            installSwizzledBundle()
        } else {
            revertSwizzledBundle()
        }
        onLanguageChanged?()
    }

    private static func installSwizzledBundle() {
        guard !isSwizzled else { return }
        object_setClass(Bundle.main, QAudionLocalizedBundle.self)
        isSwizzled = true
    }

    private static func revertSwizzledBundle() {
        guard isSwizzled else { return }
        object_setClass(Bundle.main, Bundle.self)
        isSwizzled = false
    }
}

/// Swapped onto `Bundle.main`'s runtime class via `object_setClass` so
/// every `NSLocalizedString` / `String(localized:)` / `Text(_:)` lookup in
/// the app transparently resolves against the overridden language from
/// that point on — zero call-site changes anywhere else in the app. This
/// is the standard decade-old Obj-C runtime technique for an in-app
/// language switch, not a novel API.
private final class QAudionLocalizedBundle: Bundle {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let path = Bundle.main.path(forResource: AppLanguageManager.effectiveLanguageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}
