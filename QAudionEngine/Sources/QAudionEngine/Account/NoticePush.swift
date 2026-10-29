import Foundation

/// System notification authorization, reduced to what the registration decision needs.
/// `granted` covers authorized, provisional and ephemeral.
public enum NoticePushAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

/// What to do about the push notice of a pending phone-number transfer.
public enum NoticePushStep: Equatable, Sendable {
    /// Nothing: not signed in, a denied permission, or the alert-call path owns the push token.
    case none
    /// The user has not decided yet: ask once, and register only if the answer is yes.
    case askThenRegister
    /// The permission is already granted: register for remote notifications, without asking.
    case register
}

public enum NoticePushPolicy {
    /// Decides when to ask for the permission and register for remote notifications.
    ///  - never before sign-in;
    ///  - with `callKitFree` the existing alert-call path owns the push token: nothing here;
    ///  - a permission the user already decided on is never asked again;
    ///  - a denied permission means no registration at all.
    public static func step(
        callKitFree: Bool,
        authenticated: Bool,
        authorization: NoticePushAuthorization
    ) -> NoticePushStep {
        guard authenticated, !callKitFree else { return .none }
        switch authorization {
        case .notDetermined: return .askThenRegister
        case .granted: return .register
        case .denied: return .none
        }
    }
}

/// The two account endpoints that take the APNs device token of the app.
public enum AccountApnsTokenRoute: Equatable, Sendable {
    /// Token used for the alert push of an incoming call (no CallKit). The server drops the VoIP token.
    case callAlert
    /// Token used for the alert of a new message and for the notification key, on a device whose calls
    /// ring through CallKit and PushKit. The server keeps the VoIP token and never uses this one for calls.
    case messageAlert
    /// Token used for the account notice of a pending phone-number transfer.
    case notice

    public var path: String {
        switch self {
        case .callAlert: return "/api/v1/account/apns-token"
        case .messageAlert: return "/api/v1/account/apns-message-token"
        case .notice: return "/api/v1/account/apns-notice-token"
        }
    }
}

/// The registration request for an APNs device token. All routes carry the same body.
public enum AccountApnsTokenRequest {
    /// An APNs device token is 32 bytes, 64 hex digits.
    public static func isValid(hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy { $0.isHexDigit }
    }

    /// `POST <serverUrl><route.path>` with `{"apns_token": hex, "bundle_id": bundleId}` and the bearer
    /// token. Nil for a malformed token or server URL.
    public static func make(
        serverUrl: String,
        route: AccountApnsTokenRoute,
        hex: String,
        bundleId: String,
        bearer: String
    ) -> URLRequest? {
        guard isValid(hex: hex), var components = URLComponents(string: serverUrl) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + route.path
        guard let url = components.url else { return nil }
        let body: [String: Any] = [
            "apns_token": hex,
            "bundle_id": bundleId,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }
}

/// The token request that is running, so the launch / login / foreground triggers do not send the same
/// token twice at once. Per account: `reset()` (logout, wipe, change of account) forgets the running
/// request, so the next account registers the token again, and the late answer of the old request cannot
/// clear the new one.
public struct AccountApnsTokenInFlight: Sendable {
    private var hex: String?
    private var generation = 0

    public init() {}

    /// A ticket when `hex` is not already running (the caller sends the request and later calls
    /// `finish(ticket:)`); nil when the same token is already in flight.
    public mutating func begin(hex: String) -> Int? {
        guard self.hex != hex else { return nil }
        generation += 1
        self.hex = hex
        return generation
    }

    /// The request ended (any outcome). Only the latest ticket clears the state.
    public mutating func finish(ticket: Int) {
        if ticket == generation { hex = nil }
    }

    /// The account changed: forget the running request.
    public mutating func reset() {
        hex = nil
        generation += 1
    }
}

extension PhoneTransferNotice {
    /// True only for a notification whose custom key `type` is `phone_transfer_pending`. `userInfo` is the
    /// payload flattened to strings. A missing or different `type`, or an empty payload, is ignored.
    public static func isPendingPush(userInfo: [String: String]) -> Bool {
        userInfo["type"] == "phone_transfer_pending"
    }
}

/// When the kept APNs token is sent again, and what happens after a failure. Pure, so it is tested without a network.
public enum AlertTokenRegistrationPolicy {
    /// A token that was accepted for this account is not sent again from the kept copy within this time.
    public static let debounceInterval: TimeInterval = 15 * 60
    /// Retries after a failure, one launch / login / foreground trigger at a time.
    public static let maxRetries = 3
    public static let retryDelaySeconds: TimeInterval = 30

    /// The last accepted registration: which account, which token, when.
    public struct Accepted: Equatable, Sendable {
        public let userId: String
        public let hex: String
        public let at: Date
        public init(userId: String, hex: String, at: Date) {
            self.userId = userId
            self.hex = hex
            self.at = at
        }
    }

    /// False only when this very token was accepted for this very account less than `debounceInterval` ago.
    /// A different token, a different account, no record, or a clock that went back always sends.
    public static func shouldSendKept(hex: String, userId: String, last: Accepted?, now: Date) -> Bool {
        guard let last, last.hex == hex, last.userId == userId else { return true }
        let age = now.timeIntervalSince(last.at)
        return age < 0 || age >= debounceInterval
    }

    /// Which of the two routes (notice, message alert) get the token now. Each route has its own accepted record,
    /// so a route whose request failed is sent again even when the other one was accepted a moment ago. The
    /// same debounce as `shouldSendKept` applies to each route; a new token or account sends both.
    public struct Routes: Equatable, Sendable {
        public let notice: Bool
        public let messageAlert: Bool
        public init(notice: Bool, messageAlert: Bool) {
            self.notice = notice
            self.messageAlert = messageAlert
        }
        public var any: Bool { notice || messageAlert }
    }

    public static func routesToSend(
        hex: String, userId: String, notice: Accepted?, messageAlert: Accepted?, now: Date
    ) -> Routes {
        Routes(
            notice: shouldSendKept(hex: hex, userId: userId, last: notice, now: now),
            messageAlert: shouldSendKept(hex: hex, userId: userId, last: messageAlert, now: now))
    }

    /// A network error (nil status), a timeout (408), too many requests (429) and a server error (5xx) are tried
    /// again; every other answer (401, 403, 409, 400 ...) is final.
    public static func isRetryable(statusCode: Int?) -> Bool {
        guard let code = statusCode else { return true }
        return code == 408 || code == 429 || (500..<600).contains(code)
    }

    /// Delay before retry number `failures` (1-based), nil when the retries are used up.
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval? {
        (1...maxRetries).contains(failures) ? retryDelaySeconds : nil
    }
}

/// `DELETE /api/v1/auth/logout` with the bearer of the session that is ending. The server answers by dropping
/// this device's push records, so the next account on the phone does not inherit them.
public enum AccountLogoutRequest {
    public static func make(serverUrl: String, bearer: String) -> URLRequest? {
        guard !bearer.isEmpty, var components = URLComponents(string: serverUrl) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/api/v1/auth/logout"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// `POST /api/v1/auth/refresh` with `{"refresh_token": ...}`.
public enum AccountRefreshRequest {
    public static func make(serverUrl: String, refreshToken: String) -> URLRequest? {
        guard !refreshToken.isEmpty, var components = URLComponents(string: serverUrl) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/api/v1/auth/refresh"
        guard let url = components.url,
              let body = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken]) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
}

/// What to do with a sign-out request that could not reach the server, at the next launch or login.
public enum PendingLogoutPolicy {
    /// What the flush does next.
    public enum Next: Equatable, Sendable {
        /// Finished (accepted, or no answer can ever succeed): forget the pending request.
        case done
        /// A transient failure: keep it for the next launch.
        case keep
        /// Get a new access token with the stored refresh token, then send the sign-out again.
        case refreshAndRetry
    }

    /// Whether to send at all. `currentUserId` is the account signed in now (nil or empty: nobody). With someone signed
    /// in, the request goes out only when it is known to belong to another account: the same account (or an unknown
    /// one) would end the new session as well, so it is dropped.
    public static func shouldSend(pendingUserId: String?, currentUserId: String?) -> Bool {
        guard let current = currentUserId, !current.isEmpty else { return true }
        guard let pending = pendingUserId, !pending.isEmpty else { return false }
        return pending != current
    }

    /// Any answer ends the attempt (done, or the old session is already invalid: 401); a network error, 408, 429
    /// and 5xx keep the request for the next launch.
    public static func isFinal(statusCode: Int?) -> Bool {
        guard let code = statusCode else { return false }
        return !AlertTokenRegistrationPolicy.isRetryable(statusCode: code)
    }

    /// After a sign-out attempt. A 401 means the access token expired: refresh once (when a refresh token is kept)
    /// and only then treat a 401 as final.
    public static func afterLogout(statusCode: Int?, hasRefreshToken: Bool, refreshAlreadyTried: Bool) -> Next {
        if statusCode == 401, hasRefreshToken, !refreshAlreadyTried { return .refreshAndRetry }
        return isFinal(statusCode: statusCode) ? .done : .keep
    }

    /// The new pair from a 2xx refresh answer, nil when the body cannot be read (then the item is kept, not dropped).
    public static func decodeRefreshedPair(_ data: Data) -> (accessToken: String, refreshToken: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty else { return nil }
        let refresh = object["refresh_token"] as? String
        return (access, refresh?.isEmpty == false ? refresh : nil)
    }

    /// After the refresh: `.refreshAndRetry` here means "send the sign-out with the new access token".
    public static func afterRefresh(statusCode: Int?) -> Next {
        if let code = statusCode, (200..<300).contains(code) { return .refreshAndRetry }
        return isFinal(statusCode: statusCode) ? .done : .keep
    }
}
