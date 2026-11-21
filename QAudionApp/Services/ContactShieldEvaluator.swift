import Foundation
import QAudionEngine

/// Reads the stores that hold the key-bound verification record of a contact and hands them to the pure rules of
/// `IdentityShieldRules` (QAudionEngine, where the CI job that runs on every push compiles their tests). Nothing here decides
/// anything: it gathers the pinned keys, the stored in-call confirmation and the stored safety-number verification, and the
/// identity of this account.
///
/// Used by every surface that shows the identity shield outside a call (contact list, contact detail, chat header, chat list,
/// the car screen) and by the live call (`keyVerification`).
enum ContactShieldEvaluator {

    /// The identity of this account: the safety number of a pair of identities needs both.
    struct Context {
        let selfUserId: String?
        let selfIdentityKey: Data?
    }

    static func currentContext() -> Context {
        Context(selfUserId: TokenVault.loadUserId(),
                selfIdentityKey: SovereignIdentityManager().loadIdentity()?.signingPublic)
    }

    /// The stored verification of a peer: the identity tag of the in-call confirmation and the safety number attested on the
    /// contact screen (or by an in-person ceremony).
    static func record(peerUserId: String, contact: ContactsStore.StoredContact?) -> IdentityVerificationRecord {
        IdentityVerificationRecord(
            bindingTag: SasVerificationStore.shared.storedBinding(peerUserId: peerUserId)?.identityTag,
            verifiedFingerprintHex: contact?.verifiedFingerprintHex)
    }

    /// How the stored verification of `peerUserId` relates to `authKey`, the key a call was authenticated by, for the peer
    /// device `deviceId`.
    ///
    /// Known limit (accepted): `PeerIdentityPinStore.pinnedKey(contactId:deviceId:)` reads the legacy bare-account pin as the pin of
    /// a device that has none of its own, and the in-call confirmation is stored per peer, not per device. A new device of a peer
    /// whose only pin is the legacy one can therefore read as "changed" (red) instead of "to verify" (purple). That fails safe, and
    /// a per-device store is a separate change (a new key format).
    static func keyVerification(authKey: Data, peerUserId: String, deviceId: String?) -> KeyVerification {
        let ctx = currentContext()
        let contact = ContactsStore().load().first(where: { $0.userId == peerUserId })
        return IdentityShieldRules.keyVerification(
            authKey: authKey,
            devicePin: PeerIdentityPinStore().pinnedKey(contactId: peerUserId, deviceId: deviceId),
            record: record(peerUserId: peerUserId, contact: contact),
            selfUserId: ctx.selfUserId, selfIdentityKey: ctx.selfIdentityKey,
            peerUserId: peerUserId)
    }

    /// The contact-level shield of one contact (no call), from the keys pinned for it.
    static func shield(for contact: ContactsStore.StoredContact, pinnedKeys: [Data], context: Context) -> IdentityShield {
        if let me = context.selfUserId, me == contact.userId { return .pending }
        return IdentityShieldRules.contactShield(
            pinnedKeys: pinnedKeys,
            record: record(peerUserId: contact.userId, contact: contact),
            selfUserId: context.selfUserId, selfIdentityKey: context.selfIdentityKey,
            peerUserId: contact.userId,
            pendingChange: contact.identityChangePendingAtMs != nil)
    }

    /// The shield of every contact, from ONE enumeration of the pin store (a list must not scan the Keychain once per row).
    static func shields(for contacts: [ContactsStore.StoredContact]) -> [String: IdentityShield] {
        let context = currentContext()
        let pins = PeerIdentityPinStore().allPinnedKeysByContact()
        var out: [String: IdentityShield] = [:]
        for contact in contacts {
            out[contact.userId] = shield(for: contact, pinnedKeys: pins[contact.userId] ?? [], context: context)
        }
        return out
    }

    /// The shield of one contact by user id: `.pending` when it is not a stored contact.
    static func shield(forUserId userId: String) -> IdentityShield {
        guard let contact = ContactsStore().load().first(where: { $0.userId == userId }) else { return .pending }
        return shield(for: contact, pinnedKeys: PeerIdentityPinStore().allPinnedKeys(contactId: userId), context: currentContext())
    }
}
