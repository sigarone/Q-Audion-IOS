import Foundation

/// The age declaration a person makes when creating an account.
///
/// The server reads two optional keys on the self-service registration endpoints (`/auth/otp/verify` with
/// purpose `register`, `/auth/register/extension`, `/register`, `/register/sovereign`): `age_declaration`, true when
/// the box was ticked, and `terms_version`, the version of the Terms accepted with it (read only together with
/// `true`). The client sends both keys when the box is ticked and neither when it is not: it never sends `false` and
/// never one key without the other. Nothing here verifies the age, it is what the person declares.
public enum AgeDeclaration {

    /// The age the declaration states.
    public static let minimumAge = 18

    /// Last-updated date of the Terms the declaration accepts. It changes together with the Terms, and it is the
    /// value Android sends. The server takes up to 32 letters, digits, `.`, `_` and `-`.
    public static let termsVersion = "2026-08-05"

    static let declarationKey = "age_declaration"
    static let termsVersionKey = "terms_version"

    /// Adds the declaration to a registration body, and only when the box was ticked.
    static func add(to body: inout [String: Any], declared: Bool) {
        guard declared else { return }
        body[declarationKey] = true
        body[termsVersionKey] = termsVersion
    }
}
