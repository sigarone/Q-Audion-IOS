import XCTest
import CryptoKit
@testable import QAudionEngine

/// The contact shield over the keys the chat sessions are bound to: the rule itself, the same rule fed from real binding records, the
/// published device set and its cache, and the traffic marker.
final class ContactShieldBindingTests: XCTestCase {

    private typealias Row = ContactShieldRow

    private let pa = String(repeating: "aa", count: 16)
    private let pb = String(repeating: "bb", count: 16)
    private let pl = String(repeating: "cc", count: 16)
    private let px = String(repeating: "dd", count: 16)

    private func shield(
        _ rows: [Row], bound: Set<String>?, published: PublishedDevices? = nil,
        verifiedAtMs: Int64? = 200, contactChange: Bool = false
    ) -> IdentityShield {
        IdentityShieldRules.contactShield(
            rows: rows, contactChangePending: contactChange, verifiedAtMs: verifiedAtMs, published: published, bound: bound)
    }

    private var published: PublishedDevices { PublishedDevices(deviceIds: ["dev-a"], fingerprints: [pa]) }

    // MARK: Bound known

    func testAChatBoundToAnUnverifiedUnpublishedKeyIsToVerifyEvenWithAVerifiedDeviceAlongside() {
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "dev-b", fingerprintHex: pb, verified: false, lastTrafficAtMs: 100), // traffic only before the verification
        ]
        // Without the binding the published set alone would drop the leftover and turn the contact green: that is what the rule closes.
        XCTAssertEqual(shield(rows, bound: [], published: published), .verified)
        XCTAssertEqual(shield(rows, bound: [pb], published: published), .toVerify)
        XCTAssertEqual(shield(rows, bound: [pa, pb], published: published), .toVerify)
    }

    func testAChatBoundToTheVerifiedKeyIgnoresTheOldUnpublishedUnverifiedLegacyRow() {
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "", fingerprintHex: pl, verified: false),
        ]
        XCTAssertEqual(shield(rows, bound: [pa], published: published), .verified)
    }

    func testAKeyBoundToNoRowIsToVerifyAndAnEmptyContactStaysPending() {
        let rows = [Row(deviceId: "dev-a", fingerprintHex: pa, verified: true)]
        XCTAssertEqual(shield(rows, bound: [px], published: published), .toVerify)
        XCTAssertEqual(shield([], bound: [px]), .toVerify)
        XCTAssertEqual(shield([], bound: []), .pending)
    }

    func testABoundKeyOnARowWithAChangeMarkerIsChanged() {
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "dev-b", fingerprintHex: pb, verified: false, changePending: true),
        ]
        XCTAssertEqual(shield(rows, bound: [pb], published: published), .changed)
        // an upper-case print names the same key
        XCTAssertEqual(shield(rows, bound: [pb.uppercased()], published: published), .changed)
    }

    func testARecordedChangeOfAVerifiedContactIsStillChanged() {
        let rows = [Row(deviceId: "dev-a", fingerprintHex: pa, verified: true)]
        XCTAssertEqual(shield(rows, bound: [pa], published: published, contactChange: true), .changed)
        XCTAssertEqual(shield(rows, bound: nil, contactChange: true), .changed)
    }

    func testABoundUnverifiedKeyIsNeverIgnoredWhateverTheServerSays() {
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "dev-b", fingerprintHex: pb, verified: false),
        ]
        // the server publishes only dev-a: dev-b would be a leftover, but the chat speaks to its key
        XCTAssertEqual(shield(rows, bound: [pb], published: published), .toVerify)
        XCTAssertEqual(shield(rows, bound: [pa], published: published), .verified)
    }

    // MARK: Bound unknown is exactly the plain rule over every row

    func testAnUnknownBindingGivesTheRuleOfBeforeOverEveryRow() {
        let selfId = "11111111-1111-1111-1111-111111111111"
        let peerId = "22222222-2222-2222-2222-222222222222"
        let selfKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let keyA = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let keyB = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let keyL = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        func fp(_ k: Data) -> String {
            SasPinVerification.fingerprintHex(selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId, peerIdentityKey: k) ?? ""
        }
        let record = IdentityVerificationRecord(bindingTag: nil, verifiedFingerprintHex: fp(keyA))
        let sets: [[(String, Data)]] = [
            [], [("dev-a", keyA)], [("dev-b", keyB)], [("dev-a", keyA), ("dev-b", keyB)],
            [("", keyL), ("dev-a", keyA)], [("", keyL), ("dev-a", keyA), ("dev-b", keyB)], [("", keyA), ("dev-a", keyA)],
        ]
        for pins in sets {
            for pending in [false, true] {
                let rows = IdentityShieldRules.contactShieldRows(
                    pins: pins.map { PeerIdentityPinStore.PinnedRow(deviceId: $0.0, key: $0.1) }, record: record,
                    selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId,
                    pendingChangeFingerprints: [], traffic: [:])
                let before = IdentityShieldRules.contactShield(
                    pinnedKeys: pins.map { $0.1 }, record: record, selfUserId: selfId, selfIdentityKey: selfKey,
                    peerUserId: peerId, pendingChange: pending)
                // whatever the server publishes and whatever traffic there is: an unknown binding switches the filter off
                for set in [nil, PublishedDevices(deviceIds: ["dev-a"], fingerprints: [fp(keyA)])] {
                    XCTAssertEqual(
                        IdentityShieldRules.contactShield(
                            rows: rows, contactChangePending: pending, verifiedAtMs: 1, published: set, bound: nil),
                        before, "\(pins.map { $0.0 }) pending=\(pending)")
                }
            }
        }
    }

    func testNoContactThatIsGreenTodayTurnsPurpleWhenTheBindingIsUnknown() {
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "dev-a2", fingerprintHex: pa, verified: true),
        ]
        XCTAssertEqual(shield(rows, bound: nil, published: published), .verified)
    }

    func testAnOlderRatchetGivesAnUnknownBindingAndSoThePlainRule() throws {
        let r = MessageRatchet(vault: SessionBindingStoreTests.FlakyVault())
        let peer = UUID().uuidString.lowercased()
        try r.persistInstall(epochId: MessageRatchet.v4RoutingEpoch, peerId: peer, blob: Data(repeating: 1, count: 64), peerKeyPrint: pb)
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "dev-b", fingerprintHex: pb, verified: false),
        ]
        let v3 = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in 3 })
        let v4 = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in 4 })
        XCTAssertNil(v3.boundPeerPrints(peerUserId: peer))
        XCTAssertEqual(shield(rows, bound: v3.boundPeerPrints(peerUserId: peer), published: published), .toVerify, "plain: every row counts")
        XCTAssertEqual(shield(Array(rows.prefix(1)), bound: v3.boundPeerPrints(peerUserId: peer), published: published), .verified)
        XCTAssertEqual(v4.boundPeerPrints(peerUserId: peer), [pb])
    }

    // MARK: The published set

    func testAnUnknownPublishedSetCountsEveryRow() {
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "", fingerprintHex: pl, verified: false),
        ]
        XCTAssertEqual(shield(rows, bound: [pa], published: nil), .toVerify)
        XCTAssertEqual(shield(rows, bound: [pa], published: PublishedDevices(deviceIds: [], fingerprints: [pa])), .toVerify)
        XCTAssertEqual(shield(rows, bound: [pa], published: published), .verified)
    }

    func testARowIsDroppedOnlyWhenItIsAnUnverifiedUnmarkedLeftoverWithoutTrafficSinceTheVerification() {
        let stale = Row(deviceId: "dev-old", fingerprintHex: pl, verified: false, lastTrafficAtMs: 100)
        let verified = Row(deviceId: "dev-a", fingerprintHex: pa, verified: true)
        XCTAssertEqual(shield([verified, stale], bound: [pa], published: published, verifiedAtMs: 200), .verified)
        // traffic at or after the verification keeps it
        let live = Row(deviceId: "dev-old", fingerprintHex: pl, verified: false, lastTrafficAtMs: 200)
        XCTAssertEqual(shield([verified, live], bound: [pa], published: published, verifiedAtMs: 200), .toVerify)
        // never verified: any traffic counts
        XCTAssertEqual(shield([verified, stale], bound: [pa], published: published, verifiedAtMs: nil), .toVerify)
        // a published device counts, a marker counts
        let publishedUnverified = Row(deviceId: "dev-a2", fingerprintHex: pl, verified: false)
        let p2 = PublishedDevices(deviceIds: ["dev-a", "dev-a2"], fingerprints: [pa, pl])
        XCTAssertEqual(shield([verified, publishedUnverified], bound: [pa], published: p2), .toVerify)
        let marked = Row(deviceId: "dev-old", fingerprintHex: pl, verified: false, changePending: true)
        XCTAssertNotEqual(shield([verified, marked], bound: [pa], published: published), .verified)
        // the legacy row whose key IS published counts; one without published fingerprints to compare is never dropped
        let legacyPublished = Row(deviceId: "", fingerprintHex: pl, verified: false)
        XCTAssertEqual(shield([verified, legacyPublished], bound: [pa],
                              published: PublishedDevices(deviceIds: ["dev-a"], fingerprints: [pa, pl])), .toVerify)
        XCTAssertEqual(shield([verified, legacyPublished], bound: [pa],
                              published: PublishedDevices(deviceIds: ["dev-a"], fingerprints: [])), .toVerify)
    }

    func testDroppingNeverLeavesNothing() {
        let rows = [
            Row(deviceId: "dev-x", fingerprintHex: pl, verified: false),
            Row(deviceId: "dev-y", fingerprintHex: pb, verified: false),
        ]
        XCTAssertEqual(shield(rows, bound: [], published: published), .toVerify)
    }

    // MARK: Through real binding records

    private func ratchetWithBindings() -> (MessageRatchet, SessionBindingStoreTests.FlakyVault) {
        let vault = SessionBindingStoreTests.FlakyVault()
        return (MessageRatchet(vault: vault), vault)
    }

    func testTheOwnerCaseTurnsGreenAfterTheFirstCallThatFollowsTheVerification() throws {
        let (r, _) = ratchetWithBindings()
        let reader = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in 5 })
        let peer = UUID().uuidString.lowercased()
        let control = MessageRatchet.v5ControlRoutingEpoch
        // The chat was bound to the old unpublished key; the user verified the real device in person (trust rows only).
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: Data(repeating: 1, count: 64), peerKeyPrint: pl)
        let rows = [
            Row(deviceId: "", fingerprintHex: pl, verified: false),
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
        ]
        XCTAssertEqual(shield(rows, bound: reader.boundPeerPrints(peerUserId: peer), published: published), .toVerify,
                       "the chat still speaks to the unverified key: not green")
        // One call after the verification re-keys the chat to the verified key; the new session decrypts; the old one has not.
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: Data(repeating: 2, count: 64), peerKeyPrint: pa)
        r.noteCurrentOpened(epochId: control, peerId: peer)
        XCTAssertEqual(reader.boundPeerPrints(peerUserId: peer), [pa])
        XCTAssertEqual(shield(rows, bound: reader.boundPeerPrints(peerUserId: peer), published: published), .verified)
        // The same with a decrypt under the previous session after the current one's first decrypt: not green.
        r.notePreviousOpened(epochId: control, peerId: peer)
        XCTAssertEqual(reader.boundPeerPrints(peerUserId: peer), [pa, pl])
        XCTAssertEqual(shield(rows, bound: reader.boundPeerPrints(peerUserId: peer), published: published), .toVerify)
    }

    func testAChatBoundToAKeyAFirstContactPinnedIsToVerifyEvenAfterTheRealDeviceIsVerified() throws {
        let (r, _) = ratchetWithBindings()
        let reader = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in 4 })
        let peer = UUID().uuidString.lowercased()
        try r.persistInstall(epochId: MessageRatchet.v4RoutingEpoch, peerId: peer, blob: Data(repeating: 3, count: 64), peerKeyPrint: pb)
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "dev-b", fingerprintHex: pb, verified: false, lastTrafficAtMs: 100),
        ]
        XCTAssertEqual(shield(rows, bound: reader.boundPeerPrints(peerUserId: peer), published: published), .toVerify)
    }

    // MARK: The published set cache

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var ms: Int64 = 1_000
        var now: Int64 { lock.lock(); defer { lock.unlock() }; return ms }
        func advance(_ delta: Int64) { lock.lock(); ms += delta; lock.unlock() }
    }

    private final class FakeSource: PublishedDeviceSource, @unchecked Sendable {
        private let lock = NSLock()
        private var value: PublishedDevices?
        private var count = 0
        var delayMs: UInt64 = 0
        init(_ value: PublishedDevices?) { self.value = value }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func set(_ v: PublishedDevices?) { lock.lock(); value = v; lock.unlock() }
        func published(peerUserId: String) async -> PublishedDevices? {
            lock.lock(); count += 1; let v = value; lock.unlock()
            if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            return v
        }
    }

    func testAnExpiredPublishedSetWithAnEqualRefetchKeepsTheContactVerified() async throws {
        let clock = TestClock()
        let source = FakeSource(published)
        let cache = PublishedDeviceSetCache(source: source, nowMs: { clock.now })
        let peer = UUID().uuidString.lowercased()
        let rows = [
            Row(deviceId: "dev-a", fingerprintHex: pa, verified: true),
            Row(deviceId: "", fingerprintHex: pl, verified: false),
        ]
        let box = SessionBindingStoreTests.LineBox()
        let token = NotificationCenter.default.addObserver(
            forName: PublishedDeviceSetCache.didChangeNotification, object: nil, queue: nil) { note in
            if let p = note.userInfo?["peerId"] as? String, p == peer { box.add(p) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertNil(cache.lastKnown(peerUserId: peer))
        XCTAssertEqual(shield(rows, bound: [pa], published: cache.lastKnown(peerUserId: peer)), .toVerify, "set not fetched yet: every row counts")
        let first = await cache.get(peerUserId: peer)
        XCTAssertEqual(first, published)
        XCTAssertEqual(box.all.count, 1, "the first set is announced")
        XCTAssertEqual(shield(rows, bound: [pa], published: cache.lastKnown(peerUserId: peer)), .verified)

        // fresh: no second fetch
        _ = await cache.get(peerUserId: peer)
        XCTAssertEqual(source.calls, 1)

        // expired: the shield keeps using the last set while the refresh runs, and an equal refetch changes and announces nothing
        clock.advance(PublishedDeviceSetCache.ttlMs + 1)
        XCTAssertFalse(cache.isFresh(peerUserId: peer))
        XCTAssertEqual(shield(rows, bound: [pa], published: cache.lastKnown(peerUserId: peer)), .verified, "an expiry never flips the shield")
        _ = await cache.get(peerUserId: peer)
        XCTAssertEqual(source.calls, 2)
        XCTAssertEqual(box.all.count, 1, "an equal refetch announces nothing")
        XCTAssertEqual(shield(rows, bound: [pa], published: cache.lastKnown(peerUserId: peer)), .verified)

        // a different set is announced
        clock.advance(PublishedDeviceSetCache.ttlMs + 1)
        source.set(PublishedDevices(deviceIds: ["dev-a", "dev-l"], fingerprints: [pa, pl]))
        _ = await cache.get(peerUserId: peer)
        XCTAssertEqual(box.all.count, 2)
        XCTAssertEqual(shield(rows, bound: [pa], published: cache.lastKnown(peerUserId: peer)), .toVerify, "the leftover is published again")
    }

    func testAFailedFetchIsUnknownForAShortWhileAndASetWithoutDeviceIdsIsUnknown() async {
        let clock = TestClock()
        let source = FakeSource(nil)
        let cache = PublishedDeviceSetCache(source: source, nowMs: { clock.now }, announceChanges: false)
        let peer = UUID().uuidString.lowercased()
        let none = await cache.get(peerUserId: peer)
        XCTAssertNil(none)
        XCTAssertNil(cache.lastKnown(peerUserId: peer))
        XCTAssertTrue(cache.isFresh(peerUserId: peer), "a failure is remembered for a short while")
        _ = await cache.get(peerUserId: peer)
        XCTAssertEqual(source.calls, 1, "the network is not hammered")
        clock.advance(PublishedDeviceSetCache.failureTtlMs + 1)
        XCTAssertFalse(cache.isFresh(peerUserId: peer))
        source.set(PublishedDevices(deviceIds: [], fingerprints: [pa]))
        let empty = await cache.get(peerUserId: peer)
        XCTAssertNil(empty, "no device ids is unknown")
        XCTAssertEqual(source.calls, 2)
    }

    func testTwoCallersWaitForOneFetchAndForceSkipsTheCache() async {
        let clock = TestClock()
        let source = FakeSource(published)
        source.delayMs = 40
        let cache = PublishedDeviceSetCache(source: source, nowMs: { clock.now }, announceChanges: false)
        let peer = UUID().uuidString.lowercased()
        async let one = cache.get(peerUserId: peer)
        async let two = cache.get(peerUserId: peer)
        let (a, b) = await (one, two)
        XCTAssertEqual(a, published)
        XCTAssertEqual(b, published)
        XCTAssertEqual(source.calls, 1)
        _ = await cache.get(peerUserId: peer, force: true)
        XCTAssertEqual(source.calls, 2)
    }

    // MARK: The traffic marker

    private func contact(verifiedAtMs: Int64?) -> ContactsStore.StoredContact {
        ContactsStore.StoredContact(
            userId: "22222222-2222-2222-2222-222222222222", displayName: "p", phoneHash: "", avatarUrl: nil, lastSeen: nil,
            isVerified: verifiedAtMs != nil, verifiedFingerprintHex: verifiedAtMs == nil ? nil : pa, verifiedAtMs: verifiedAtMs)
    }

    func testTrafficIsNeverBehindWhatIsKnown() {
        let c = contact(verifiedAtMs: 5_000)
        let key = ContactsStore.StoredContact.trafficKey(deviceId: "DEV-1")
        // a clock stepped back: the traffic is placed after the verification it follows
        let early = c.withTraffic(deviceId: "dev-1", fingerprintHex: nil, nowMs: 1_000)
        XCTAssertEqual(early.lastTrafficAtMs?[key], 5_001)
        // and never before traffic already recorded
        let later = early.withTraffic(deviceId: "dev-1", fingerprintHex: nil, nowMs: 9_000)
        XCTAssertEqual(later.lastTrafficAtMs?[key], 9_000)
        let steppedBack = later.withTraffic(deviceId: "dev-1", fingerprintHex: nil, nowMs: 2_000)
        XCTAssertEqual(steppedBack.lastTrafficAtMs?[key], 9_000)
        // nothing to record without a device or a key
        XCTAssertEqual(c.withTraffic(deviceId: nil, fingerprintHex: "", nowMs: 1), c)
        // the key and the device are recorded together
        let both = c.withTraffic(deviceId: "d", fingerprintHex: pl.uppercased(), nowMs: 6_000)
        XCTAssertEqual(both.lastTrafficAtMs?[ContactsStore.StoredContact.trafficKey(fingerprintHex: pl)], 6_000)
    }

    func testTheRowsCarryTheTrafficOfTheirDeviceOrKey() {
        let selfId = "11111111-1111-1111-1111-111111111111"
        let peerId = "22222222-2222-2222-2222-222222222222"
        let selfKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let k1 = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let k2 = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fp2 = SasPinVerification.fingerprintHex(selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId, peerIdentityKey: k2) ?? ""
        let traffic: [String: Int64] = [
            ContactsStore.StoredContact.trafficKey(deviceId: "dev-1"): 300,
            ContactsStore.StoredContact.trafficKey(fingerprintHex: fp2): 400,
        ]
        let rows = IdentityShieldRules.contactShieldRows(
            pins: [PeerIdentityPinStore.PinnedRow(deviceId: "dev-1", key: k1), PeerIdentityPinStore.PinnedRow(deviceId: "", key: k2)],
            record: .empty, selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId,
            pendingChangeFingerprints: [fp2.uppercased()], traffic: traffic)
        XCTAssertEqual(rows[0].lastTrafficAtMs, 300)
        XCTAssertEqual(rows[1].lastTrafficAtMs, 400)
        XCTAssertFalse(rows[0].changePending)
        XCTAssertTrue(rows[1].changePending)
    }

    func testNoteTrafficThroughTheStoreWritesOnlyForAStoredContact() throws {
        // A unit-test bundle has no usable keychain: the store gets a fixed key, like the contact store tests.
        ContactsStore.testKeyOverride = Data(repeating: 0x2b, count: 32)
        defer { ContactsStore.testKeyOverride = nil }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ContactShieldBindingTests-" + UUID().uuidString))
        let store = ContactsStore(defaults: defaults)
        let c = contact(verifiedAtMs: 10)
        store.noteTraffic(peerUserId: c.userId, deviceId: "dev-1", fingerprintHex: nil, nowMs: 50)
        XCTAssertTrue(store.load().isEmpty, "a peer that is not a stored contact has no row to mark")
        store.upsert(c)
        store.noteTraffic(peerUserId: c.userId, deviceId: "dev-1", fingerprintHex: pa, nowMs: 50)
        let stored = store.load().first
        XCTAssertEqual(stored?.lastTrafficAtMs?[ContactsStore.StoredContact.trafficKey(deviceId: "dev-1")], 50)
        XCTAssertEqual(stored?.lastTrafficAtMs?[ContactsStore.StoredContact.trafficKey(fingerprintHex: pa)], 50)
        // the field survives the copies that thread every other field through
        XCTAssertEqual(stored?.withDisplayName("q").lastTrafficAtMs, stored?.lastTrafficAtMs)
    }
}
