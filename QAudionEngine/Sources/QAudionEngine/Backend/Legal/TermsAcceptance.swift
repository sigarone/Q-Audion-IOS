import Foundation

/// What a person accepted, in the shape the server stores it (`terms_acceptance` of every registration request
/// and the body of `POST /api/v1/legal/accept`).
///
/// Every box is true except `professional`, the answer to "I use the service for my professional activity".
public struct TermsAcceptance: Equatable, Sendable {
    public let version: String
    public let lang: String
    public let sha256: String
    public let terms: Bool
    public let deviations: Bool
    public let groups: [String: Bool]
    public let professional: Bool
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

    public init(version: String, lang: String, sha256: String, terms: Bool, deviations: Bool,
                groups: [String: Bool], professional: Bool,
                platform: String = TermsAcceptance.platformName, appVersion: String = TermsAcceptance.currentAppVersion) {
        self.version = version
        self.lang = lang
        self.sha256 = sha256
        self.terms = terms
        self.deviations = deviations
        self.groups = groups
        self.professional = professional
        self.platform = platform
        self.appVersion = appVersion
    }

    /// The JSON object of the acceptance. Booleans stay JSON booleans.
    public var wireObject: [String: Any] {
        var groupObject: [String: Any] = [:]
        for (id, value) in groups { groupObject[id] = value }
        return [
            "version": version,
            "lang": lang,
            "sha256": sha256,
            "terms": terms,
            "deviations": deviations,
            "groups": groupObject,
            "professional": professional,
            "platform": platform,
            "app_version": appVersion,
        ]
    }

    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: wireObject, options: [.sortedKeys])
    }
}

/// The three steps of the acceptance, in the order they are shown, with every box off at the start.
///
///  1. `deviations`: the text of art. 21.1-bis and its own box;
///  2. `terms`: the document, its box and the professional question (default no);
///  3. `groups`: the six groups, each with its own box.
///
/// `canContinue` is the whole gate of the continue button; `acceptance(for:)` builds the request body and
/// returns nil unless every required box is on.
public struct TermsAcceptanceDraft: Equatable, Sendable {
    public enum Step: Int, Equatable, Sendable, CaseIterable {
        case deviations
        case terms
        case groups
    }

    public private(set) var step: Step = .deviations
    public var deviationsAccepted = false
    public var termsAccepted = false
    public var professional = false
    public private(set) var groupAccepted: [String: Bool] = [:]

    public init() {}

    public func isGroupAccepted(_ id: String) -> Bool { groupAccepted[id] ?? false }

    public mutating func setGroup(_ id: String, accepted: Bool) { groupAccepted[id] = accepted }

    public func canContinue(document: LegalTermsDocument) -> Bool {
        switch step {
        case .deviations: return deviationsAccepted
        case .terms: return termsAccepted
        case .groups: return allGroupsAccepted(document: document)
        }
    }

    public func allGroupsAccepted(document: LegalTermsDocument) -> Bool {
        !document.groups.isEmpty && document.groups.allSatisfy { isGroupAccepted($0.id) }
    }

    /// True on the last step: the continue button there completes the acceptance.
    public var isLastStep: Bool { step == .groups }

    /// Moves to the next step when the current one is complete. Returns true when it moved.
    @discardableResult
    public mutating func advance(document: LegalTermsDocument) -> Bool {
        guard canContinue(document: document), let next = Step(rawValue: step.rawValue + 1) else { return false }
        step = next
        return true
    }

    /// Back one step. The boxes already ticked stay as they are.
    @discardableResult
    public mutating func back() -> Bool {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return false }
        step = previous
        return true
    }

    /// The acceptance to send, or nil while a required box is off.
    public func acceptance(for fetch: LegalTermsFetch) -> TermsAcceptance? {
        let document = fetch.document
        guard deviationsAccepted, termsAccepted, allGroupsAccepted(document: document) else { return nil }
        var groups: [String: Bool] = [:]
        for group in document.groups { groups[group.id] = true }
        return TermsAcceptance(
            version: document.version, lang: document.lang, sha256: fetch.sha256,
            terms: true, deviations: true, groups: groups, professional: professional)
    }
}
