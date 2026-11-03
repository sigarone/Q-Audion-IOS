import Foundation
import Security

/// Storage seam for the per-installation identifier.
public protocol InstallIdStorage: AnyObject {
    func read() -> String?
    func write(_ value: String)
    func delete()
}

/// Random per-installation identifier sent with every sign-in request. Generated once,
/// kept in the Keychain (this device only, not synced) and kept across sign-outs.
public final class InstallIdStore {
    public static let shared = InstallIdStore(storage: KeychainInstallIdStorage())

    private let storage: InstallIdStorage
    private let lock = NSLock()

    public init(storage: InstallIdStorage) { self.storage = storage }

    /// The stored id, or a fresh UUIDv4 stored on first use.
    public func current() -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = storage.read(), Self.isValid(existing) { return existing }
        let fresh = UUID().uuidString.lowercased()
        storage.write(fresh)
        return fresh
    }

    /// Full app data wipe only (remote wipe, account deletion).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        storage.delete()
    }

    /// Adds `install_id` to a sign-in request body.
    public func add(to dict: inout [String: Any]) {
        dict["install_id"] = current()
    }

    static func isValid(_ value: String) -> Bool { UUID(uuidString: value) != nil }
}

public final class KeychainInstallIdStorage: InstallIdStorage {
    private let service = "com.bcrypto.qaudion.install-id"
    private let account = "install_id"
    public init() {}

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var q = base
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = kCFBooleanFalse
        SecItemAdd(q as CFDictionary, nil)
    }

    public func delete() { SecItemDelete(base as CFDictionary) }
}
