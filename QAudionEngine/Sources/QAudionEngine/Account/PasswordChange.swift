import Foundation

/// Answer of `POST /api/v1/account/password`: the whole new session of this device. The previous
/// pair is no longer valid, so the caller replaces both tokens and the device id.
public struct PasswordChangeResult: Codable, Sendable, CustomStringConvertible {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int?
    public let deviceId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case deviceId = "device_id"
    }

    public init(accessToken: String, refreshToken: String, expiresIn: Int?, deviceId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.deviceId = deviceId
    }

    /// Never prints the tokens.
    public var description: String {
        "PasswordChangeResult(accessToken: <redacted>, refreshToken: <redacted>, expiresIn: \(String(describing: expiresIn)), deviceId: \(deviceId))"
    }
}

/// Why a password change did not happen. One case per server answer the screen words differently.
public enum ChangePasswordError: Error, Equatable, Sendable {
    case invalidRequest
    case tooShort
    case tooLong
    case common
    case containsIdentity
    case unchanged
    /// 401 `invalid credentials`: the current password is wrong.
    case wrongCurrent
    /// 401 `unauthorized`: the session is not valid any more.
    case sessionExpired
    /// 403 `password_login_unavailable`: this account does not sign in with a password.
    case unavailable
    /// Any other 403 (account locked).
    case locked
    case rateLimited(retryAfterSec: Int?)
    case serviceUnavailable(retryAfterSec: Int?)
    case server(Int)
    case malformedResponse

    /// Reads the `{"error": code}` body of a non-2xx answer. Nothing but the status, the code and the
    /// `Retry-After` value is looked at.
    public static func map(status: Int, body: Data, retryAfter: String?) -> ChangePasswordError {
        let code = errorCode(in: body)
        switch status {
        case 400:
            switch code {
            case "password_too_short": return .tooShort
            case "password_too_long": return .tooLong
            case "password_common": return .common
            case "password_contains_identity": return .containsIdentity
            case "password_unchanged": return .unchanged
            default: return .invalidRequest
            }
        case 401:
            return code == "invalid credentials" ? .wrongCurrent : .sessionExpired
        case 403:
            return code == "password_login_unavailable" ? .unavailable : .locked
        case 429:
            return .rateLimited(retryAfterSec: BCryptoRateLimitedError.parse(retryAfter))
        case 503:
            return .serviceUnavailable(retryAfterSec: BCryptoRateLimitedError.parse(retryAfter))
        default:
            return .server(status)
        }
    }

    static func errorCode(in body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["error"] as? String
    }
}

/// The rules a new password must pass before it is sent: the same limits as the server, so the
/// screen can say so without a round trip. No composition rules.
public enum PasswordPolicy {
    public static let minLength = 8
    public static let maxLength = 64
    public static let maxBytes = 72

    /// `nil` when the length rules are met. Counted in Unicode scalars (runes) after NFC, like the server.
    public static func lengthProblem(_ password: String) -> ChangePasswordError? {
        let normalized = password.precomposedStringWithCanonicalMapping
        let scalars = normalized.unicodeScalars.count
        if scalars < minLength { return .tooShort }
        if scalars > maxLength || normalized.utf8.count > maxBytes { return .tooLong }
        return nil
    }
}

/// Decides whether a `password_changed` notice is news: the device that made the change gets the notice
/// too, a moment after its own success, and must not show the "changed elsewhere" banner.
public enum PasswordChangedNoticeFilter {
    public static let localWindow: TimeInterval = 15

    public static func shouldShow(now: Date, lastLocalChange: Date?,
                                  noticeDeviceId: String?, ownDeviceId: String?) -> Bool {
        if let n = noticeDeviceId, !n.isEmpty, let o = ownDeviceId, n == o { return false }
        if let last = lastLocalChange {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0 && elapsed <= localWindow { return false }
        }
        return true
    }
}
