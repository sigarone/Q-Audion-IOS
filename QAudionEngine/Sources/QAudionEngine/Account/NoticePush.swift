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
    /// Token used for the alert push of an incoming call (no CallKit).
    case callAlert
    /// Token used for the account notice of a pending phone-number transfer.
    case notice

    public var path: String {
        switch self {
        case .callAlert: return "/api/v1/account/apns-token"
        case .notice: return "/api/v1/account/apns-notice-token"
        }
    }
}

/// The registration request for an APNs device token. Both routes carry the same body.
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
