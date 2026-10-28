import Foundation
import CryptoKit

/// Lifecycle of the notification key: generation, the registration requests and the policy of when to send it.
public enum NotifyKeyRegistration {

    public static let path = "/api/v1/account/notify-key"

    /// Loads the device's notification private key, creating and storing a new one when there is none.
    /// Returns the private key and the base64 (standard, padded) public key.
    public static func ensureKey(in keychain: NotifyKeychain) -> (privateKey: Data, publicBase64: String)? {
        if let existing = keychain.load(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: existing) {
            return (existing, key.publicKey.rawRepresentation.base64EncodedString())
        }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        let raw = fresh.rawRepresentation
        do { try keychain.store(raw) } catch { return nil }
        return (raw, fresh.publicKey.rawRepresentation.base64EncodedString())
    }

    private static func url(serverUrl: String) -> URL? {
        guard var components = URLComponents(string: serverUrl) else { return nil }
        var base = components.path
        while base.hasSuffix("/") { base.removeLast() }
        components.path = base + path
        return components.url
    }

    /// `PUT <server>/api/v1/account/notify-key` with `{"pub":..., "alg":...}`.
    public static func putRequest(serverUrl: String, publicBase64: String, bearer: String) -> URLRequest? {
        guard let url = url(serverUrl: serverUrl),
              let body = try? JSONSerialization.data(
                withJSONObject: ["pub": publicBase64, "alg": NotifyEnvelope.algorithm], options: [.sortedKeys])
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// `DELETE <server>/api/v1/account/notify-key`.
    public static func deleteRequest(serverUrl: String, bearer: String) -> URLRequest? {
        guard let url = url(serverUrl: serverUrl) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// What the app does with the answer of a PUT.
    public enum Outcome: Equatable, Sendable {
        case registered
        /// 409 `no_alert_token`: the server has no alert token for this device yet. Not retried in a loop: the next
        /// successful alert-token registration sends the key again.
        case waitForNextToken
        /// Anything else (network error, 4xx/5xx): the key is sent again at the next alert-token registration.
        case failed
    }

    public static func outcome(statusCode: Int?) -> Outcome {
        guard let statusCode else { return .failed }
        if (200..<300).contains(statusCode) { return .registered }
        if statusCode == 409 { return .waitForNextToken }
        return .failed
    }

    /// The key goes to the server only when signed in AND an alert token was just registered successfully.
    public static func shouldRegister(authenticated: Bool, alertTokenJustRegistered: Bool) -> Bool {
        authenticated && alertTokenJustRegistered
    }
}

/// The key request that is running, so two triggers do not send it twice at once. Per account: `reset()` forgets it.
public struct NotifyKeyInFlight: Sendable {
    private var running = false
    private var generation = 0

    public init() {}

    public mutating func begin() -> Int? {
        guard !running else { return nil }
        running = true
        generation += 1
        return generation
    }

    public mutating func finish(ticket: Int) {
        if ticket == generation { running = false }
    }

    public mutating func reset() {
        running = false
        generation += 1
    }
}
