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
        ///
        /// W-NFCBIND — the generic blob grew a second field (`"<class>;origin=<o>"`,
        /// see `Blob`), so only the part before the first `;` is the class. A
        /// legacy blob has no separator and is its own first field, which is why
        /// the split is safe to apply unconditionally: without it a
        /// class-plus-origin blob would fall through to `.shared` and silently
        /// demote an hw_only contact, defeating the D4 policy that reads it.
        public static func parse(_ wire: String?) -> KeyClass {
            switch wire?.split(separator: ";", maxSplits: 1).first.map(String.init) {
            case "hw_only": return .hwOnly
            case "sw_only": return .swOnly
            default:        return .shared
            }
        }
    }

    /// W-NFCBIND — encoding of the `kSecAttrGeneric` byte blob, which now
    /// carries two independent facts about an entry.
    ///
    /// Format: `"<class>"` (legacy, pre-W-NFCBIND) or `"<class>;origin=<origin>"`.
    /// Both parse correctly in both directions: an old build reading a new blob
    /// gets the class it expects because `KeyClass.parse` splits on `;`, and a
    /// new build reading an old blob finds no origin field and falls back to
    /// `PskOrigin.inferred(fromAccountName:)`.
    ///
    /// Keeping it in the existing attribute rather than adding a second Keychain
    /// item matters for `migratePskProtection`, which deletes and re-adds every
    /// entry when biometric protection is toggled: it already carries this blob
    /// through that window, so the origin survives for free. A sidecar item
    /// would have needed its own migration path and could desynchronise from the
    /// key it describes.
    private enum Blob {
        static func encode(keyClass: KeyClass?, origin: PskOrigin?, nfcPeerIdentityKey: Data? = nil) -> Data? {
            guard keyClass != nil || origin != nil || nfcPeerIdentityKey != nil else { return nil }
            // A blob that carries only an origin still needs the class field
            // present so the separator has a left-hand side; `.shared` is what
            // an absent class already means.
            var s = (keyClass ?? .shared).rawValue
            if let origin { s += ";origin=" + origin.rawValue }
            // W-NFCIDBIND (2026-07-29) — the peer's 32-byte Ed25519 identity
            // pubkey captured at the NFC tap itself, hex-encoded. This is the
            // ONLY place that identity is ever recorded: nothing else in this
            // codebase persists it, and `AssuranceState.resolveNfcMixInputs`'s
            // `nfcBound` check needs the REAL captured identity to compare
            // against the peer's verified identity key at call time — the
            // fingerprint field is SHA-256(psk), an unrelated 32 bytes, and
            // comparing it to an identity key can never legitimately match.
            if let nfcPeerIdentityKey {
                s += ";nfcpid=" + nfcPeerIdentityKey.map { String(format: "%02x", $0) }.joined()
            }
            return Data(s.utf8)
        }

        /// The origin recorded in the blob, or nil for a legacy blob that has
        /// none. Deliberately nil rather than a default, so the caller can tell
        /// "no origin was ever written" apart from "the origin is manual" and
        /// apply the name-based fallback only in the first case.
        static func origin(_ data: Data?) -> PskOrigin? {
            guard let data, let s = String(data: data, encoding: .utf8) else { return nil }
            for field in s.split(separator: ";") where field.hasPrefix("origin=") {
                return PskOrigin(rawValue: String(field.dropFirst("origin=".count)))
            }
            return nil
        }

        /// W-NFCIDBIND — the peer identity pubkey captured at tap time, or nil
        /// when this entry never recorded one (every non-NFC entry, and any
        /// NFC entry written before this field existed).
        static func nfcPeerIdentityKey(_ data: Data?) -> Data? {
            guard let data, let s = String(data: data, encoding: .utf8) else { return nil }
            for field in s.split(separator: ";") where field.hasPrefix("nfcpid=") {
                return DeviceRenewBlob.hexDecode(String(field.dropFirst("nfcpid=".count)))
            }
            return nil
        }
    }

    public init() {}

    /// Phase-1 (D1) overload — store a PSK WITH its key_class. The class is
    /// persisted in `kSecAttrGeneric`; everything else is byte-identical to the
    /// legacy `storePsk(name:key:fingerprint:)` path (which now forwards here
    /// with `keyClass: nil`, leaving the generic slot empty → reads back as
    /// `.shared`).
    /// W-NFCBIND overload — store a PSK with its key_class AND its provenance.
    /// The two share the `kSecAttrGeneric` blob (see `Blob`). Callers that do
    /// not know the provenance keep using the 4-arg form and the entry falls
    /// back to the name-based inference on read.
    public func storePsk(
        name: String,
        key: Data,
        fingerprint: String,
        keyClass: KeyClass?,
        origin: PskOrigin?,
        // W-NFCIDBIND (2026-07-29) — the peer's 32-byte Ed25519 identity
        // pubkey captured AT THE NFC TAP ITSELF, when `origin == .nfc`. This
        // is the only place that identity is ever recorded going forward;
        // `AssuranceState.resolveNfcMixInputs`'s `nfcBound` check compares
        // THIS against the peer's verified identity key at call time — never
        // the fingerprint (SHA-256(psk), an unrelated 32 bytes that can never
        // legitimately equal an identity key). nil for every non-NFC call
        // site, byte-identical to the pre-existing blob.
        nfcPeerIdentityKey: Data? = nil
    ) throws {
        try storeInternal(name: name, key: key, fingerprint: fingerprint,
                          blob: Blob.encode(keyClass: keyClass, origin: origin, nfcPeerIdentityKey: nfcPeerIdentityKey))
    }

    public func storePsk(name: String, key: Data, fingerprint: String, keyClass: KeyClass?) throws {
        // IOS-SE: fresh writes honor the current protection policy. When
        // biometric key protection is enabled, attach a `.userPresence`
        // access control; otherwise the plain class from
        // `KeychainAccessibilityPolicy` (W-KCAFTERUNLOCK). Existing items are
        // re-protected via `migratePskProtection(enable:)`, not here, because
        // SecItemUpdate cannot change an item's access-control class.
        // D1: the key_class string (if any) goes into kSecAttrGeneric — a raw
        // byte blob attribute that does NOT collide with the fingerprint label.
        // W-NFCBIND: with `origin: nil` this encodes to exactly the old bytes,
        // so existing call sites write a byte-identical blob.
        try storeInternal(name: name, key: key, fingerprint: fingerprint,
                          blob: Blob.encode(keyClass: keyClass, origin: nil))
    }

    private func storeInternal(name: String, key: Data, fingerprint: String, blob classBlob: Data?) throws {
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
            // W-KCAFTERUNLOCK (2026-09-01) — the plain class comes from the one
            // policy (AfterFirstUnlockThisDeviceOnly today) so a PSK is readable
            // on a VoIP-push wake with the phone locked; the `.userPresence`
            // branch above is untouched. See KeychainAccessibilityPolicy.
            query[kSecAttrAccessible as String] = KeychainAccessibilityPolicy.secAttrAccessible(for: .sessionPsk)
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
        // W-VAULTREFRESH — mirrors `ContactsStore.save()`'s own
        // `.contactsDidChange` post: every write funnels through here (both
        // `storePsk` overloads), so this is the ONE place that needs to
        // notify for a listing UI (`KeyManagementScreen`'s
        // `KeyRotationCoordinator.vaultKeys`) to refresh reactively instead
        // of only at its own one-shot `init()`. Fixes: a PSK written by a
        // path that doesn't itself know about that coordinator (e.g.
        // `NfcExchangeView.persistPsk` after an NFC tap) previously left the
        // vault list stale until the whole screen was torn down and
        // recreated (leave/re-enter) — see that coordinator's doc.
        NotificationCenter.default.post(name: .sovereignVaultDidChange, object: nil)
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

    /// W-NFCBIND reader — where this entry came from.
    ///
    /// The persisted tag wins; a legacy entry that has none falls back to
    /// `PskOrigin.inferred(fromAccountName:)`, which is why NFC keys already on
    /// devices are covered without a migration step.
    public func origin(name: String) -> PskOrigin {
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
        if status == errSecSuccess, let attrs = item as? [String: Any],
           let recorded = Blob.origin(attrs[kSecAttrGeneric as String] as? Data) {
            return recorded
        }
        #endif
        return PskOrigin.inferred(fromAccountName: name)
    }

    /// W-NFCIDBIND (2026-07-29) reader — the peer's 32-byte Ed25519 identity
    /// pubkey captured at NFC-tap time for this entry, or `nil` when this
    /// entry never recorded one (every non-NFC entry, and any NFC entry
    /// written before this field existed — those keep degrading to plain PSK
    /// in `resolveNfcMixInputs`, exactly as an entry with no vault match at
    /// all already does).
    ///
    /// Deliberately separate from `origin(name:)`/`getKeyClass(name:)` rather
    /// than folded into a combined return, so a caller that only needs this
    /// one fact (`AppState`'s `resolveNfcMixInputs` wiring) doesn't have to
    /// know the other two exist.
    public func nfcPeerIdentityKey(name: String) -> Data? {
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
        if status == errSecSuccess, let attrs = item as? [String: Any] {
            return Blob.nfcPeerIdentityKey(attrs[kSecAttrGeneric as String] as? Data)
        }
        #endif
        return nil
    }

    /// W-NFCBIND — raw material for an entry that is about to LEAVE the device
    /// (a QR export, a device-linking snapshot, a backup archive).
    ///
    /// Every egress path must call THIS, never `loadPsk`. The split is the
    /// point: `loadPsk` is for using the key here — the handshake, message
    /// decryption — and must keep working for NFC keys, while this is the one
    /// door outward. Enforcing in the vault rather than in each caller means a
    /// future export surface has to opt in explicitly instead of inheriting the
    /// leak, which is exactly how Android ended up QR-exporting NFC secrets.
    ///
    /// - Throws: `KeyVaultError.notExportable` when the origin forbids it.
    public func exportableMaterial(name: String) throws -> Data? {
        let o = origin(name: name)
        guard o.isExportable else {
            throw KeyVaultError.notExportable(origin: o, name: name)
        }
        return try loadPsk(name: name)
    }

    /// The subset of `listPskNames()` whose material may leave the device.
    /// For whoever builds an export or device-linking flow later, so the filter
    /// is in place before the feature is.
    public func exportablePskNames() -> [String] {
        listPskNames().filter { origin(name: $0).isExportable }
    }

    /// - Returns: the PSK, or `nil` when no item exists under `name`.
    /// - Throws: `KeyVaultError.deviceLocked` when the item cannot be decrypted
    ///   because the device is locked (-25308) — it may well exist, retry after
    ///   unlock; `KeyVaultError.loadFailed` for any other Keychain status.
    public func loadPsk(name: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            // W-KCAFTERUNLOCK (2026-09-01) — attributes ride along with the
            // data (one round trip, same shape `migratePskProtection` already
            // reads) so an item still on the legacy class can be upgraded in
            // place right after the read that proved it readable.
            kSecReturnAttributes as String: true,
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
        switch KeychainAccessibilityPolicy.classifyRead(status: status) {
        case .absent:
            return nil
        case .deviceLocked:
            // W-KCAFTERUNLOCK — -25308: the item may exist, the Keychain is
            // just not readable yet (locked before first unlock). Distinct from
            // `.loadFailed` so no caller can mistake it for "no such PSK".
            throw KeyVaultError.deviceLocked
        case .failed(let failedStatus):
            throw KeyVaultError.loadFailed(failedStatus)
        case .found:
            break
        }
        guard let attrs = item as? [String: Any] else { return nil }
        KeychainAccessibilityMigration.upgradeIfNeeded(
            attributes: attrs,
            baseQuery: [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: name
            ],
            category: .sessionPsk,
            tag: "SovereignKeyVault")
        return attrs[kSecValueData as String] as? Data
    }

    public func deletePsk(name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyVaultError.deleteFailed(status) }
        // W-VAULTREFRESH — see `storeInternal`'s matching post; a deletion
        // changes vault membership exactly as much as a write does.
        NotificationCenter.default.post(name: .sovereignVaultDidChange, object: nil)
    }

    /// P0-5 (2026-08-05, coordinated fix plan cluster 5) — bulk wipe for
    /// `remote_wipe` / account deletion. One Keychain call, no
    /// `kSecAttrAccount` filter, so it removes every PSK this vault holds
    /// regardless of name — the caller doesn't need `listPskNames()` first.
    /// `errSecItemNotFound` (vault already empty) is not an error.
    public func clearAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyVaultError.deleteFailed(status)
        }
        NotificationCenter.default.post(name: .sovereignVaultDidChange, object: nil)
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

    /// W-PSKMIX step 3 — same enumeration as `listPskNames()`, paired with
    /// each item's Keychain-recorded creation date. `kSecAttrCreationDate` is
    /// already tracked automatically by every `kSecClassGenericPassword`
    /// item; this just reads an attribute no caller previously asked for, no
    /// new persisted state. Used to build a stable, deterministic PSK
    /// advertise order (oldest-registered first) instead of falling back to
    /// whatever order `SecItemCopyMatching` happens to enumerate in, which
    /// is unspecified and not guaranteed stable across calls.
    public func listPskEntries() -> [(name: String, createdAt: Date?)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let results = items as? [[String: Any]] else { return [] }
        return results.compactMap { attrs in
            guard let name = attrs[kSecAttrAccount as String] as? String else { return nil }
            return (name: name, createdAt: attrs[kSecAttrCreationDate as String] as? Date)
        }
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
    ///                     class `KeychainAccessibilityPolicy` assigns to
    ///                     `.sessionPsk`).
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
                // W-KCAFTERUNLOCK — the plain (no access control) class is the
                // policy's, so disabling protection lands on the same class a
                // fresh `storePsk` writes.
                add[kSecAttrAccessible as String] = KeychainAccessibilityPolicy.secAttrAccessible(for: .sessionPsk)
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
                    restore[kSecAttrAccessible as String] = KeychainAccessibilityPolicy.secAttrAccessible(for: .sessionPsk)
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
    /// W-KCAFTERUNLOCK (2026-09-01) — `errSecInteractionNotAllowed` (-25308):
    /// the Keychain refused to decrypt the item because the device is locked
    /// (before the first unlock since boot for an AfterFirstUnlock item; any
    /// lock for a legacy WhenUnlocked one). The item is NOT known to be
    /// absent. Transient — retry after unlock; never regenerate or delete on
    /// it. See KeychainAccessibilityPolicy.
    case deviceLocked
    /// W-NFCBIND — raw material was requested for an entry that may not leave
    /// the device. Carries the origin so the UI can say *why*: "created by an
    /// NFC tap, it cannot leave this device" is actionable, "export failed"
    /// invites a retry.
    case notExportable(origin: PskOrigin, name: String)
}

// MARK: - Notification names

public extension Notification.Name {
    /// W-VAULTREFRESH — posted by `SovereignKeyVault.storePsk`/`deletePsk`
    /// (every write/delete path) whenever the vault's PSK membership may have
    /// changed. Mirrors `ContactsStore`'s own `.contactsDidChange` convention
    /// exactly, for the same reason: a listing UI (`KeyRotationCoordinator
    /// .vaultKeys`) needs to refresh reactively instead of only once at
    /// `init()`, regardless of WHICH code path wrote the new entry (QR
    /// import, NFC pairing, KMS delivery, rotation, …).
    static let sovereignVaultDidChange = Notification.Name("qaudion.sovereignVault.didChange")
}
