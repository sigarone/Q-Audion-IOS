import Foundation
#if canImport(Security)
import Security
#endif

/// W-PSKBLIND (WIRE_SPEC §3.3.1.1) — Keychain-backed per-contact latch recording that
/// a peer has spoken the §3.3.1 BLINDED PSK advertisement at least once.
///
/// ## What it defends
///
/// A relay that logged this pair's OLD static fingerprints — constant for the life of
/// the key, which is the very leak §3.3.1 closes, so assume any long-lived observer has
/// them — can substitute them into a v3 OFFER and strip the Ed25519 signature. Client
/// policy is warn-and-proceed on a bad signature and never to drop the call
/// (W-NOBRICK), so the receiver's v3 match fails, its static match succeeds, it mirrors
/// static, and the blinding is switched off on demand.
///
/// Once this latch is set for a contact, their static advertisement stops being
/// honoured: no PSK, nothing echoed, said out loud in the log and in the assurance
/// state. The call still proceeds — the point is to make the downgrade loud, never to
/// drop the call.
///
/// ## Why a dedicated Keychain store
///
/// There is no relational contact row on iOS at all: the GRDB database holds only
/// conversations, messages and security events, and contacts live as JSON in
/// UserDefaults. `PeerIdentityPinStore`'s own header already argues this exact case for
/// a security pin and rejects `ContactsStore` in writing — it is rewritten on every
/// upsert (display-name edits, discover refreshes), and a pin must be
/// write-once-then-immutable. Same reasoning applies verbatim here, so this is the same
/// pattern with its own service namespace.
///
/// Storage mirrors `PeerIdentityPinStore` exactly: `kSecClassGenericPassword`,
/// accessibility `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (per-device, never
/// synced, never in an iCloud or iTunes backup), service
/// `com.bcrypto.qaudion.pskdialect`, account = the peer's `contactId`.
///
/// ## Accepted limits, stated rather than discovered later
///
/// Keyed by CONTACT, not by the per-device composite `PeerIdentityPinStore` uses. The
/// initiator leg has no server-stamped device id for the callee, so a per-device key is
/// not available on both legs, and a latch that only armed on one leg would be worse
/// than one that is slightly coarse. A multi-device contact running mixed builds during
/// the rollout can therefore get a refusal on its older device — a no-PSK call plus a
/// notice, never a broken one.
///
/// `WhenUnlockedThisDeviceOnly` means the latch does NOT survive a restore to a new
/// device, which returns that contact to permissive. That is a deliberate fail-open: a
/// latch that cannot be cleared eventually locks a user out of their own calls, and
/// W-NOBRICK is absolute here. It DOES survive app updates and reinstalls on the same
/// device, which is the case that matters.
///
/// It cannot be poisoned. Setting it requires a v3 resolution to SUCCEED, which requires
/// reproducing an HMAC tag over a secret we already hold — so only a peer that genuinely
/// shares a key with us can arm it, and a tag replayed from an earlier call fails because
/// the nonce binds both the callId and the sender's ephemeral key.
public final class PskAdvertDialectLatchStore {

    /// Keychain service namespace — distinct from `com.bcrypto.qaudion.peerpins` (peer
    /// identity pins) and `com.bcrypto.qaudion.sovereign` (this device's own identity),
    /// so the three never collide.
    private static let keychainService = "com.bcrypto.qaudion.pskdialect"

    /// The stored value is a presence sentinel, not data. Keychain rejects an empty
    /// value, so one byte it is; nothing ever reads it, only whether the item exists.
    private static let sentinel = Data([0x01])

    public init() {}

    /// Has this contact ever spoken the blinded advertisement?
    ///
    /// Synchronous, because the resolve that consumes it is on the handshake path and
    /// cannot await. Any Keychain failure reads as `false`, i.e. permissive — the same
    /// direction every other absent-pin default takes, and the only safe one for a
    /// signal whose false-positive would refuse a legitimate peer forever.
    public func hasSpokenBlindedAdvert(contactId: String) -> Bool {
        #if canImport(Security)
        guard !contactId.isEmpty else { return false }
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
            return false
        }
        return true
        #else
        return false
        #endif
    }

    /// Arm the latch for this contact. Idempotent, write-once-true — there is no unset
    /// path, by design: "this peer can speak v3" is a fact about their build, and
    /// clearing it on one anomalous call is exactly the downgrade the latch refuses.
    ///
    /// MUST only be called for a `.v3Blinded` resolution of the PEER's OWN
    /// advertisement. Resolving our own echoed value does not qualify: its dialect
    /// reports what THIS build emitted, so latching from there would arm every contact
    /// the instant the OFFER dialect flips — including peers that only ever spoke
    /// static, which we would then refuse forever.
    @discardableResult
    public func rememberSpokeBlindedAdvert(contactId: String) -> Bool {
        #if canImport(Security)
        guard !contactId.isEmpty else { return false }
        if hasSpokenBlindedAdvert(contactId: contactId) { return true }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: contactId,
            kSecValueData as String: Self.sentinel,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            print("[PskAdvertDialectLatchStore] \(contactId.prefix(8))… speaks the blinded PSK "
                + "advertisement — latched; a static advertisement from them will be refused "
                + "from now on (WIRE_SPEC §3.3.1.1)")
            return true
        }
        // A failed write leaves the contact permissive until the next blinded call. It
        // must never fail the call in progress.
        print("[PskAdvertDialectLatchStore] could not latch \(contactId.prefix(8))… (OSStatus \(status)) "
            + "— this contact stays permissive; the call is unaffected")
        return false
        #else
        return false
        #endif
    }

    /// Remove the latch for one contact. Exists for contact deletion and for support
    /// recovery when a peer has legitimately rolled back to a pre-v3 build — NOT called
    /// from any handshake path, because "clear it because this call looked odd" is the
    /// downgrade itself.
    @discardableResult
    public func forget(contactId: String) -> Bool {
        #if canImport(Security)
        guard !contactId.isEmpty else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: contactId
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #else
        return false
        #endif
    }
}
