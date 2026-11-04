import Foundation

/// How a pending sign-in is doing, as the poll answers.
public enum PendingLoginPoll: Sendable {
    case pending
    /// The pair of a sign-in that was approved. Single use: the next poll answers `.expired` or a refusal.
    case approved(ApprovedLogin)
    case denied
    case expired
    /// The poll came too soon (HTTP 429); ask again after `retryAfter` seconds.
    case tooFast(retryAfter: TimeInterval)
    /// 401 `session revoked, sign in again`: the entry was approved but the account's sessions were revoked in
    /// between, so the pair cannot be handed out. Polling again would only end in "expired".
    case sessionRevoked
}

public enum RecoveryChannel: String, Sendable {
    case email
    case sms
}

/// Why the recovery by code did not go through.
public enum PendingLoginRecoveryError: Error, Equatable, Sendable {
    /// Not the code, or no code was asked for.
    case invalidCode
    /// Too many tries on this code (5): ask for a new one.
    case tooManyAttempts
    /// 429: codes or tries are throttled.
    case rateLimited(retryAfter: TimeInterval?)
    /// The user has no verified contact for this channel.
    case channelUnavailable
    case denied
    /// The whole entry is over (410 `expired`).
    case expired
    /// 410 `code expired or not found`: only the code is gone, the entry may still be pending. Ask for a new one.
    case codeExpired
    case server(status: Int)
}

/// The three public calls of the waiting screen. No bearer: the poll token proves it is the same screen.
public protocol PendingLoginApi: Sendable {
    /// `POST /api/v1/auth/login/pending`.
    func poll(pendingId: String, pollToken: String) async throws -> PendingLoginPoll
    /// `POST /api/v1/auth/login/pending/recover`: sends a 6-digit code to the verified contact.
    func requestRecoveryCode(pendingId: String, pollToken: String, channel: RecoveryChannel) async throws
    /// `POST /api/v1/auth/login/pending/recover/verify`: on success the entry is approved; the next poll
    /// returns the session.
    func verifyRecoveryCode(pendingId: String, pollToken: String, code: String) async throws
}

public final class BCryptoPendingLoginApi: PendingLoginApi, @unchecked Sendable {
    private let rest: BCryptoRestClient
    /// Keeps what the client depends on alive (the provider the app built it from).
    private let retained: AnyObject?

    static let pollPath = "/api/v1/auth/login/pending"
    static let recoverPath = "/api/v1/auth/login/pending/recover"
    static let verifyPath = "/api/v1/auth/login/pending/recover/verify"

    /// A client without a token for the waiting screen (the device has no session yet).
    public init(rest: BCryptoRestClient, retaining: AnyObject? = nil) {
        self.rest = rest
        self.retained = retaining
    }

    public func poll(pendingId: String, pollToken: String) async throws -> PendingLoginPoll {
        let answer = try await rest.postRaw(Self.pollPath, body: Self.body(pendingId, pollToken))
        return try Self.parsePoll(status: answer.status, data: answer.data, retryAfter: answer.retryAfter)
    }

    public func requestRecoveryCode(pendingId: String, pollToken: String, channel: RecoveryChannel) async throws {
        let body = Self.body(pendingId, pollToken, ["channel": channel.rawValue])
        let answer = try await rest.postRaw(Self.recoverPath, body: body)
        if let error = Self.recoveryError(status: answer.status, data: answer.data, retryAfter: answer.retryAfter) { throw error }
    }

    public func verifyRecoveryCode(pendingId: String, pollToken: String, code: String) async throws {
        let body = Self.body(pendingId, pollToken, ["code": code])
        let answer = try await rest.postRaw(Self.verifyPath, body: body)
        if let error = Self.recoveryError(status: answer.status, data: answer.data, retryAfter: answer.retryAfter) { throw error }
    }

    static func body(_ pendingId: String, _ pollToken: String, _ extra: [String: Any] = [:]) -> Data? {
        var dict: [String: Any] = ["pending_id": pendingId, "poll_token": pollToken]
        for (key, value) in extra { dict[key] = value }
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    static func parsePoll(status: Int, data: Data, retryAfter: String?) throws -> PendingLoginPoll {
        switch status {
        case 200...299:
            guard let object = ApprovalWire.object(data) else { throw BCryptoError.decodingError }
            if object["access_token"] != nil {
                guard let approved = ApprovalWire.approvedLogin(from: object) else { throw BCryptoError.decodingError }
                return .approved(approved)
            }
            return .pending
        case 403: return .denied
        case 401: return .sessionRevoked
        // 404: the entry is gone (swept after the end); the same thing for the person as an expired one.
        case 404, 410: return .expired
        case 429:
            return .tooFast(retryAfter: BCryptoRateLimitedError.parse(retryAfter).map(TimeInterval.init) ?? 3)
        default: throw BCryptoError.httpError(status)
        }
    }

    /// Nil on success. The server's `{"error": code}` decides when it names the problem; the status otherwise.
    static func recoveryError(status: Int, data: Data, retryAfter: String?) -> PendingLoginRecoveryError? {
        if (200...299).contains(status) { return nil }
        let code = (ApprovalWire.object(data)?["error"] as? String)?.lowercased() ?? ""
        switch status {
        case 429:
            // 5 wrong codes: "too many attempts, request a new code". The other 429s are throttles.
            if code.contains("attempt") { return .tooManyAttempts }
            return .rateLimited(retryAfter: BCryptoRateLimitedError.parse(retryAfter).map(TimeInterval.init))
        case 410, 404:
            // "code expired or not found, request a new one" is about the code only; a plain "expired" (or
            // anything else) is the entry itself.
            if code.contains("code") { return .codeExpired }
            return .expired
        case 403:
            if code.contains("denied") { return .denied }
            if code.contains("attempt") { return .tooManyAttempts }
            return .invalidCode
        case 400, 401, 422:
            if code.contains("attempt") { return .tooManyAttempts }
            if code.contains("channel") || code.contains("unavailable") || code.contains("no_") { return .channelUnavailable }
            return .invalidCode
        case 409:
            return .channelUnavailable
        default:
            return .server(status: status)
        }
    }
}
