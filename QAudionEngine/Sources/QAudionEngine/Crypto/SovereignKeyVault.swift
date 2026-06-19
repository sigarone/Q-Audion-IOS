import Foundation
#if canImport(Security)
import Security
#endif

public final class SovereignKeyVault {
    private static let service = "com.bcrypto.qaudion.psk"

    /// KMS-rotation-v2 Phase-1 (D1) — per-entry key_class persisted alongside
    /// each PSK. Mirrors Android `SovereignKeyVault` key_class column (captured
    /// from `KmsKey.keyClass` at import) and the firmware KMU `contact_meta`
    /// key_class byte. SW-only on iOS/desktop never holds `hwOnly` storage; the
    /// class is what the negotiation (D2) and the local require-hw-only policy
    /// (D4) consult.
    ///
    /// Wire-neutral: stored ONLY in the Keychain item's `kSecAttrGeneric` slot
    /// (a byte blob attribute distinct from `kSecAttrLabel`, which carries the
    /// fingerprint). Reading a legacy item that predates Phase-1 yields no
    /// generic blob → `.shared` (the safe, additive-default class — a contact
    /// without a recorded class is treated as a plain shared PSK, never
    /// hw_only, so the D4 abort can't misfire on legacy entries).
    public enum KeyClass: String {
        case shared = "shared"
        case hwOnly = "hw_only"
        case swOnly = "sw_only"

        /// Lenient parse: unknown / nil wire string → `.shared` (safe default).
        public static func parse(_ wire: String?) -> KeyClass {
            switch wire {
            case "hw_only": return .hwOnly
            case "sw_only": return .swOnly
            default:        return .shared
            }
        }
    }

    public init() {}

    /// Phase-1 (D1) overload — store a PSK WITH its key_class. The class is
    /// persisted in `kSecAttrGeneric`; everything else is byte-identical to the
    /// legacy `storePsk(name:key:fingerprint:)` path (which now forwards here
    /// with `keyClass: nil`, leaving the generic slot empty → reads back as
    /// `.shared`).
    public func storePsk(name: String, key: Data, fingerprint: String, keyClass: KeyClass?) throws {
        // IOS-SE: fresh writes honor the current protection policy. When
        // biometric key protection is enabled, attach a `.userPresence`
        // access control; otherwise the plain WhenUnlockedThisDeviceOnly path
        // (byte-identical to the pre-IOS-SE behavior). Existing items are
        // re-protected via `migratePskProtection(enable:)`, not here, because
        // SecItemUpdate cannot change an item's access-control class.
        // D1: the key_class string (if any) goes into kSecAttrGeneric — a raw
        // byte blob attribute that does NOT collide with the fingerprint label.
        let classBlob: Data? = keyClass.map { Data($0.rawValue.utf8) }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
            kSecValueData as String: key,
            kSecAttrLabel as String: fingerprint
        ]
        if let classBlob { query[kSecAttrGeneric as String] = classBlob }
        if let ac = KeychainProtectionPolicy.shared.makeAccessControl() {
            query[kSecAttrAccessControl as String] = ac
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var update: [String: Any] = [kSecValueData as String: key, kSecAttrLabel as String: fingerprint]
            // Only touch the generic slot when a class is supplied, so a legacy
            // 3-arg re-store (keyClass == nil) NEVER clears an already-recorded
            // class — once a contact is tagged hw_only it stays hw_only across
            // idempotent PSK refreshes.
            if let classBlob { update[kSecAttrGeneric as String] = classBlob }
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

    /// Legacy 3-arg overload — preserves the EXACT pre-Phase-1 call sites
    /// (`storePsk(name:key:fingerprint:)`). Forwards with `keyClass: nil`, so
    /// the generic slot is left untouched and a subsequent `getKeyClass` reads
    /// back `.shared` (the additive-safe default).
    public func storePsk(name: String, key: Data, fingerprint: String) throws {
        try storePsk(name: name, key: key, fingerprint: fingerprint, keyClass: nil)
    }

    /// D1 reader — the persisted key_class for a PSK entry, or `.shared` when
    /// the item has no recorded class (legacy entry or never tagged). Never
    /// throws: a missing item / read failure also yields `.shared`, so the D4
    /// require-hw-only policy is the ONLY thing that can escalate, and it can
    /// never spuriously treat an absent class as hw_only.
    public func getKeyClass(name: String) -> KeyClass {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let attrs = item as? [String: Any],
              let blob = attrs[kSecAttrGeneric as String] as? Data,
              let wire = String(data: blob, encoding: .utf8) else {
            return .shared
        }
        return KeyClass.parse(wire)
        #else
        return .shared
        #endif
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
            // D1: carry the persisted key_class blob through the delete→re-add so
            // a biometric-protection toggle does NOT silently reset a hw_only
            // contact back to .shared (which would defeat the D4 abort).
            let classBlob = attrs[kSecAttrGeneric as String] as? Data

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
            if let classBlob { add[kSecAttrGeneric as String] = classBlob }
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
                if let classBlob { restore[kSecAttrGeneric as String] = classBlob }
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
