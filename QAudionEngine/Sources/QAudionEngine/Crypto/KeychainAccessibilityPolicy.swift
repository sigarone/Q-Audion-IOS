import Foundation
#if canImport(Security)
import Security
#endif

/// W-KCAFTERUNLOCK (2026-09-01) — single source of truth for the Keychain
/// accessibility class each category of item is written with, and for how a
/// read that fails with `errSecInteractionNotAllowed` (-25308) must be read.
///
/// WHY. Incoming calls reach this app through a VoIP push, which can wake the
/// process while the phone is locked — including BEFORE the first unlock after
/// a reboot. The call path then reads the sovereign identity
/// (`SovereignIdentityManager`), the session PSKs (`SovereignKeyVault`) and the
/// ratchet state (`KeychainRatchetVault`) from the Keychain. All three were
/// written `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, which the system
/// refuses to decrypt while locked: the read fails with -25308, and every one of
/// those vaults collapsed that status into `nil` — the same answer as "never
/// stored". A caller that regenerates on "never stored" could then mint a new
/// identity or derive a fresh ratchet chain over the real one; a caller that
/// just gives up drops the call. See audit memory
/// reference_ios_stability_audit_2026_09_01 (P1 item 5:
/// SovereignIdentityManager.swift:214, SovereignKeyVault.swift:160-163,
/// KeychainRatchetVault.swift:6-9, QAudionKeyStore.swift:20).
///
/// RULE. Items a background wake needs are stored
/// `AfterFirstUnlockThisDeviceOnly` — readable once the user has unlocked the
/// phone once since boot, still never synced and never restored to another
/// device (the `ThisDeviceOnly` half is unchanged). Items that already sit
/// behind a `.userPresence` access control (biometric key protection ON,
/// `KeychainProtectionPolicy`) are left exactly as they are: their whole point
/// is to require the user, and an access control cannot be edited in place
/// anyway. Items only ever read with the app in the foreground keep
/// `WhenUnlockedThisDeviceOnly`. And -25308 is classified as "locked, retry
/// later" — a distinct outcome from "absent" — so no caller can confuse the two
/// again. This is the platform's own guidance for data that background
/// launches need; the contacts key already moved for the same reason
/// (`ContactsStore.upgradeAccessibilityIfNeeded`, W-CONTACTLOCKED).
///
/// Pure: no Keychain call in this type, so every branch is pinned by
/// `KeychainAccessibilityPolicyTests` on the CI simulator. The attribute-only
/// upgrade of items already on disk lives in `KeychainAccessibilityMigration`.
public enum KeychainAccessibilityPolicy {

    // MARK: - Kill switches (compile-time, same discipline as
    // `CallCapabilities.longAudioSendEnabled` / `RestartIceDecisions`)

    /// `true`  → identity / session-PSK / ratchet items are written
    ///           `AfterFirstUnlockThisDeviceOnly`, and an existing item still on
    ///           the legacy class is upgraded in place the first time it is
    ///           read successfully.
    /// `false` → every category keeps `WhenUnlockedThisDeviceOnly` and no
    ///           migration ever runs (byte-identical to the pre-W-KCAFTERUNLOCK
    ///           write path). Items already upgraded are NOT downgraded — that
    ///           would need a second migration and protects nothing the
    ///           message database (`completeUntilFirstUserAuthentication`) and
    ///           the contacts key do not already expose.
    /// Rollback is this line.
    public static let backgroundKeyAccessEnabled: Bool = true

    /// `true`  → a Keychain read that fails with -25308 surfaces as
    ///           `.deviceLocked` (typed, transient) instead of being folded into
    ///           the generic failure / `nil` the vaults used to return.
    /// `false` → legacy mapping (generic failure), independent of the flag
    ///           above. Rollback is this line.
    public static let lockedReadIsTransientEnabled: Bool = true

    // MARK: - Vocabulary

    /// What a Keychain item is FOR — the only input the class decision needs.
    public enum ItemCategory: CaseIterable, Equatable {
        /// This device's sovereign X25519 + Ed25519 identity
        /// (`SovereignIdentityManager`, service `com.bcrypto.qaudion.sovereign`).
        case sovereignIdentity
        /// Session PSKs and the `__device.*` long-term keys sharing that vault
        /// (`SovereignKeyVault`, service `com.bcrypto.qaudion.psk`) when NOT
        /// under a `.userPresence` access control.
        case sessionPsk
        /// v3.1 snapshots and v4 opaque session blobs
        /// (`KeychainRatchetVault`, services `…ratchet.v1` / `…ratchet.v4`).
        case ratchetState
        /// Anything only ever read with the app in the foreground and the
        /// device unlocked (`QAudionKeyStore` backup / credential blobs).
        case uiOnly
    }

    /// The subset of `kSecAttrAccessible` values this policy reasons about.
    public enum AccessClass: Equatable {
        case whenUnlockedThisDeviceOnly
        case afterFirstUnlockThisDeviceOnly
        /// Any other value the system may report (a class this codebase never
        /// wrote). Never migrated from, never migrated to.
        case other
    }

    // MARK: - Write side

    /// The class a FRESH item of `category` is written with.
    public static func accessClass(for category: ItemCategory) -> AccessClass {
        guard backgroundKeyAccessEnabled else { return .whenUnlockedThisDeviceOnly }
        switch category {
        case .sovereignIdentity, .sessionPsk, .ratchetState:
            return .afterFirstUnlockThisDeviceOnly
        case .uiOnly:
            return .whenUnlockedThisDeviceOnly
        }
    }

    // MARK: - Read side: in-place upgrade decision

    /// Given what a successful read reported about an EXISTING item, the class
    /// it should be moved to with an attribute-only `SecItemUpdate`, or `nil`
    /// when it must be left alone. `nil` is the answer for everything except
    /// the one legacy shape this codebase wrote: no access control, currently
    /// `WhenUnlockedThisDeviceOnly`, in a category that now wants
    /// `AfterFirstUnlockThisDeviceOnly`. An unreadable / unknown current class
    /// is left untouched rather than guessed at.
    public static func migrationTarget(
        category: ItemCategory,
        currentClass: AccessClass?,
        hasAccessControl: Bool
    ) -> AccessClass? {
        guard backgroundKeyAccessEnabled else { return nil }
        // A `.userPresence` item stays as it is: the access control IS the
        // user's choice, and `SecItemUpdate` cannot rewrite one in place.
        guard !hasAccessControl else { return nil }
        let target = accessClass(for: category)
        guard target == .afterFirstUnlockThisDeviceOnly else { return nil }
        guard let current = currentClass, current == .whenUnlockedThisDeviceOnly else { return nil }
        return target
    }

    // MARK: - Read side: status classification

    /// `errSecInteractionNotAllowed` — the status the system returns when an
    /// item exists but its class forbids decrypting it right now (device
    /// locked). Pinned against the Security constant by the tests.
    public static let deviceLockedStatus: OSStatus = -25308
    /// `errSecItemNotFound`.
    static let itemNotFoundStatus: OSStatus = -25300
    /// `errSecSuccess`.
    static let successStatus: OSStatus = 0

    /// The four things a `SecItemCopyMatching` status can mean to a vault.
    public enum ReadOutcome: Equatable {
        case found
        case absent
        /// The item may well exist; the Keychain is just not readable yet.
        /// Transient: retry after the user unlocks. NEVER "absent".
        case deviceLocked
        case failed(OSStatus)
    }

    public static func classifyRead(status: OSStatus) -> ReadOutcome {
        if status == successStatus { return .found }
        if status == itemNotFoundStatus { return .absent }
        if status == deviceLockedStatus && lockedReadIsTransientEnabled { return .deviceLocked }
        return .failed(status)
    }

    // MARK: - Bridging to Security constants (the only non-pure corner)

    #if canImport(Security)
    /// The `kSecAttrAccessible` value to put in a `SecItemAdd` query for a
    /// fresh item of `category`.
    public static func secAttrAccessible(for category: ItemCategory) -> CFString {
        switch accessClass(for: category) {
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly, .other:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }

    /// `nil` for `.other` — there is no constant to write for a class this
    /// policy does not own.
    public static func secAttrAccessible(_ accessClass: AccessClass) -> CFString? {
        switch accessClass {
        case .whenUnlockedThisDeviceOnly:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .other:
            return nil
        }
    }

    /// Parse the `kSecAttrAccessible` attribute a `kSecReturnAttributes` read
    /// hands back. `nil` when the attribute is missing or not a string.
    public static func accessClass(fromAttribute value: Any?) -> AccessClass? {
        guard let raw = value as? String else { return nil }
        if raw == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) {
            return .whenUnlockedThisDeviceOnly
        }
        if raw == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) {
            return .afterFirstUnlockThisDeviceOnly
        }
        return .other
    }
    #endif
}
