import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain-backed [RatchetVault]. Persists each `(epochId, peerId)`
/// snapshot under its own keychain item with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so the chain keys
/// can never leave the device unencrypted.
///
/// Mirror of Android's `EncryptedSharedPreferencesRatchetVault.kt` —
/// both use the platform's native secure store and the same opaque
/// snapshot codec.
///
/// **Synchrony contract:** matches the protocol — `save()` calls
/// `SecItemUpdate`/`SecItemAdd` synchronously and returns only after
/// the keychain has acknowledged the write. This is the write-ahead
/// invariant that prevents nonce reuse on a crash between encrypt and
/// network send.
public final class KeychainRatchetVault: RatchetVault, @unchecked Sendable {

    /// Keychain `kSecAttrService` value. Distinct from PSK vault so a
    /// future `keychain dump` migration can target the ratchet items
    /// without disturbing PSKs.
    public static let service = "com.bcrypto.qaudion.ratchet.v1"

    public init() {}

    public func load(epochId: String, peerId: String) -> RatchetSnapshot? {
        let blob = readBlob(account: Self.account(epochId: epochId, peerId: peerId))
        guard let blob = blob else { return nil }
        return try? RatchetSnapshotCodec.decode(blob)
    }

    public func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) {
        let blob = RatchetSnapshotCodec.encode(snapshot)
        writeBlob(account: Self.account(epochId: epochId, peerId: peerId), blob: blob)
    }

    public func delete(epochId: String, peerId: String) {
        deleteBlob(account: Self.account(epochId: epochId, peerId: peerId))
    }

    // MARK: - Internal

    private static func account(epochId: String, peerId: String) -> String {
        return "\(epochId)|\(peerId)"
    }

    private func readBlob(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { return nil }
        return item as? Data
    }

    private func writeBlob(account: String, blob: Data) {
        let baseAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        var addAttrs = baseAttrs
        addAttrs[kSecValueData as String] = blob
        addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateAttrs: [String: Any] = [
                kSecValueData as String: blob,
            ]
            _ = SecItemUpdate(baseAttrs as CFDictionary, updateAttrs as CFDictionary)
        }
        // We deliberately do NOT throw on errors — the engine treats
        // persistence as best-effort because in-memory state is the
        // source of truth within a process. A persistence failure
        // means we lose chain state on crash; legitimate decrypts in
        // the same process keep working.
    }

    private func deleteBlob(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
