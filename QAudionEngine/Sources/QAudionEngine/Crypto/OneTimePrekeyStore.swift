import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain home for the device's one-time prekeys.
///
/// Its own Keychain service, deliberately not the PSK vault's. That vault is
/// enumerated by name in several places — the exportable-key list, PSK
/// advertising, the settings UI — and none of them filter, so a prekey stored
/// there would show up as if it were a contact key. Worse, the
/// biometric-protection migration walks that same list and would attach a
/// user-presence requirement to keys the WebSocket handler has to read in the
/// background, where there is no user to be present.
///
/// One item per prekey, keyed by id, so consuming one is a single delete and
/// nothing has to rewrite a blob under concurrency.
public struct OneTimePrekeyStore {

    private static let service = "com.bcrypto.qaudion.otp"

    public init() {}

    public enum StoreError: Error {
        case keychain(OSStatus)
        case encoding
    }

    private static func account(_ prekeyId: UInt32) -> String { "otp.\(prekeyId)" }

    public func save(_ prekey: OneTimePrekeyPool.StoredPrekey) throws {
        guard let blob = try? JSONEncoder().encode(prekey) else { throw StoreError.encoding }
        let account = Self.account(prekey.prekeyId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = blob
        // WhenUnlockedThisDeviceOnly, matching every other private half this
        // app holds: a prekey must never ride an iCloud backup to another
        // device, or "one-time" stops being true.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    public func load(prekeyId: UInt32) -> OneTimePrekeyPool.StoredPrekey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(prekeyId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(OneTimePrekeyPool.StoredPrekey.self, from: data)
    }

    /// Delete after use. One-time means one time: a prekey that survives its
    /// own message is just a short-lived long-term key.
    public func delete(prekeyId: UInt32) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(prekeyId),
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// How many prekeys this device still holds privately.
    ///
    /// This is the local count, which is the only one anybody can see: the
    /// server exposes a pool size in the upload response and nowhere else.
    public func count() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return 0 }
        return items.count
    }

    /// Drop everything — used when the identity changes, since a prekey signed
    /// by a key that no longer exists can never be verified by anyone.
    public func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
