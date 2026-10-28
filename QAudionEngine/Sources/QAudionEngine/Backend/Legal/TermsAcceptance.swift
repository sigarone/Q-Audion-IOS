import Foundation

/// What a person accepted, in the shape the server stores it (`terms_acceptance` of every registration request
/// and the body of `POST /api/v1/legal/accept`).
///
/// Both boxes are true: `terms` (Terms and Privacy Policy) and `specific` (the features of art. 21.1-bis and the
/// specific approval of arts. 1341-1342 c.c.).
public struct TermsAcceptance: Equatable, Sendable {
    public let version: String
    public let lang: String
    public let sha256: String
    public let terms: Bool
    public let specific: Bool
    /// Where the acceptance was made: `ios`, and the build of the app (short version, a dot, the build number).
    public let platform: String
    public let appVersion: String

    public static let platformName = "ios"

    /// `CFBundleShortVersionString` + "." + `CFBundleVersion`, reduced to the characters the server accepts
    /// (letters, digits and `._-+`, at most 64); "unknown" when the bundle has neither.
    public static func appVersionString(short: String?, build: String?) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+")
        let parts = [short, build].compactMap { $0 }.map { String($0.filter { allowed.contains($0) }) }.filter { !$0.isEmpty }
        let joined = String(parts.joined(separator: ".").prefix(64))
        return joined.isEmpty ? "unknown" : joined
    }

    public static var currentAppVersion: String {
        appVersionString(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    public init(version: String, lang: String, sha256: String, terms: Bool, specific: Bool,
                platform: String = TermsAcceptance.platformName, appVersion: String = TermsAcceptance.currentAppVersion) {
        self.version = version
        self.lang = lang
        self.sha256 = sha256
        self.terms = terms
        self.specific = specific
        self.platform = platform
        self.appVersion = appVersion
    }

    /// The JSON object of the acceptance. Booleans stay JSON booleans.
    public var wireObject: [String: Any] {
        [
            "version": version,
            "lang": lang,
            "sha256": sha256,
            "terms": terms,
            "specific": specific,
            "platform": platform,
            "app_version": appVersion,
        ]
    }

    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: wireObject, options: [.sortedKeys])
    }
}

/// The two boxes of the acceptance screen, both off at the start.
///
/// `canContinue` is the whole gate of the continue button; `acceptance(for:)` builds the request body and
/// returns nil unless both boxes are on.
public struct TermsAcceptanceDraft: Equatable, Sendable {
    public var termsAccepted = false
    public var specificAccepted = false

    public init() {}

    public var canContinue: Bool { termsAccepted && specificAccepted }

    /// The acceptance to send, or nil while a box is off.
    public func acceptance(for fetch: LegalTermsFetch) -> TermsAcceptance? {
        guard canContinue else { return nil }
        let document = fetch.document
        return TermsAcceptance(
            version: document.version, lang: document.lang, sha256: fetch.sha256, terms: true, specific: true)
    }
}
