import Foundation
#if canImport(Security)
import Security
#endif

/// W-KCAFTERUNLOCK (2026-09-01) — in-place, attribute-only upgrade of an item
/// that is already on disk under the legacy accessibility class, driven by
/// `KeychainAccessibilityPolicy.migrationTarget`.
///
/// Sequence, chosen so the value can never be lost: the caller has ALREADY
/// read the item successfully (this is only ever invoked from a vault's read
/// path, with the attributes that read returned) → `SecItemUpdate` of
/// `kSecAttrAccessible` alone, no delete, no re-add, value untouched → a
/// second attribute read confirms the new class. A failed or unverified
/// update is logged and the item simply stays on the old class; the next
/// successful read tries again. Idempotent by construction: once the
/// attribute matches, `migrationTarget` returns `nil` and nothing runs. Same
/// technique `ContactsStore.upgradeAccessibilityIfNeeded` (W-CONTACTLOCKED)
/// already ships for the contacts key. `print`, not RTLog: RTLog lives in the
/// app target and this package cannot reach it.
enum KeychainAccessibilityMigration {

    #if canImport(Security)
    /// - Parameters:
    ///   - attributes: the dictionary a successful `SecItemCopyMatching` with
    ///     `kSecReturnAttributes` returned for this item.
    ///   - baseQuery: `kSecClass` + `kSecAttrService` + `kSecAttrAccount` that
    ///     identify exactly this item.
    ///   - tag: log prefix, the owning vault's name.
    /// - Returns: `true` iff the item is now verified on the target class as a
    ///   result of THIS call (already-migrated and left-alone items return
    ///   `false`).
    @discardableResult
    static func upgradeIfNeeded(
        attributes: [String: Any],
        baseQuery: [String: Any],
        category: KeychainAccessibilityPolicy.ItemCategory,
        tag: String
    ) -> Bool {
        let current = KeychainAccessibilityPolicy.accessClass(
            fromAttribute: attributes[kSecAttrAccessible as String])
        let hasAccessControl = attributes[kSecAttrAccessControl as String] != nil
        guard let target = KeychainAccessibilityPolicy.migrationTarget(
                  category: category, currentClass: current, hasAccessControl: hasAccessControl),
              let cfTarget = KeychainAccessibilityPolicy.secAttrAccessible(target) else {
            return false
        }
        let update: [String: Any] = [kSecAttrAccessible as String: cfTarget]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else {
            print("[\(tag)] accessibility upgrade failed status=\(status) (item left on legacy class, value untouched)")
            return false
        }
        var verify = baseQuery
        verify[kSecReturnAttributes as String] = true
        verify[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        let verifyStatus = SecItemCopyMatching(verify as CFDictionary, &item)
        let after = KeychainAccessibilityPolicy.accessClass(
            fromAttribute: (item as? [String: Any])?[kSecAttrAccessible as String])
        guard verifyStatus == errSecSuccess, after == target else {
            print("[\(tag)] accessibility upgrade unverified status=\(verifyStatus)")
            return false
        }
        print("[\(tag)] accessibility upgraded to after-first-unlock")
        return true
    }
    #endif
}
