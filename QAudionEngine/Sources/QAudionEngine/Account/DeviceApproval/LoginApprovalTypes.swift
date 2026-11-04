import Foundation

/// What a password sign-in answered: a session, or "a device of the account must approve this one first".
public enum LoginOutcome {
    case credentials(AuthCredentials)
    case approvalRequired(PendingLoginTicket)
}

/// What the new device asks the person after an approved sign-in. `keep` after an approval from another
/// device, `disconnectAll` after a recovery by email, SMS or the administrator (nobody vouched for the
/// request from a known device, so the default is to cut the others off).
public enum RevokePrompt: String, Equatable, Sendable {
    case keep
    case disconnectAll = "disconnect_all"

    public init(wire: Any?) {
        self = (wire as? String) == RevokePrompt.disconnectAll.rawValue ? .disconnectAll : .keep
    }
}

/// The 202 answer of a sign-in that needs approval. The poll token is a secret of this screen only.
public struct PendingLoginTicket: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let pendingId: String
    public let pollToken: String
    /// Two digits shown big on the new device; the person picks the same number on the approving device.
    public let matchCode: String
    public let expiresAt: Date
    /// 8 characters the administrator can approve with.
    public let shortCode: String
    public let emailRecovery: Bool
    public let smsRecovery: Bool
    /// Masked, never the address itself ("m***@g***.com"); nil when the server sent none.
    public let emailHint: String?
    public let phoneHint: String?

    public init(pendingId: String, pollToken: String, matchCode: String, expiresAt: Date, shortCode: String,
                emailRecovery: Bool, smsRecovery: Bool, emailHint: String? = nil, phoneHint: String? = nil) {
        self.pendingId = pendingId
        self.pollToken = pollToken
        self.matchCode = matchCode
        self.expiresAt = expiresAt
        self.shortCode = shortCode
        self.emailRecovery = emailRecovery
        self.smsRecovery = smsRecovery
        self.emailHint = emailHint
        self.phoneHint = phoneHint
    }

    public var description: String { "PendingLoginTicket(pollToken: <redacted>, expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
}

// All stored properties are immutable values.
extension AuthCredentials: @unchecked Sendable {}

/// A session handed out by an approved pending sign-in.
public struct ApprovedLogin: Sendable {
    public let credentials: AuthCredentials
    public let revokePrompt: RevokePrompt

    public init(credentials: AuthCredentials, revokePrompt: RevokePrompt) {
        self.credentials = credentials
        self.revokePrompt = revokePrompt
    }
}

/// Reading of the server's JSON for the device-approval flow. Tolerant about number/string types and date
/// formats so a server detail (ISO text, seconds or milliseconds) does not break the screen.
public enum ApprovalWire {
    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The lowercased `error` text of a `{"error": ...}` answer, empty when there is none.
    public static func errorCode(_ data: Data) -> String {
        (object(data)?["error"] as? String)?.lowercased() ?? ""
    }

    public static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    public static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let parsed = formatter.date(from: text) { return parsed }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: text) { return parsed }
            if let number = Double(text) { return epoch(number) }
            return nil
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return epoch(number.doubleValue) }
        return nil
    }

    /// Milliseconds when the number is too large to be seconds.
    private static func epoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    /// `user_id` (or `sub`/`uid`) from the unverified payload of a JWT. Only used to name the account of a
    /// session the server just issued; nothing is trusted from it.
    public static func userId(fromJwt token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64), let payload = object(data) else { return nil }
        for key in ["user_id", "sub", "uid"] {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The 202 body. Nil when a required field is missing.
    public static func ticket(from object: [String: Any]) -> PendingLoginTicket? {
        guard let pendingId = string(object["pending_id"]), !pendingId.isEmpty,
              let pollToken = string(object["poll_token"]), !pollToken.isEmpty,
              let matchCode = string(object["match_code"]), !matchCode.isEmpty,
              let expiresAt = date(object["expires_at"]) else { return nil }
        let recovery = object["recovery"] as? [String: Any]
        return PendingLoginTicket(
            pendingId: pendingId,
            pollToken: pollToken,
            matchCode: matchCode,
            expiresAt: expiresAt,
            shortCode: string(object["short_code"]) ?? "",
            emailRecovery: (recovery?["email"] as? Bool) ?? false,
            smsRecovery: (recovery?["sms"] as? Bool) ?? false,
            emailHint: string(recovery?["email_hint"]),
            phoneHint: string(recovery?["sms_hint"] ?? recovery?["phone_hint"]))
    }

    /// The normal login pair (poll answer after the approval). The pair has no `user_id` in the contract,
    /// so it is read from the access token when the body has none.
    public static func approvedLogin(from object: [String: Any]) -> ApprovedLogin? {
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let deviceId = string(object["device_id"]), !deviceId.isEmpty else { return nil }
        guard let userId = string(object["user_id"]) ?? userId(fromJwt: access) else { return nil }
        let credentials = AuthCredentials(
            userId: userId,
            deviceId: deviceId,
            accessToken: access,
            refreshToken: object["refresh_token"] as? String,
            expiresIn: (object["expires_in"] as? NSNumber)?.intValue)
        return ApprovedLogin(credentials: credentials, revokePrompt: RevokePrompt(wire: object["revoke_prompt"]))
    }
}

extension LoginOutcome {
    /// Maps a sign-in answer. 202 (or a body that says `approval_required`) is the pending state, any other
    /// 2xx is a session; the refusals keep the errors the screens already know.
    static func parse(status: Int, data: Data) throws -> LoginOutcome {
        if (200...299).contains(status) {
            let object = ApprovalWire.object(data)
            if status == 202 || (object?["status"] as? String) == "approval_required" {
                guard let object, let ticket = ApprovalWire.ticket(from: object) else { throw BCryptoError.decodingError }
                return .approvalRequired(ticket)
            }
            return .credentials(try JSONDecoder().decode(AuthCredentials.self, from: data))
        }
        if status == 401 { throw BCryptoError.unauthorized }
        if status == 402 { throw BCryptoError.paymentRequired }
        if status == 400, let refusal = BCryptoTermsRefusal(responseBody: data) { throw refusal }
        throw BCryptoError.httpError(status)
    }
}

/// Domain-tagged blobs the approving device signs with its device key. Layout, like the revoke blob:
/// `tag || 0x00 || serverID || 0x00 || subjectID || 0x00 || approverDeviceID || 0x00 || nonce(32)`.
/// The tags are prefix-disjoint from the renew and revoke tags (pinned by a test).
public enum DeviceApprovalBlob {
    public static let tagApprove = "QAUDION-APPROVE-v1"
    public static let tagDeny = "QAUDION-DENY-v1"
    public static let tagRevokeOthers = DeviceRenewBlob.domainTagRevokeOthers

    public static func build(tag: String, serverId: String, pendingId: String, approverDeviceId: String,
                             nonce: Data) -> Data {
        var out = Data()
        for part in [tag, serverId, pendingId, approverDeviceId] {
            out.append(contentsOf: part.utf8)
            out.append(0x00)
        }
        out.append(nonce)
        return out
    }
}
