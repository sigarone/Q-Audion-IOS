import Foundation

/// The age declaration a person makes when creating an account, and the acceptance of the Terms that travels with it.
///
/// The server reads two optional keys on the self-service registration endpoints (`/auth/otp/verify` with
/// purpose `register`, `/auth/register/extension`, `/register`, `/register/sovereign`): `age_declaration`, true when
/// the box was ticked, and `terms_acceptance`, the object built by ``TermsAcceptance`` (version and digest of the
/// document shown, one flag per box, the professional answer). A registration without a valid `terms_acceptance`
/// is refused with `400 terms_acceptance_required`. The client sends `age_declaration` only as `true`, never as
/// `false`. Nothing here verifies the age, it is what the person declares.
public enum AgeDeclaration {

    /// The age the declaration states.
    public static let minimumAge = 18

    static let declarationKey = "age_declaration"
    static let termsAcceptanceKey = "terms_acceptance"

    /// Adds the declaration to a registration body when the box was ticked, and the acceptance when there is one.
    static func add(to body: inout [String: Any], declared: Bool, acceptance: TermsAcceptance?) {
        if declared { body[declarationKey] = true }
        if let acceptance { body[termsAcceptanceKey] = acceptance.wireObject }
    }
}
