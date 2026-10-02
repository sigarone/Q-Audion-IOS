import Foundation

/// R-VERIFIED-MARK: a SAS confirmation that COMMITS the durable identity pin of a peer device
/// (`AppState.adoptSasConfirmedSignerKeyIfUnresolved`, no pin and no server key: `identity_unresolved`)
/// marks the contact verified in the store the contact list and the group-call "Non verificato" badge
/// read (`ContactsStore.StoredContact.isVerified`), through the existing verification path
/// (`StoredContact.withVerification`, the same one the safety-number card writes), the same way on
/// every platform. The contact-detail trust card then shows the contact as verified by SAS even though
/// no server key could be fetched to evaluate it against.
///
/// The verification pin recorded is the safety number of (this account, the confirmed signer key), so a
/// later key rotation changes the computed number and the mark stops applying (`PeerTrustEvaluator`).
///
/// Pure (store, identity and clock are injected) so the rules are unit-tested in the engine target.
public enum SasPinVerification {

    /// The method recorded on the contact (`TrustVerificationMethod.antiReplay`'s raw value, the in-call SAS).
    public static let method = "anti-replay"

    /// Whether a SAS confirmation marks the contact verified, given what the pin policy decided and
    /// whether the durable write succeeded. Only a COMMITTED pin marks: a stored pin that already
    /// equals the confirmed key, or a new pin that was really written. A conflicting pin (an existing,
    /// different key), a failed Keychain write, and every refused confirmation never mark.
    public static func shouldMark(decision: SasSignerPinPolicy.Decision, durableWriteCommitted: Bool) -> Bool {
        switch decision {
        case .alreadyPinned: return true
        case .pin: return durableWriteCommitted
        case .conflict: return false
        }
    }

    /// Safety-number fingerprint (lowercase hex) of (self, peer) for the given identity keys, `nil`
    /// when an id or key is malformed (or both ids are equal).
    public static func fingerprintHex(
        selfUserId: String, selfIdentityKey: Data, peerUserId: String, peerIdentityKey: Data
    ) -> String? {
        guard let selfRaw = SafetyNumber.rawUuidBytes(fromUuidString: selfUserId),
              let peerRaw = SafetyNumber.rawUuidBytes(fromUuidString: peerUserId),
              let computed = try? SafetyNumber.compute(
                localUuidRaw: selfRaw, localIkEdPub: selfIdentityKey,
                peerUuidRaw: peerRaw, peerIkEdPub: peerIdentityKey)
        else { return nil }
        return computed.fingerprintHex
    }

    /// Mark `peerUserId` verified by SAS for `confirmedKey` (the signer key just pinned). Returns true
    /// when the contact was written. Nothing is written when the peer is not a stored contact (there is
    /// no row to mark), or the safety number cannot be computed.
    @discardableResult
    public static func markVerified(
        store: ContactsStore, peerUserId: String, selfUserId: String, selfIdentityKey: Data,
        confirmedKey: Data, nowMs: Int64
    ) -> Bool {
        guard confirmedKey.count == 32,
              let existing = store.load().first(where: { $0.userId == peerUserId }),
              let fp = fingerprintHex(
                selfUserId: selfUserId, selfIdentityKey: selfIdentityKey,
                peerUserId: peerUserId, peerIdentityKey: confirmedKey)
        else { return false }
        store.upsert(existing.withVerification(fingerprintHex: fp, atMs: nowMs, method: method))
        return true
    }

    /// The trust card's resolution when the peer's server key could not be fetched: the locally pinned
    /// key whose safety number is exactly the one recorded by a SAS confirmation of this contact
    /// (`verificationMethod == "anti-replay"` and `verifiedFingerprintHex` equal to the number computed
    /// from that pin). `nil` for a contact that was not SAS-verified, and for pins that do not match
    /// the recorded number (a rotated or replaced key never inherits the mark).
    public static func verifiedPinnedKey(
        contact: ContactsStore.StoredContact?, selfUserId: String, selfIdentityKey: Data,
        peerUserId: String, pinnedKeys: [Data]
    ) -> (key: Data, fingerprintHex: String)? {
        guard let contact, contact.isVerified,
              contact.verificationMethod == method,
              let recorded = contact.verifiedFingerprintHex, !recorded.isEmpty else { return nil }
        for key in pinnedKeys where key.count == 32 {
            guard let fp = fingerprintHex(
                selfUserId: selfUserId, selfIdentityKey: selfIdentityKey,
                peerUserId: peerUserId, peerIdentityKey: key) else { continue }
            if fp == recorded { return (key, fp) }
        }
        return nil
    }
}
