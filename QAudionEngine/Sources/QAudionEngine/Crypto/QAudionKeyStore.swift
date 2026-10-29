import Foundation
#if canImport(Security)
import Security
#endif

public final class QAudionKeyStore {
    private static let service = "com.bcrypto.qaudion.keys"

    public init() {}

    public func storeKey(identifier: String, keyData: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: keyData,
            // W-KCAFTERUNLOCK (2026-09-01) — `.uiOnly`: backup / credential
            // blobs are only read in the foreground, so the class stays
            // WhenUnlockedThisDeviceOnly; routed through the policy so the
            // per-category decision lives in exactly one place.
            kSecAttrAccessible as String: KeychainAccessibilityPolicy.secAttrAccessible(for: .uiOnly)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: keyData]
            let search: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service, kSecAttrAccount as String: identifier]
            SecItemUpdate(search as CFDictionary, update as CFDictionary)
        }
    }

    public func loadKey(identifier: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess ? item as? Data : nil
    }

    public func deleteKey(identifier: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: identifier]
        SecItemDelete(query as CFDictionary)
    }
}
