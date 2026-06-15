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

    // MARK: - Read

    /// Return the pinned 32-byte Ed25519 public key for `contactId`, or `nil`
    /// when no pin exists yet (genuine first contact).
    public func pinnedKey(contactId: String) -> Data? {
        #if canImport(Security)
        guard !contactId.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: contactId,
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

    /// Trust-On-First-Use pin/compare for `contactId`'s long-term Ed25519 key.
    ///
    /// - No existing pin → store `ed25519Pub` and return `.pinnedNew`.
    /// - Existing pin equals `ed25519Pub` → return `.match` (no write).
    /// - Existing pin DIFFERS → return `.mismatch` and DO NOT overwrite — the
    ///   immutable-on-mismatch property is what makes a key-swap detectable.
    ///
    /// Returns `.mismatch` for a malformed argument (empty / not 32 bytes) so
    /// the caller fails closed rather than pinning garbage. The `@discardableResult`
    /// lets call sites that only care about the side-effect (first-contact pin
    /// after a successful verify) ignore the return.
    @discardableResult
    public func pinOrMatch(contactId: String, ed25519Pub: Data) -> PinResult {
        guard !contactId.isEmpty, ed25519Pub.count == 32 else { return .mismatch }

        if let existing = pinnedKey(contactId: contactId) {
            // Constant-time-ish compare is unnecessary here (the pinned key is
            // not secret — it is a public identity key), but `Data ==` is a
            // single length-checked memcmp which is fine.
            return existing == ed25519Pub ? .match : .mismatch
        }

        #if canImport(Security)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: contactId,
            kSecValueData as String: ed25519Pub,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Raced with another writer between the read above and this add.
            // Re-read and compare so two concurrent first-contacts converge on
            // ONE pin (and a racing different key is reported as a mismatch
            // rather than silently overwriting).
            if let now = pinnedKey(contactId: contactId) {
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

    /// Forget the pin for a single peer — used when the user explicitly resets
    /// a contact (the next handshake re-TOFU-pins).
    public func wipe(contactId: String) {
        #if canImport(Security)
        guard !contactId.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: contactId
        ]
        SecItemDelete(query as CFDictionary)
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
