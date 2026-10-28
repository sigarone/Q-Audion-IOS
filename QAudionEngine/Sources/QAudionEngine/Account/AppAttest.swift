import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// Device attestation. The policy, the requests and the coordinator live here (testable on any host); the thin
// DeviceCheck wrapper and the transport live in the app target.

/// What the platform service reports, reduced to what the policy needs.
public enum AppAttestServiceError: Error, Equatable, Sendable {
    /// The key is unknown to the system (for example after a restore): a new key is needed.
    case invalidKey
    /// The system or the attestation service is temporarily unavailable.
    case transient
    /// Anything else; the code is the platform error code.
    case failed(Int)
}

/// A failed request to the server.
public struct AppAttestTransportError: Error, Equatable, Sendable {
    /// HTTP status; 0 when no response arrived.
    public let status: Int
    /// The `code` field of the error body, when there is one.
    public let code: String?
    public init(status: Int, code: String?) {
        self.status = status
        self.code = code
    }
}

public protocol AppAttestPlatformService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
}

public protocol AppAttestTransport: Sendable {
    /// The challenge exactly as received (base64).
    func challenge() async throws -> String
    func submit(_ body: AppAttestSubmission) async throws
}

public protocol AppAttestStore: Sendable {
    func keyId() -> String?
    func setKeyId(_ keyId: String)
    /// Forgets the key and the attested mark.
    func clearKey()
    /// The account the current key was attested for.
    func attestedAccount() -> String?
    func setAttestedAccount(_ account: String)
    func clearAttestedAccount()
}

/// The body of the attestation request. The key id and the challenge are standard base64 already; the attestation
/// is encoded when the request is built.
public struct AppAttestSubmission: Equatable, Sendable {
    public let keyId: String
    public let attestation: Data
    public let challenge: String
    public init(keyId: String, attestation: Data, challenge: String) {
        self.keyId = keyId
        self.attestation = attestation
        self.challenge = challenge
    }
}

public enum AppAttestRequests {
    public static let challengePath = "/api/v1/attest/challenge"
    public static let attestPath = "/api/v1/attest/ios"

    private static func url(_ serverUrl: String, _ path: String) -> URL? {
        guard var components = URLComponents(string: serverUrl) else { return nil }
        var base = components.path
        while base.hasSuffix("/") { base.removeLast() }
        components.path = base + path
        return components.url
    }

    private static func post(_ url: URL, bearer: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    public static func challengeRequest(serverUrl: String, bearer: String) -> URLRequest? {
        guard let url = url(serverUrl, challengePath) else { return nil }
        return post(url, bearer: bearer, body: nil)
    }

    public static func attestRequest(serverUrl: String, bearer: String, submission: AppAttestSubmission) -> URLRequest? {
        guard let url = url(serverUrl, attestPath) else { return nil }
        let body: [String: String] = [
            "key_id": submission.keyId,
            "attestation": submission.attestation.base64EncodedString(),
            "challenge": submission.challenge,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return post(url, bearer: bearer, body: data)
    }

    /// The challenge of a 200 answer, nil when the body is not `{"challenge": <non-empty string>}`.
    public static func parseChallenge(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challenge = object["challenge"] as? String, !challenge.isEmpty else { return nil }
        return challenge
    }

    /// The `code` of an error body.
    public static func parseErrorCode(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
    }

    /// `SHA256(challenge bytes)`, nil when the challenge is not base64.
    public static func clientDataHash(challenge: String) -> Data? {
        guard let bytes = Data(base64Encoded: challenge), !bytes.isEmpty else { return nil }
        return Data(SHA256.hash(data: bytes))
    }
}

/// What to do after a failed attempt.
public enum AppAttestDecision: Equatable, Sendable {
    case retryAfterBackoff
    case regenerateKey
    /// Give up until the next launch.
    case stop
}

public enum AppAttestPolicy {
    public static let maxAttempts = 3
    /// Seconds to wait after attempt n (index n-1).
    public static let backoffSeconds: [UInt64] = [2, 8, 30]

    public static func backoff(afterAttempt attempt: Int) -> UInt64 {
        backoffSeconds[min(max(attempt - 1, 0), backoffSeconds.count - 1)]
    }

    public static func decision(for error: AppAttestTransportError) -> AppAttestDecision {
        switch error.status {
        case 0, 500...599: return .retryAfterBackoff
        case 400: return error.code == "challenge_invalid" ? .retryAfterBackoff : .stop
        case 422: return error.code == "key_mismatch" ? .regenerateKey : .stop
        default: return .stop  // 401, 404 (not available), 429 and the rest: next launch
        }
    }

    public static func decision(for error: AppAttestServiceError) -> AppAttestDecision {
        switch error {
        case .invalidKey: return .regenerateKey
        case .transient: return .retryAfterBackoff
        case .failed: return .stop
        }
    }

    /// Verdict code for the telemetry: no key id, no bytes.
    public static func code(for error: AppAttestTransportError) -> String {
        if let code = error.code, code.count <= 32, code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return "http_\(error.status)_\(code)"
        }
        return "http_\(error.status)"
    }

    public static func code(for error: AppAttestServiceError) -> String {
        switch error {
        case .invalidKey: return "invalid_key"
        case .transient: return "service_unavailable"
        case .failed(let n): return "service_\(n)"
        }
    }
}

public enum AppAttestVerdict: Equatable, Sendable {
    case ok
    case unsupported
    case alreadyAttested
    case fail(String)

    public var code: String {
        switch self {
        case .ok: return "ok"
        case .unsupported: return "unsupported"
        case .alreadyAttested: return "already"
        case .fail(let c): return "fail_\(c)"
        }
    }
}

/// Attests the installation key once per account. Never throws; run it from a detached task so it cannot hold up
/// sign-in or calls.
public actor AppAttestCoordinator {
    private let service: AppAttestPlatformService
    private let transport: AppAttestTransport
    private let store: AppAttestStore
    private let report: @Sendable (AppAttestVerdict) -> Void
    private let sleep: @Sendable (UInt64) async -> Void
    private var running = false
    private var generation = 0

    public init(
        service: AppAttestPlatformService,
        transport: AppAttestTransport,
        store: AppAttestStore,
        report: @escaping @Sendable (AppAttestVerdict) -> Void,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0 * 1_000_000_000) }
    ) {
        self.service = service
        self.transport = transport
        self.store = store
        self.report = report
        self.sleep = sleep
    }

    /// Logout, wipe or change of account: forget the attested mark (the key stays, it belongs to the installation)
    /// and let a running attempt of the old account end without recording anything.
    public func accountLeft() {
        generation += 1
        store.clearAttestedAccount()
    }

    @discardableResult
    public func attestIfNeeded(account: String) async -> AppAttestVerdict {
        guard !running else { return .alreadyAttested }
        guard service.isSupported else {
            report(.unsupported)
            return .unsupported
        }
        if store.keyId() != nil, store.attestedAccount() == account { return .alreadyAttested }
        running = true
        defer { running = false }
        let myGeneration = generation
        var regenerated = false
        var verdict = AppAttestVerdict.fail("none")
        var attempt = 0
        while attempt < AppAttestPolicy.maxAttempts {
            attempt += 1
            switch await attemptOnce(account: account, generation: myGeneration) {
            case .success:
                verdict = .ok
            case .failure(let decision, let code):
                verdict = .fail(code)
                switch decision {
                case .stop:
                    attempt = AppAttestPolicy.maxAttempts
                case .regenerateKey:
                    if regenerated {
                        attempt = AppAttestPolicy.maxAttempts
                    } else {
                        regenerated = true
                        store.clearKey()
                        attempt -= 1  // the new key does not use up an attempt
                    }
                case .retryAfterBackoff:
                    if attempt < AppAttestPolicy.maxAttempts {
                        await sleep(AppAttestPolicy.backoff(afterAttempt: attempt))
                    }
                }
            }
            if verdict == .ok || generation != myGeneration { break }
        }
        if generation == myGeneration { report(verdict) }
        return verdict
    }

    private enum Step {
        case success
        case failure(AppAttestDecision, String)
    }

    private func attemptOnce(account: String, generation expected: Int) async -> Step {
        do {
            let keyId: String
            if let existing = store.keyId() {
                keyId = existing
            } else {
                keyId = try await service.generateKey()
                store.setKeyId(keyId)
            }
            let challenge = try await transport.challenge()
            guard let hash = AppAttestRequests.clientDataHash(challenge: challenge) else {
                return .failure(.retryAfterBackoff, "bad_challenge")
            }
            let attestation = try await service.attestKey(keyId, clientDataHash: hash)
            try await transport.submit(AppAttestSubmission(keyId: keyId, attestation: attestation, challenge: challenge))
            if generation == expected { store.setAttestedAccount(account) }
            return .success
        } catch let error as AppAttestServiceError {
            return .failure(AppAttestPolicy.decision(for: error), AppAttestPolicy.code(for: error))
        } catch let error as AppAttestTransportError {
            return .failure(AppAttestPolicy.decision(for: error), AppAttestPolicy.code(for: error))
        } catch {
            return .failure(.retryAfterBackoff, "unknown")
        }
    }
}

#if canImport(Security)
/// Keychain storage of the key id and of the attested mark: the app default access group (the first
/// `keychain-access-groups` entry), readable after the first unlock, this device only, not synchronised.
public struct AppAttestKeychainStore: AppAttestStore {
    public static let service = "com.qaudion.appattest"
    private static let keyAccount = "key-id"
    private static let attestedAccountName = "attested-account"

    public init() {}

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    private func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }

    public func keyId() -> String? { read(Self.keyAccount) }
    public func setKeyId(_ keyId: String) { write(Self.keyAccount, keyId) }
    public func clearKey() {
        remove(Self.keyAccount)
        remove(Self.attestedAccountName)
    }
    public func attestedAccount() -> String? { read(Self.attestedAccountName) }
    public func setAttestedAccount(_ account: String) { write(Self.attestedAccountName, account) }
    public func clearAttestedAccount() { remove(Self.attestedAccountName) }
}
#endif
