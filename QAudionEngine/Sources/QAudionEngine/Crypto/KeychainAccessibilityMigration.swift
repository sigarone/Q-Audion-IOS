import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// W-KCAFTERUNLOCK (2026-09-01) — in-place, attribute-only upgrade of an item
/// that is already on disk under the legacy accessibility class, driven by
/// `KeychainAccessibilityPolicy.migrationTarget`.
///
/// Sequence, chosen so the value can never be lost: the caller has ALREADY
/// read the item successfully (a vault's read path, with the attributes that
/// read returned, or `SovereignKeyVault.upgradeLegacyAccessibility` with the
/// attributes of its listing) → only an item on the legacy class goes on →
/// one read of its value with an authentication context that may not interact
/// with the user, which succeeds for an item with no user-presence constraint
/// and fails, showing nothing, for one that has it → `SecItemUpdate` of
/// `kSecAttrAccessible` alone, with that same context, no delete, no re-add,
/// value untouched → a second attribute read confirms the new class. A failed
/// or unverified update is logged and the item simply stays on the old class;
/// the next successful read tries again. Idempotent by construction: once the
/// attribute matches, `migrationTarget` returns `nil` and nothing runs. Same
/// technique `ContactsStore.upgradeAccessibilityIfNeeded` (W-CONTACTLOCKED)
/// already ships for the contacts key. `print`, not RTLog: RTLog lives in the
/// app target and this package cannot reach it.
///
/// The user-presence check is the read, not the `kSecAttrAccessControl`
/// attribute: the system reports an access control object for every item, a
/// plain one included, so its presence does not tell the two shapes apart.
enum KeychainAccessibilityMigration {

    /// What one call did to the item.
    enum Outcome: Equatable {
        /// Nothing to do: already on its target class, a class this policy does
        /// not own, or a category that keeps its class.
        case unchanged
        /// Moved to the target class, and the move was read back.
        case upgraded
        /// On the legacy class but it may need the user (a user-presence
        /// constraint, or the read could not show otherwise): left as it is.
        case leftForUser
        /// The update or its read-back failed; the item stays on its class and a
        /// later call tries again.
        case failed
    }

    #if canImport(Security)
    /// - Parameters:
    ///   - attributes: the dictionary a successful `SecItemCopyMatching` with
    ///     `kSecReturnAttributes` returned for this item.
    ///   - baseQuery: `kSecClass` + `kSecAttrService` + `kSecAttrAccount` that
    ///     identify exactly this item.
    ///   - tag: log prefix, the owning vault's name.
    @discardableResult
    static func upgradeIfNeeded(
        attributes: [String: Any],
        baseQuery: [String: Any],
        category: KeychainAccessibilityPolicy.ItemCategory,
        tag: String
    ) -> Outcome {
        let current = KeychainAccessibilityPolicy.accessClass(
            fromAttribute: attributes[kSecAttrAccessible as String])
        // Only an item on the legacy class, in a category that moves, is worth the read below.
        guard KeychainAccessibilityPolicy.migrationTarget(
                  category: category, currentClass: current, requiresUserPresence: false) != nil else {
            return .unchanged
        }
        let context = nonInteractiveContext()
        let requiresUserPresence = KeychainAccessibilityPolicy.requiresUserPresence(
            probeStatus: probeStatus(baseQuery: baseQuery, context: context))
        guard let context,
              let target = KeychainAccessibilityPolicy.migrationTarget(
                  category: category, currentClass: current, requiresUserPresence: requiresUserPresence),
              let cfTarget = KeychainAccessibilityPolicy.secAttrAccessible(target) else {
            return .leftForUser
        }
        // The same non-interactive context: should the item need the user after all, the update fails instead of
        // asking. Only this fresh, never-evaluated context may be passed here, never a shared or already evaluated
        // one (e.g. `KeychainProtectionPolicy`'s session context): an update of `kSecAttrAccessible` replaces the
        // item's access control with one that carries the protection class only, so on a user-presence item it must
        // fail. The read-back below compares the class only and does not see the access control.
        var updateQuery = baseQuery
        updateQuery[kSecUseAuthenticationContext as String] = context
        let update: [String: Any] = [kSecAttrAccessible as String: cfTarget]
        let status = SecItemUpdate(updateQuery as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else {
            print("[\(tag)] accessibility upgrade failed status=\(status) (item left on legacy class, value untouched)")
            return .failed
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
            return .failed
        }
        print("[\(tag)] accessibility upgraded to after-first-unlock")
        return .upgraded
    }

    /// An authentication context that never shows anything to the user; nil where LocalAuthentication is missing.
    private static func nonInteractiveContext() -> AnyObject? {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
        #else
        return nil
        #endif
    }

    /// The status of one read of the item's value under `context`. With no context there is no way to read without
    /// possibly asking the user, so no read is made and the status is a failure.
    private static func probeStatus(baseQuery: [String: Any], context: AnyObject?) -> OSStatus {
        guard let context else { return errSecUnimplemented }
        var probe = baseQuery
        probe[kSecReturnData as String] = true
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        probe[kSecUseAuthenticationContext as String] = context
        var item: AnyObject?
        return SecItemCopyMatching(probe as CFDictionary, &item)
    }
    #endif
}
