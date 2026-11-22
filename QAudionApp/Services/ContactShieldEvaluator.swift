import Foundation
import QAudionEngine

/// Reads the stores that hold the key-bound verification record of a contact and hands them to the pure rules of
/// `IdentityShieldRules` (QAudionEngine, where the CI job that runs on every push compiles their tests). Nothing here decides
/// anything: it gathers the pinned keys, the stored in-call confirmation and the stored safety-number verification, the keys the
/// chat sessions are bound to, what the server publishes for the contact, and the identity of this account.
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

    /// The contact-level shield of one contact (no call), from the keys pinned for it, the keys its chat sessions are bound to and
    /// what the server publishes for it (`IdentityShieldRules.contactShield(rows:...)`). A binding that is unknown is the plain rule
    /// over every row.
    static func shield(for contact: ContactsStore.StoredContact, pins: [PeerIdentityPinStore.PinnedRow], context: Context) -> IdentityShield {
        if let me = context.selfUserId, me == contact.userId { return .pending }
        let rows = IdentityShieldRules.contactShieldRows(
            pins: pins,
            record: record(peerUserId: contact.userId, contact: contact),
            selfUserId: context.selfUserId, selfIdentityKey: context.selfIdentityKey,
            peerUserId: contact.userId,
            pendingChangeFingerprints: contact.identityChangePendingFingerprintsHex ?? [],
            traffic: contact.lastTrafficAtMs ?? [:])
        // Reads the Keychain on a first answer for the peer, then is cached until the peer's bindings change.
        let bound = PeerSessionBindings.shared.boundPeerPrints(peerUserId: contact.userId)
        let published = ContactShieldPublished.lastKnown(peerUserId: contact.userId)
        if bound != nil, rows.contains(where: { !$0.verified && !$0.changePending }) {
            ContactShieldPublished.refreshIfStale(peerUserId: contact.userId)
        }
        return IdentityShieldRules.contactShield(
            rows: rows,
            contactChangePending: contact.identityChangePendingAtMs != nil,
            verifiedAtMs: contact.verifiedAtMs,
            published: published,
            bound: bound)
    }

    /// The shield of every contact, from ONE enumeration of the pin store (a list must not scan the Keychain once per row).
    static func shields(for contacts: [ContactsStore.StoredContact]) -> [String: IdentityShield] {
        let context = currentContext()
        let pins = PeerIdentityPinStore().allPinnedRowsByContact()
        var out: [String: IdentityShield] = [:]
        for contact in contacts {
            out[contact.userId] = shield(for: contact, pins: pins[contact.userId] ?? [], context: context)
        }
        return out
    }

    /// The shield of just the given contacts (one pin read each): the refresh of a peer whose bindings or published set changed.
    static func shields(forFew contacts: [ContactsStore.StoredContact]) -> [String: IdentityShield] {
        let context = currentContext()
        let store = PeerIdentityPinStore()
        var out: [String: IdentityShield] = [:]
        for contact in contacts {
            out[contact.userId] = shield(for: contact, pins: store.allPinnedRows(contactId: contact.userId), context: context)
        }
        return out
    }

    /// The shield of one contact by user id: `.pending` when it is not a stored contact.
    static func shield(forUserId userId: String) -> IdentityShield {
        guard let contact = ContactsStore().load().first(where: { $0.userId == userId }) else { return .pending }
        return shield(for: contact, pins: PeerIdentityPinStore().allPinnedRows(contactId: userId), context: currentContext())
    }

    /// The safety-number fingerprint of `key` as the trust rows record it (what the chat sessions are bound to) for the peer
    /// `peerUserId`; nil when this account's identity is unavailable.
    static func peerKeyPrint(peerUserId: String, key: Data) -> String? {
        let context = currentContext()
        return PeerKeyPrint.of(selfUserId: context.selfUserId, selfIdentityKey: context.selfIdentityKey, peerUserId: peerUserId, peerKey: key)
    }

    /// Records ACCEPTED traffic with a device or key of a stored contact (see `ContactsStore.noteTraffic`). The key reads run off the
    /// caller's thread; the one short read-modify-write of the contact store is done on the main queue, where every other write of the
    /// store is made and whose observers expect the change notification.
    static func noteTraffic(peerUserId: String, deviceId: String?, key: Data?) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        DispatchQueue.global(qos: .utility).async {
            let fingerprint: String? = key.flatMap { peerKeyPrint(peerUserId: peerUserId, key: $0) }
            DispatchQueue.main.async {
                ContactsStore().noteTraffic(peerUserId: peerUserId, deviceId: deviceId, fingerprintHex: fingerprint, nowMs: nowMs)
            }
        }
    }
}

/// The server's published device set of the contacts, for the contact shield: one shared cache that outlives the signed-in session's
/// provider. A provider that is rebuilt or gone (nil) only means there is nobody to ask for now: the last known sets stay, and no fetch
/// is started, so a rebuild never turns "known" into "unknown". Until a first set is fetched, and whenever a fetch fails, the set is
/// unknown and every row of a contact counts.
enum ContactShieldPublished {
    private static let source = SwappableSource()
    private static let cache = PublishedDeviceSetCache(source: source)

    /// Called whenever the signed-in session's client changes. nil stops refreshing; nothing is forgotten.
    static func configure(kmsClient: BCryptoKmsClient?) {
        source.set(kmsClient)
    }

    /// The account left (logout, wipe): what was learned about its contacts goes.
    static func forgetAccount() {
        source.set(nil)
        cache.removeAll()
    }

    /// The last set known for the peer, fresh or not: an expiry never flips the shield.
    static func lastKnown(peerUserId: String) -> PublishedDevices? {
        cache.lastKnown(peerUserId: peerUserId)
    }

    /// Starts a fetch when the entry is missing or expired and a client exists. Fire and forget; the cache announces a change.
    static func refreshIfStale(peerUserId: String) {
        guard source.hasClient, !cache.isFresh(peerUserId: peerUserId) else { return }
        Task.detached(priority: .utility) { await cache.get(peerUserId: peerUserId) }
    }

    /// Asks through whichever client is current at the time of the fetch.
    private final class SwappableSource: PublishedDeviceSource, @unchecked Sendable {
        private let lock = NSLock()
        private var client: BCryptoKmsClient?

        func set(_ new: BCryptoKmsClient?) {
            lock.lock(); client = new; lock.unlock()
        }

        var hasClient: Bool {
            lock.lock(); defer { lock.unlock() }
            return client != nil
        }

        func published(peerUserId: String) async -> PublishedDevices? {
            let current = lock.withLock { client }
            guard let current else { return nil }
            return await KmsPublishedDeviceSource(client: current, selfContext: ContactShieldPublished.selfContext)
                .published(peerUserId: peerUserId)
        }
    }

    @Sendable private static func selfContext() -> (userId: String, identityKey: Data)? {
        let context = ContactShieldEvaluator.currentContext()
        guard let me = context.selfUserId, let key = context.selfIdentityKey else { return nil }
        return (me, key)
    }
}
