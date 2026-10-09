import Foundation

/// HTTP 403 from a registration endpoint (`/auth/register/extension`,
/// `/auth/otp/verify`) when the server runs with `registration_mode="invite"`.
/// A separate type, not a case of `BCryptoError`: that enum is switched
/// exhaustively across the app, and `performRequest` discards the body of every
/// other non-2xx status, so the reason can only be told apart here.
public struct BCryptoInviteCodeError: Error, Sendable, Equatable {

    public enum Reason: Sendable, Equatable {
        /// Server message "invite code required" / "invite_code required".
        case required
        /// Server message "invalid or expired invite code".
        case invalid
    }

    public let reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }

    /// Classifies the body of a 403 (`{"error":"..."}`). Returns nil when the
    /// message is not about the invite code, so any other 403 keeps arriving
    /// as `BCryptoError.httpError(403)`.
    init?(forbiddenBody data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (obj["error"] as? String)?.lowercased(),
              message.contains("invite") else { return nil }
        if message.contains("required") {
            self.reason = .required
        } else if message.contains("invalid") || message.contains("expired") {
            self.reason = .invalid
        } else {
            return nil
        }
    }

    /// Text shown to the user. Resolved from the app's string catalog; the
    /// default value is the Italian source text.
    public var userFacingMessage: String {
        switch reason {
        case .required:
            return String(localized: "error.invite_code_required", defaultValue: "Serve un codice invito", comment: "Registration refused by the server because no invite code was sent.")
        case .invalid:
            return String(localized: "error.invite_code_invalid", defaultValue: "Codice invito non valido o scaduto", comment: "Registration refused by the server because the invite code is invalid, expired, revoked or already used.")
        }
    }
}
