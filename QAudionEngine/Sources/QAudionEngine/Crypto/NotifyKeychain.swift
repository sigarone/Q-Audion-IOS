import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain storage for the device's notification private key (X25519).
///
/// The item lives in its own keychain access group (`<team prefix>.com.qaudion.notify`), which only the app and the
/// notification extension carry. It is readable after the first unlock (a notification can arrive while the phone is
/// locked), never leaves the device (`...ThisDeviceOnly`) and is not synchronised.
///
/// The app's default group (the first `keychain-access-groups` entry) is a different group, so none of the app's other
/// keychain items are visible to the extension, and a query of the app that names a service never touches this one.
public struct NotifyKeychain {

    public static let service = "com.qaudion.notify.key"
    public static let account = "x25519-private"
    /// The private key is a raw X25519 scalar.
    public static let keyLength = 32
    /// Info.plist key holding `$(AppIdentifierPrefix)com.qaudion.notify`, expanded at build time.
    public static let infoPlistGroupKey = "QANotifyKeychainGroup"

    public enum StoreError: Error, Equatable {
        case invalidLength
        case keychain(OSStatus)
    }

    /// `nil` selects the process's default group (used by tests, whose host has no access groups).
    public let accessGroup: String?

    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    /// The store for the running app or extension. `nil` when the Info.plist carries no (or an unexpanded) group.
    public static func production(bundle: Bundle = .main) -> NotifyKeychain? {
        guard let group = bundle.object(forInfoDictionaryKey: infoPlistGroupKey) as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return NotifyKeychain(accessGroup: group)
    }

    #if canImport(Security)

    /// The attributes that identify the item (used by every operation).
    func identityQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// The attributes of a new item.
    func addQuery(_ key: Data) -> [String: Any] {
        var query = identityQuery()
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    /// Stores (or replaces) the private key.
    public func store(_ privateKey: Data) throws {
        guard privateKey.count == Self.keyLength else { throw StoreError.invalidLength }
        let status = SecItemAdd(addQuery(privateKey) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: privateKey,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updated = SecItemUpdate(identityQuery() as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw StoreError.keychain(updated) }
            return
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// The stored private key, or nil when there is none (or it is not 32 bytes).
    public func load() -> Data? {
        var query = identityQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == Self.keyLength else { return nil }
        return data
    }

    /// Removes the key (logout, revoked device, rotation).
    public func delete() {
        SecItemDelete(identityQuery() as CFDictionary)
    }

    #endif
}
