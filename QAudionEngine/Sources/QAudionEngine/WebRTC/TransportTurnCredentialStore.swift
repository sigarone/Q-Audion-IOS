import Foundation
#if canImport(Security)
import Security
#endif

/// The user name and the password of the custom TURN server of Settings > Trasporto. They are kept apart from the address
/// (`TransportPreferences` puts the address in `UserDefaults`, these in the Keychain) and never print: a log line or an
/// assertion message shows `TransportTurnCredentials(hidden)`.
public struct TransportTurnCredentials: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "TransportTurnCredentials(hidden)" }
    public var debugDescription: String { description }
}

/// Where the credentials of the custom TURN server are kept, one entry per server host.
///
/// The app uses the Keychain (`KeychainTransportTurnCredentialStore`). A unit test bundle has no Keychain access group, so
/// the tests that are not about the Keychain itself use `InMemoryTransportTurnCredentialStore`.
public protocol TransportTurnCredentialStore {
    /// The credentials kept for `host`, or `nil` when there are none or they cannot be read right now.
    func credentials(forHost host: String) -> TransportTurnCredentials?
    /// Keeps `credentials` for `host`, replacing the ones kept before. `false` when the write did not take.
    func save(_ credentials: TransportTurnCredentials, forHost host: String) -> Bool
    /// Forgets the credentials kept for `host`.
    func remove(forHost host: String)
    /// Removes every stored credential of the service, for every host. Used when the account is wiped.
    func removeAll()
}

/// The Keychain store: one generic password item per server, service `qaudion.transport.turn`, account = the host of the
/// TURN server (lower case), value = the user name and the password.
///
/// The item is `AfterFirstUnlockThisDeviceOnly`, like the other items a call reads: an incoming call can wake the app
/// from a push while the phone is locked, and a call built then reads the saved server. It never leaves the phone (no
/// iCloud Keychain, not restored to another device). A read that fails (for example before the first unlock after a
/// restart) gives `nil`, and a call without credentials does not use the custom server at all: it does not borrow the
/// credentials of the BCrypto server, see `TransportPlan`.
///
/// `kSecUseDataProtectionKeychain` is set on every query, like in `TusResumeStateStore`: it is the documented way to get
/// the same Keychain on every platform the package builds for.
public struct KeychainTransportTurnCredentialStore: TransportTurnCredentialStore {

    public static let service = "qaudion.transport.turn"

    public init() {}

    /// What the item holds. Two short keys: the value is a few dozen bytes.
    fileprivate struct Payload: Codable {
        let u: String
        let p: String
    }

    #if canImport(Security)
    private func query(forHost host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host.lowercased(),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
    #endif

    public func credentials(forHost host: String) -> TransportTurnCredentials? {
        #if canImport(Security)
        var read = query(forHost: host)
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return TransportTurnCredentials(username: payload.u, password: payload.p)
        #else
        // Fail closed: no plaintext fallback. `Security` exists on every Apple platform this package builds for.
        return nil
        #endif
    }

    @discardableResult
    public func save(_ credentials: TransportTurnCredentials, forHost host: String) -> Bool {
        #if canImport(Security)
        guard let data = try? JSONEncoder().encode(Payload(u: credentials.username, p: credentials.password)) else {
            return false
        }
        var write = query(forHost: host)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(write as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            // An item that cannot be updated in place: start again from nothing.
            SecItemDelete(write as CFDictionary)
        }
        for (key, value) in attributes { write[key] = value }
        return SecItemAdd(write as CFDictionary, nil) == errSecSuccess
        #else
        _ = (credentials, host)
        return false
        #endif
    }

    public func removeAll() {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    public func remove(forHost host: String) {
        #if canImport(Security)
        SecItemDelete(query(forHost: host) as CFDictionary)
        #else
        _ = host
        #endif
    }
}

/// A store that lives in memory only. For unit tests and previews: it is not a place to keep a password between launches.
public final class InMemoryTransportTurnCredentialStore: TransportTurnCredentialStore, @unchecked Sendable {

    private let lock = NSLock()
    private var entries: [String: TransportTurnCredentials] = [:]
    /// When `false`, `save` refuses, like a Keychain that cannot be written (a test sets it to drive that case).
    public var acceptsWrites: Bool = true

    public init() {}

    public func credentials(forHost host: String) -> TransportTurnCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return entries[host.lowercased()]
    }

    @discardableResult
    public func save(_ credentials: TransportTurnCredentials, forHost host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsWrites else { return false }
        entries[host.lowercased()] = credentials
        return true
    }

    public func remove(forHost host: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: host.lowercased())
    }

    /// The hosts that currently have credentials, sorted.
    public var hosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted()
    }
}

/// Stores that keep nothing (tests, previews) have nothing to remove.
extension TransportTurnCredentialStore {
    public func removeAll() {}
}
