import Foundation
#if canImport(Security)
import Security
#endif

/// Phase-10b handshake-signing — Keychain-backed TOFU pin store for peer
/// long-term Ed25519 identity keys (HANDSHAKE-SIGNING-SPEC.md §2 / §5c).
///
/// To verify a peer's handshake signature you need its AUTHENTIC 32-byte
/// long-term Ed25519 identity key. This store implements the Trust-On-First-Use
/// floor: the first valid-signature handshake pins the peer's key; every
/// subsequent handshake MUST match that pin or the verifier fails closed
/// (`identity_key_mismatch` — the MITM / key-swap alarm). The pin is the
/// iOS mirror of Android `PeerTrustRepository.checkOrPinTrust` and Desktop
/// `ContactsStore` TOFU pin.
///
/// **Why a dedicated store** (vs reusing `ContactsStore.pubkey`): `ContactsStore`
/// holds the pubkey only when the QR-pairing flow populated it; it is rewritten
/// on every `upsert` (display-name edits, discover-v2 refresh, …). A TOFU pin
/// MUST be write-once-then-immutable on mismatch, so it lives in its own
/// Keychain item that `pinOrMatch` never overwrites once set. `ContactsStore`
/// remains the SERVER/QR-fetched trust source consulted BEFORE this pin
/// (spec §5c order: pin → server/QR → bundle-key-as-TOFU-candidate).
///
/// **Storage** mirrors `SovereignIdentityManager`'s Keychain pattern exactly:
/// `kSecClassGenericPassword`, accessibility
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (per-device, never synced /
/// never in an iCloud or iTunes backup), service `com.bcrypto.qaudion.peerpins`,
/// account = the peer's `contactId`. The stored value is the RAW 32-byte
/// Ed25519 public key (no base64 — same RAW convention the transcript uses).
///
/// **Additive-safety:** this is a brand-new file with NO references to any
/// existing type; nothing reads or writes these Keychain items today, so it
/// cannot change any current behaviour. It is exercised only once the
/// handshake-signing closures in `QAudionCallIntegration` are wired (which are
/// themselves nil-by-default and only set in `AppState`).
public final class PeerIdentityPinStore {

    /// Outcome of `pinOrMatch` (HANDSHAKE-SIGNING-SPEC.md §2).
    public enum PinResult: Equatable {
        /// No pin existed — the argument key was pinned now (TOFU first contact).
        case pinnedNew
        /// A pin existed and it equals the argument key — the steady-state case.
        case match
        /// A pin existed and it DIFFERS from the argument key — the MITM /
        /// key-swap alarm. The existing pin is left UNCHANGED (never
        /// overwritten); the caller fails the handshake closed.
        case mismatch
    }

    /// Keychain service namespace — distinct from the local-identity service
    /// (`com.bcrypto.qaudion.sovereign`) so peer pins and the local sovereign
    /// identity never collide.
    private static let keychainService = "com.bcrypto.qaudion.peerpins"

    public init() {}

    // MARK: - Account keying (D11 per-(peer,device))

    /// The `kSecAttrAccount` for a pin. D11: a pin is keyed per-(peer, deviceId)
    /// so a peer's SECOND device pins as a NEW Keychain entry (`.pinnedNew`)
    /// rather than tripping `.mismatch` against the first device's pin.
    ///
    /// - `deviceId == nil` / empty → the LEGACY bare-`contactId` account (the
    ///   pre-D11 shape). This is BOTH the migration anchor (an existing bare pin
    ///   is read/kept under this account) AND the graceful fallback when the
    ///   server did not stamp `sender_device_id` (legacy caller / pre-Step-1
    ///   envelope) — so a null device id keeps using the legacy single-key pin
    ///   and NEVER manufactures a spurious mismatch.
    /// - `deviceId` non-empty → the composite `"<contactId>|<deviceId>"` account.
    private static func account(_ contactId: String, _ deviceId: String?) -> String {
        if let d = deviceId, !d.isEmpty {
            return contactId + "|" + d
        }
        return contactId
    }

    // MARK: - Read

    /// Return the pinned 32-byte Ed25519 public key for `(contactId, deviceId)`,
    /// or `nil` when no pin exists yet (genuine first contact for THIS device).
    ///
    /// D11 migration: when a per-device pin is absent but `deviceId` is non-nil,
    /// fall back to the LEGACY bare-`contactId` pin (the pre-D11 single-key pin
    /// for the peer's first/legacy device). This stops every existing pin from
    /// reading as "no pin → first contact" the first time a concrete device id is
    /// threaded — which would silently re-TOFU and briefly weaken the pin.
    public func pinnedKey(contactId: String, deviceId: String? = nil) -> Data? {
        guard !contactId.isEmpty else { return nil }
        if let exact = rawPinnedKey(account: Self.account(contactId, deviceId)) {
            return exact
        }
        // Per-device miss → legacy bare-contactId pin (the first/legacy device).
        if let d = deviceId, !d.isEmpty {
            return rawPinnedKey(account: contactId)
        }
        return nil
    }

    /// Raw single-account Keychain read (no migration fallback).
    private func rawPinnedKey(account: String) -> Data? {
        #if canImport(Security)
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            return nil
        }
        return data
        #else
        return nil
        #endif
    }

    // MARK: - Pin-or-match (TOFU)

    /// Trust-On-First-Use pin/compare for `(contactId, deviceId)`'s long-term
    /// Ed25519 key.
    ///
    /// - No existing pin → store `ed25519Pub` and return `.pinnedNew`.
    /// - Existing pin equals `ed25519Pub` → return `.match` (no write).
    /// - Existing pin DIFFERS → return `.mismatch` and DO NOT overwrite — the
    ///   immutable-on-mismatch property is what makes a key-swap detectable.
    ///
    /// D11: the pin is write-once-immutable per-(peer, device). A SECOND device
    /// for the same peer resolves to a different account → no existing pin →
    /// `.pinnedNew` (not `.mismatch`). When `deviceId` is nil/empty the legacy
    /// bare-`contactId` account is used (migration anchor / graceful fallback).
    ///
    /// Returns `.mismatch` for a malformed argument (empty / not 32 bytes) so
    /// the caller fails closed rather than pinning garbage. The `@discardableResult`
    /// lets call sites that only care about the side-effect (first-contact pin
    /// after a successful verify) ignore the return.
    @discardableResult
    public func pinOrMatch(contactId: String, ed25519Pub: Data, deviceId: String? = nil) -> PinResult {
        guard !contactId.isEmpty, ed25519Pub.count == 32 else { return .mismatch }

        let account = Self.account(contactId, deviceId)

        // Migration anchor: if there is NO per-device pin yet but a LEGACY bare
        // pin exists for this peer, treat the legacy pin as THIS (first/legacy)
        // device's pin so a concrete device id does not orphan it into a silent
        // re-TOFU. Compare against the legacy pin; on a match it stays put (it is
        // already the immutable first-device pin), on a difference it is the
        // mismatch alarm — exactly the pre-D11 semantics for the first device.
        if let d = deviceId, !d.isEmpty,
           rawPinnedKey(account: account) == nil,
           let legacy = rawPinnedKey(account: contactId) {
            return legacy == ed25519Pub ? .match : .mismatch
        }

        if let existing = rawPinnedKey(account: account) {
            // Constant-time-ish compare is unnecessary here (the pinned key is
            // not secret — it is a public identity key), but `Data ==` is a
            // single length-checked memcmp which is fine.
            return existing == ed25519Pub ? .match : .mismatch
        }

        #if canImport(Security)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: ed25519Pub,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Raced with another writer between the read above and this add.
            // Re-read and compare so two concurrent first-contacts converge on
            // ONE pin (and a racing different key is reported as a mismatch
            // rather than silently overwriting).
            if let now = rawPinnedKey(account: account) {
                return now == ed25519Pub ? .match : .mismatch
            }
            return .mismatch
        }
        guard status == errSecSuccess else {
            // A failed write (e.g. device locked / interaction-not-allowed)
            // must NOT be reported as a successful pin. Treat as mismatch so the
            // caller fails closed; the pin can be retried on a later handshake.
            return .mismatch
        }
        return .pinnedNew
        #else
        return .mismatch
        #endif
    }

    // MARK: - Wipe

    /// Forget the pin(s) for a single peer — used when the user explicitly resets
    /// a contact (the next handshake re-TOFU-pins).
    ///
    /// - `deviceId == nil` → wipe BOTH the legacy bare-`contactId` pin AND every
    ///   per-device pin for the peer (full per-peer reset).
    /// - `deviceId` non-empty → wipe only that one device's pin.
    public func wipe(contactId: String, deviceId: String? = nil) {
        #if canImport(Security)
        guard !contactId.isEmpty else { return }
        if let d = deviceId, !d.isEmpty {
            deleteAccount(Self.account(contactId, d))
            return
        }
        // Full per-peer reset: the legacy bare account + all "<contactId>|<dev>"
        // composite accounts. Keychain has no prefix-delete, so enumerate this
        // service's accounts and delete the ones that belong to this peer.
        deleteAccount(contactId)
        let prefix = contactId + "|"
        for acct in allAccounts() where acct.hasPrefix(prefix) {
            deleteAccount(acct)
        }
        #endif
    }

    /// Delete one Keychain account in this service. No-op if absent.
    private func deleteAccount(_ account: String) {
        #if canImport(Security)
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    /// Enumerate every `kSecAttrAccount` stored under this service. Used only by
    /// the full per-peer `wipe` to find composite accounts to delete.
    private func allAccounts() -> [String] {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let arr = items as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { $0[kSecAttrAccount as String] as? String }
        #else
        return []
        #endif
    }

    /// Forget every peer pin (account wipe / logout).
    public func wipeAll() {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}
