import Foundation
#if canImport(Security)
import Security
#endif

public final class SovereignKeyVault {
    private static let service = "com.bcrypto.qaudion.psk"

    public init() {}

    public func storePsk(name: String, key: Data, fingerprint: String) throws {
        // IOS-SE: fresh writes honor the current protection policy. When
        // biometric key protection is enabled, attach a `.userPresence`
        // access control; otherwise the plain WhenUnlockedThisDeviceOnly path
        // (byte-identical to the pre-IOS-SE behavior). Existing items are
        // re-protected via `migratePskProtection(enable:)`, not here, because
        // SecItemUpdate cannot change an item's access-control class.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
            kSecValueData as String: key,
            kSecAttrLabel as String: fingerprint
        ]
        if let ac = KeychainProtectionPolicy.shared.makeAccessControl() {
            query[kSecAttrAccessControl as String] = ac
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: key, kSecAttrLabel as String: fingerprint]
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: name
            ]
            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeyVaultError.storeFailed(updateStatus) }
        } else if status != errSecSuccess {
            throw KeyVaultError.storeFailed(status)
        }
    }

    public func loadPsk(name: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // IOS-SE: when protection is active, reuse the session-authenticated
        // context so a protected item reads without a fresh prompt. If no
        // context is set, iOS prompts on demand for a protected item (still
        // works, just more friction); unprotected items are unaffected.
        if let ctx = KeychainProtectionPolicy.shared.authenticationContext() {
            query[kSecUseAuthenticationContext as String] = ctx
        }
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyVaultError.loadFailed(status) }
        return item as? Data
    }

    public func deletePsk(name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyVaultError.deleteFailed(status) }
    }

    public func listPskNames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let results = items as? [[String: Any]] else { return [] }
        return results.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func getFingerprint(name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let attrs = item as? [String: Any] else { return nil }
        return attrs[kSecAttrLabel as String] as? String
    }

    /// IOS-SE — non-destructive re-protection of EXISTING PSK items.
    ///
    /// `enable == true`  → re-store every item under a `.userPresence` access
    ///                     control (biometry/passcode-gated).
    /// `enable == false` → remove the access control (back to the plain
    ///                     WhenUnlockedThisDeviceOnly class).
    ///
    /// SAFETY: each item's value is read into memory BEFORE the item is
    /// deleted, and is restored under its prior protection if the re-add
    /// fails — so a PSK is never lost. (Only a process crash in the
    /// sub-millisecond delete→add window could orphan a single item; the
    /// caller should run this off the main actor while the app is foreground.)
    ///
    /// When DISABLING, the caller MUST have an authenticated session
    /// (`KeychainProtectionPolicy.prepareSession`) and pass its context so the
    /// currently-protected items can be read.
    public func migratePskProtection(enable: Bool, context: AnyObject? = nil) throws {
        #if canImport(Security)
        var targetAC: SecAccessControl?
        if enable {
            var err: Unmanaged<CFError>?
            targetAC = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &err)
            guard targetAC != nil else { throw KeyVaultError.storeFailed(errSecParam) }
        }
        for name in listPskNames() {
            var readQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: name,
                kSecReturnData as String: true,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if let ctx = context { readQuery[kSecUseAuthenticationContext as String] = ctx }
            var item: AnyObject?
            let rs = SecItemCopyMatching(readQuery as CFDictionary, &item)
            if rs == errSecItemNotFound { continue }
            guard rs == errSecSuccess, let attrs = item as? [String: Any],
                  let value = attrs[kSecValueData as String] as? Data else {
                throw KeyVaultError.loadFailed(rs)
            }
            let fingerprint = attrs[kSecAttrLabel as String] as? String ?? ""

            // value is now in memory — safe to delete then re-add.
            let del = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: name
            ] as CFDictionary)
            guard del == errSecSuccess || del == errSecItemNotFound else {
                throw KeyVaultError.deleteFailed(del)
            }

            var add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: name,
                kSecValueData as String: value,
                kSecAttrLabel as String: fingerprint
            ]
            if let ac = targetAC {
                add[kSecAttrAccessControl as String] = ac
            } else {
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                // Roll back: restore the item under its PRIOR protection so the
                // PSK is never lost, then surface the error.
                var restore: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Self.service,
                    kSecAttrAccount as String: name,
                    kSecValueData as String: value,
                    kSecAttrLabel as String: fingerprint
                ]
                if enable {
                    restore[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                } else {
                    var e2: Unmanaged<CFError>?
                    if let ac = SecAccessControlCreateWithFlags(
                        kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &e2) {
                        restore[kSecAttrAccessControl as String] = ac
                    } else {
                        restore[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                    }
                }
                _ = SecItemAdd(restore as CFDictionary, nil)
                throw KeyVaultError.storeFailed(addStatus)
            }
        }
        #endif
    }
}

public enum KeyVaultError: Error {
    case storeFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
}
