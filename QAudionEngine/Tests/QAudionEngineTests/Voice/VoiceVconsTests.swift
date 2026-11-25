import XCTest
import Foundation
import CryptoKit
@testable import QAudionEngine

/// Stage 10 of the reference vectors: the announcement of the contact-voice check, sealed and opened. Every seal case gives the stored
/// key, plaintext, sealed bytes and both strings; every string opens to the stored fields; every open case is accepted or dropped as
/// stored. Then the receiver rules that the vectors do not hold: the previous key, another key, another call.
final class VoiceVconsKatTests: XCTestCase {
    private func hex(_ s: String) -> Data { Data(VoiceStateKat.hex(s)) }

    private func fields(_ o: KatJSON) -> VoiceVconsCodec.Fields {
        VoiceVconsCodec.Fields(
            seq: UInt32(o["seq"].int), allow: o["allow"].flag, withdraw: o["withdraw"].flag, learning: o["learning"].flag,
            verifying: o["verifying"].flag, routeClass: o["route_class"].int, platform: o["platform"].int, unixMs: o["unix_ms"].int64)
    }

    func testEverySealCaseGivesTheStoredPlaintextKeyAndStrings() throws {
        let s10 = try VoiceKat.json("stage10_vcons/stage10.json")
        let cases = s10["seal_cases"].array
        XCTAssertEqual(cases.count, 26)
        for c in cases {
            let name = c["name"].string
            let want = c["expected"]
            let key = hex(c["session_key"].string)
            let callId = c["call_id"].string
            let f = fields(c["fields"])
            XCTAssertEqual(Data(VoiceVconsCodec.plaintext(f)), hex(want["plaintext"].string), "\(name): plaintext")
            let derived = VoiceVconsCodec.deriveKey(sessionKey: key, callId: callId).withUnsafeBytes { Data($0) }
            XCTAssertEqual(derived, hex(want["key"].string), "\(name): key")
            let sealed = VoiceVconsCodec.seal(sessionKey: key, callId: callId, fields: f, nonce: hex(c["nonce"].string))
            XCTAssertEqual(sealed, want["string"].string, "\(name): padded string")
            XCTAssertEqual(sealed?.count, 60, name)
            for string in [want["string"].string, want["string_unpadded"].string] {
                guard case .ok(let opened) = VoiceVconsCodec.open(sessionKey: key, callId: callId, string: string) else {
                    return XCTFail("\(name): does not open (\(string.count))")
                }
                XCTAssertEqual(opened, f, name)
            }
        }
    }

    func testEveryOpenCaseIsAcceptedOrDroppedAsStored() throws {
        let s10 = try VoiceKat.json("stage10_vcons/stage10.json")
        let cases = s10["open_cases"].array
        XCTAssertGreaterThanOrEqual(cases.count, 50)
        for c in cases {
            let name = c["name"].string
            let want = c["expected"]
            let result = VoiceVconsCodec.open(
                sessionKey: hex(c["session_key"].string), callId: c["call_id"].string, string: c["string"].string)
            if want["accepted"].flag {
                guard case .ok(let f) = result else { return XCTFail("\(name): not accepted") }
                let wf = want["fields"]
                XCTAssertEqual(f, fields(wf), name)
                XCTAssertEqual(f.effect.rawValue, wf["effect"].string, "\(name): effect")
            } else {
                XCTAssertEqual(result, .rejected(want["reason"].string), name)
            }
        }
    }

    private let key = Data((0..<32).map { UInt8($0 + 1) })
    private let previous = Data((0..<32).map { UInt8($0 + 101) })
    private let callId = "3F2C9D1E-7A44-4C1B-9A0E-5D6F7A8B9C0D"
    private let sample = VoiceVconsCodec.Fields(
        seq: 7, allow: true, withdraw: false, learning: true, verifying: false, routeClass: 3, platform: 2, unixMs: 1_700_000_000_000)

    func testAMessageUnderThePreviousKeyOpensThroughTheFallbackAndAnotherKeyDoesNot() throws {
        let s = try XCTUnwrap(VoiceVconsCodec.seal(sessionKey: previous, callId: callId, fields: sample))
        XCTAssertEqual(VoiceVconsCodec.open(current: key, previous: nil, callId: callId, string: s), .rejected("tag"))
        XCTAssertEqual(VoiceVconsCodec.open(current: key, previous: previous, callId: callId, string: s), .ok(sample))
        let other = Data(repeating: 9, count: 32)
        XCTAssertEqual(VoiceVconsCodec.open(current: key, previous: other, callId: callId, string: s), .rejected("tag"))
        XCTAssertEqual(VoiceVconsCodec.open(current: nil, previous: nil, callId: callId, string: s), .rejected("tag"))
        let current = try XCTUnwrap(VoiceVconsCodec.seal(sessionKey: key, callId: callId, fields: sample))
        XCTAssertEqual(VoiceVconsCodec.open(current: key, previous: previous, callId: callId, string: current), .ok(sample))
    }

    func testTheCallIdIsLoweredForTheKeyAndAnotherCallDoesNotOpen() throws {
        let a = try XCTUnwrap(VoiceVconsCodec.seal(sessionKey: key, callId: callId, fields: sample))
        let b = try XCTUnwrap(VoiceVconsCodec.seal(sessionKey: key, callId: callId, fields: sample))
        XCTAssertNotEqual(a, b, "a random nonce for every message")
        XCTAssertEqual(VoiceVconsCodec.open(sessionKey: key, callId: callId.lowercased(), string: a), .ok(sample))
        XCTAssertEqual(
            VoiceVconsCodec.open(sessionKey: key, callId: "11111111-2222-3333-4444-555555555555", string: a), .rejected("tag"))
    }

    func testOnlyFiftyNineOrSixtyCharactersCanOpen() throws {
        let s = try XCTUnwrap(VoiceVconsCodec.seal(sessionKey: key, callId: callId, fields: sample))
        XCTAssertEqual(s.count, 60)
        XCTAssertEqual(VoiceVconsCodec.open(sessionKey: key, callId: callId, string: String(s.dropLast())), .ok(sample))
        for bad in [String(s.dropLast(2)), s + "A", s + "=", "", String(s.dropLast(4))] {
            guard case .rejected = VoiceVconsCodec.open(sessionKey: key, callId: callId, string: bad) else {
                return XCTFail("opened a string of \(bad.count) characters")
            }
        }
    }
}

/// The sender and receiver of one call, with the clock, the keys and the transport injected.
final class VoiceVconsExchangeTests: XCTestCase {
    private let callId = "3f2c9d1e-7a44-4c1b-9a0e-5d6f7a8b9c0d"
    private var key = Data((0..<32).map { UInt8($0 + 1) })

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var sent: [String] = []
        var peer: [VoiceVconsCodec.Fields] = []
        var dropped: [String] = []
        var local = VoiceVconsExchange.Local(flags: 0, routeClass: 0)
        var key: Data?
        func read<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    }

    private func make(_ box: Box) -> VoiceVconsExchange {
        VoiceVconsExchange(
            callId: callId, keys: { box.read { box.key } }, send: { s in box.read { box.sent.append(s) } },
            local: { box.read { box.local } }, onPeer: { f in box.read { box.peer.append(f) } },
            onDropped: { r in box.read { box.dropped.append(r) } }, nowMs: { 1_700_000_000_000 })
    }

    private func opened(_ box: Box, key: Data? = nil) -> [VoiceVconsCodec.Fields] {
        box.read { box.sent }.compactMap { wire -> VoiceVconsCodec.Fields? in
            XCTAssertTrue(wire.hasPrefix("VCONS:"))
            guard case .ok(let f) = VoiceVconsCodec.open(
                sessionKey: key ?? self.key, callId: callId, string: String(wire.dropFirst(6))) else { return nil }
            return f
        }
    }

    func testTheSeriesIsFiveMessagesThreeSecondsApartThenNothing() {
        let box = Box()
        box.key = key
        let ex = make(box)
        for _ in 0..<(12 * 5) { ex.tick() } // 15 s of 250 ms ticks
        let got = opened(box)
        XCTAssertEqual(got.count, VoiceVconsExchange.series)
        XCTAssertEqual(got.map { $0.seq }, [0, 1, 2, 3, 4])
        for f in got {
            XCTAssertTrue(f.allow)
            XCTAssertFalse(f.withdraw)
            XCTAssertEqual(f.platform, VoiceVconsCodec.platformIos)
        }
    }

    func testTheSecondMessageGoesOutThreeSecondsAfterTheFirst() {
        let box = Box()
        box.key = key
        let ex = make(box)
        ex.tick()
        XCTAssertEqual(box.read { box.sent.count }, 1)
        for _ in 0..<11 { ex.tick() }
        XCTAssertEqual(box.read { box.sent.count }, 1, "not before 3 s")
        ex.tick()
        XCTAssertEqual(box.read { box.sent.count }, 2)
    }

    func testAFlagOrRouteChangeRestartsTheSeries() {
        let box = Box()
        box.key = key
        let ex = make(box)
        for _ in 0..<(12 * 5) { ex.tick() }
        XCTAssertEqual(box.read { box.sent.count }, 5)
        box.read { box.local = VoiceVconsExchange.Local(flags: VoiceVconsCodec.flagLearning, routeClass: VoiceRouteClass.bluetooth) }
        ex.tick()
        let got = opened(box)
        XCTAssertEqual(got.count, 6, "the change goes out at once")
        XCTAssertTrue(got[5].learning)
        XCTAssertFalse(got[5].verifying)
        XCTAssertEqual(got[5].routeClass, VoiceRouteClass.bluetooth)
        XCTAssertEqual(got[5].seq, 5, "a new, increasing seq")
        for _ in 0..<(12 * 5) { ex.tick() }
        XCTAssertEqual(box.read { box.sent.count }, 10, "four more follow")
    }

    func testNothingIsSentWithoutASessionKey() {
        let box = Box()
        let ex = make(box)
        for _ in 0..<5 { ex.tick() }
        XCTAssertTrue(box.read { box.sent.isEmpty })
        box.key = key
        ex.tick()
        XCTAssertEqual(box.read { box.sent.count }, 1, "the series starts when the key exists")
    }

    private func peerMessage(seq: UInt32, allow: Bool = true, withdraw: Bool = false, route: Int = 1, key: Data? = nil) -> String {
        let f = VoiceVconsCodec.Fields(
            seq: seq, allow: allow, withdraw: withdraw, learning: false, verifying: false, routeClass: route, platform: 1, unixMs: 0)
        return VoiceVconsCodec.seal(sessionKey: key ?? self.key, callId: callId, fields: f) ?? ""
    }

    func testTheNewestSeqWinsComparedUnsigned() {
        let box = Box()
        box.key = key
        let ex = make(box)
        ex.onReceived(peerMessage(seq: 5))
        ex.onReceived(peerMessage(seq: 3)) // older, restricts nothing
        ex.onReceived(peerMessage(seq: 0xFFFF_FFF0)) // newer when compared unsigned
        ex.flush()
        XCTAssertEqual(box.read { box.peer.map { $0.seq } }, [5, 0xFFFF_FFF0])
    }

    func testAnAllowZeroOrAWithdrawHoldsEvenWhenOlder() {
        let box = Box()
        box.key = key
        let ex = make(box)
        ex.onReceived(peerMessage(seq: 9))
        ex.onReceived(peerMessage(seq: 4, allow: false))
        ex.onReceived(peerMessage(seq: 2, withdraw: true))
        ex.flush()
        XCTAssertEqual(box.read { box.peer.map { $0.seq } }, [9, 4, 2])
        XCTAssertEqual(box.read { box.peer[2].effect }, .withdraw)
    }

    func testAMessageThatDoesNotOpenIsDroppedAndTheCallGoesOn() {
        let box = Box()
        box.key = key
        let ex = make(box)
        ex.onReceived(peerMessage(seq: 1, key: Data(repeating: 7, count: 32)))
        ex.onReceived("not a message")
        ex.flush()
        XCTAssertTrue(box.read { box.peer.isEmpty })
        XCTAssertEqual(box.read { box.dropped }, ["tag", "base64"])
    }

    func testAKeyThatChangedIsStillTriedAsThePreviousOne() {
        let box = Box()
        box.key = key
        let ex = make(box)
        ex.onReceived(peerMessage(seq: 1))
        ex.flush()
        let next = Data((0..<32).map { UInt8($0 + 50) })
        box.key = next // a new session key (the exchange has seen the first one)
        ex.onReceived(peerMessage(seq: 2, key: key)) // sealed by the peer just before it changed
        ex.flush()
        ex.onReceived(peerMessage(seq: 3, key: next))
        ex.flush()
        XCTAssertEqual(box.read { box.peer.map { $0.seq } }, [1, 2, 3])
    }

    func testOnlyTheRegisteredPeerOfTheRunningCallIsAccepted() {
        let ok = VoiceVconsExchange.isFromRegisteredPeer(
            registeredPeer: "peer-1", senderId: "peer-1", activeCallId: callId, messageCallId: callId.uppercased())
        XCTAssertTrue(ok)
        XCTAssertFalse(VoiceVconsExchange.isFromRegisteredPeer(
            registeredPeer: "peer-1", senderId: "peer-2", activeCallId: callId, messageCallId: callId))
        XCTAssertFalse(VoiceVconsExchange.isFromRegisteredPeer(
            registeredPeer: nil, senderId: "peer-1", activeCallId: callId, messageCallId: callId), "no registered peer drops")
        XCTAssertFalse(VoiceVconsExchange.isFromRegisteredPeer(
            registeredPeer: "peer-1", senderId: "peer-1", activeCallId: nil, messageCallId: callId))
        XCTAssertFalse(VoiceVconsExchange.isFromRegisteredPeer(
            registeredPeer: "peer-1", senderId: "peer-1", activeCallId: callId, messageCallId: "another-call"))
    }

    func testTheWireIsThePrefixAndPaddedBase64OnTheOpaqueLane() throws {
        let box = Box()
        box.key = key
        make(box).tick()
        let wire = try XCTUnwrap(box.read { box.sent.first })
        XCTAssertEqual(wire.count, 6 + 60)
        let framed = CallPiggyBack.serializeVoiceConsent(callId: callId, payload: wire)
        XCTAssertEqual(framed, "\(callId)|\(wire)")
        guard case .voiceConsent(let id, let sealed)? = CallPiggyBack.parse(framed) else { return XCTFail("not parsed") }
        XCTAssertEqual(id, callId)
        XCTAssertEqual(sealed, String(wire.dropFirst(6)))
    }
}

/// The device of a call: the one the identity check used, with the accept sender as a cross-check.
final class VoiceDeviceBindingTests: XCTestCase {
    func testTheAnsweringDeviceIsTheDeviceOfTheCall() {
        let b = VoiceDeviceBinding()
        b.bind(callId: "C1", deviceId: "dev-a")
        XCTAssertEqual(b.device(forCall: "c1"), "dev-a")
        b.noteAccept(callId: "c1", deviceId: "dev-a")
        XCTAssertEqual(b.device(forCall: "C1"), "dev-a")
    }

    func testAnAcceptFromAnotherDeviceLeavesTheDeviceUnknown() {
        let b = VoiceDeviceBinding()
        b.bind(callId: "c1", deviceId: "dev-a")
        b.noteAccept(callId: "c1", deviceId: "dev-b")
        XCTAssertNil(b.device(forCall: "c1"))
    }

    func testWithoutAnAnswerDeviceTheDeviceIsUnknownWhateverTheAcceptSays() {
        let b = VoiceDeviceBinding()
        b.noteAccept(callId: "c1", deviceId: "dev-b")
        XCTAssertNil(b.device(forCall: "c1"))
        b.bind(callId: "c1", deviceId: "  ")
        XCTAssertNil(b.device(forCall: "c1"), "a blank id binds nothing")
    }

    func testABlankIdNeverErasesAKnownOneAndNothingCrossesCalls() {
        let b = VoiceDeviceBinding()
        b.bind(callId: "c1", deviceId: "dev-a")
        b.bind(callId: "c1", deviceId: nil)
        XCTAssertEqual(b.device(forCall: "c1"), "dev-a")
        XCTAssertNil(b.device(forCall: "c2"))
        b.clear(callId: "c1")
        XCTAssertNil(b.device(forCall: "c1"))
    }
}

/// The owner setting and its entitlement.
final class ContactVoiceOwnerSettingTests: XCTestCase {
    private final class MemoryPref: ContactVoiceOwnerPref {
        var stored: Bool?
        var writes: [Bool] = []
        func write(_ on: Bool) {
            stored = on
            writes.append(on)
        }
    }

    private func make(
        pref: MemoryPref = MemoryPref(), entitled: Bool, featureOn: Bool = true, wipe: @escaping () -> Bool = { true }
    ) -> ContactVoiceOwnerSetting {
        ContactVoiceOwnerSetting(pref: pref, entitled: { entitled }, featureOn: { featureOn }, wipeAll: wipe)
    }

    func testTheChoiceIsOnByDefaultAndAnEntitledAccountProcesses() {
        let s = make(entitled: true)
        XCTAssertTrue(s.choice)
        XCTAssertTrue(s.ownerOn)
        XCTAssertEqual(s.ui(hasRecords: false), .full)
        XCTAssertEqual(s.ui(hasRecords: true), .full)
    }

    func testWithoutTheEntitlementNothingIsProcessedAndWithNoRecordsTheUiIsHidden() {
        let s = make(entitled: false)
        XCTAssertTrue(s.choice, "the stored choice is untouched")
        XCTAssertFalse(s.ownerOn)
        XCTAssertFalse(s.available)
        XCTAssertEqual(s.ui(hasRecords: false), .hidden)
    }

    func testWithoutTheEntitlementButWithRecordsDeletionStaysReachableAndNothingIsDeletedByItself() {
        var wipes = 0
        let s = make(entitled: false, wipe: { wipes += 1; return true })
        XCTAssertEqual(s.ui(hasRecords: true), .deleteOnly)
        XCTAssertFalse(s.ownerOn)
        XCTAssertEqual(wipes, 0, "the missing entitlement deletes nothing")
    }

    func testTheFeatureFlagOffMakesTheCheckUnavailableToo() {
        let s = make(entitled: true, featureOn: false)
        XCTAssertFalse(s.ownerOn)
        XCTAssertEqual(s.ui(hasRecords: false), .hidden)
        XCTAssertEqual(s.ui(hasRecords: true), .deleteOnly)
    }

    func testTurningItOffStoresTheChoiceAndDeletesEverythingAndOnRefusedWithoutTheEntitlement() {
        let pref = MemoryPref()
        var wipes = 0
        let entitled = make(pref: pref, entitled: true, wipe: { wipes += 1; return true })
        XCTAssertTrue(entitled.setOn(false))
        XCTAssertEqual(pref.stored, false)
        XCTAssertEqual(wipes, 1)
        XCTAssertFalse(entitled.ownerOn)
        XCTAssertTrue(entitled.setOn(true))
        XCTAssertEqual(pref.stored, true)
        XCTAssertEqual(wipes, 1, "turning it on deletes nothing")

        let denied = make(pref: MemoryPref(), entitled: false)
        XCTAssertFalse(denied.setOn(true), "no toggle without the entitlement")
        XCTAssertTrue(denied.setOn(false), "deleting is always possible")
    }

    func testAFailedDeletionIsReportedAndTheChoiceStaysOff() {
        let pref = MemoryPref()
        let s = make(pref: pref, entitled: true, wipe: { false })
        XCTAssertFalse(s.setOn(false))
        XCTAssertEqual(pref.stored, false)
        XCTAssertFalse(s.ownerOn)
    }
}

/// Turning the owner setting off deletes every record, `meta.bin` and the key, and nothing afterwards recreates them.
final class VoiceOwnerOffStoreTests: XCTestCase {
    private var dir: URL!
    private var cfg: VoiceStateConstants!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        cfg = try VoiceKat.bundle().state
        dir = try VoiceStoreFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    private func names() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    private func makeStore(_ vault: VoiceMemoryVault, generation: @escaping () -> Int = { 0 }) -> VoiceTemplateStore {
        let target = dir!
        let aead = VoiceKeychainAead(dataExists: { try VoiceTemplateStore.dataExists(in: target) }, vault: vault, sleep: { _ in })
        return VoiceTemplateStore(dir: dir, aead: aead, accountId: "acct", dirSync: VoiceDirectorySyncs.none, generationProbe: generation)
    }

    func testTheToggleOffDeletesRecordsMetaAndKeyAndNothingRecreatesThem() throws {
        let vault = VoiceMemoryVault()
        var generation = 0
        let store = makeStore(vault, generation: { generation })
        try store.save("a", VoiceStoreFixtures.record(cfg))
        try store.save("b", VoiceStoreFixtures.record(cfg))
        XCTAssertTrue(names().contains("meta.bin"))
        XCTAssertNotNil(vault.current)
        let adds = vault.addCount

        let setting = ContactVoiceOwnerSetting(
            pref: UserDefaultsContactVoiceOwnerPref(defaults: UserDefaults(suiteName: "voice-owner-off-\(UUID().uuidString)") ?? .standard),
            entitled: { true }, featureOn: { true },
            wipeAll: {
                generation += 1
                return (try? store.wipeAll()) != nil
            })
        XCTAssertTrue(setting.setOn(false))
        XCTAssertFalse(setting.choice)
        XCTAssertEqual(names().filter { $0.hasSuffix(".qvt") }.count, 0)
        XCTAssertFalse(names().contains("meta.bin"))
        XCTAssertNil(vault.current, "the key is gone")

        // a contact delete or block, a forget, a sweep, a contact sync and a read: nothing is created
        XCTAssertFalse(try store.delete("a"))
        XCTAssertNil(try store.sweep("a", nowS: 1_790_000_000, cfg))
        XCTAssertEqual(try store.deleteOrphans(knownContactIds: ["x"], directorySynced: true), 0)
        XCTAssertEqual(try store.summaries(contactIds: ["a", "b"], cfg: cfg), [:])
        XCTAssertFalse(names().contains("meta.bin"))
        XCTAssertNil(vault.current)
        XCTAssertEqual(vault.addCount, adds, "no new key was made")
    }

    func testAStoreOperationThatCarriesAStaleGenerationCreatesNothing() throws {
        let vault = VoiceMemoryVault()
        var generation = 0
        let store = makeStore(vault, generation: { generation })
        generation = 1 // a wipe came first
        XCTAssertThrowsError(try store.delete("a", generation: 0)) { XCTAssertTrue($0 is VoiceStaleCall) }
        XCTAssertThrowsError(try store.sweep("a", nowS: 0, cfg, generation: 0)) { XCTAssertTrue($0 is VoiceStaleCall) }
        XCTAssertThrowsError(try store.deleteOrphans(knownContactIds: ["x"], directorySynced: true, generation: 0)) {
            XCTAssertTrue($0 is VoiceStaleCall)
        }
        XCTAssertThrowsError(try store.summaries(contactIds: ["a"], cfg: cfg, generation: 0)) { XCTAssertTrue($0 is VoiceStaleCall) }
        XCTAssertFalse(names().contains("meta.bin"))
        XCTAssertNil(vault.current)
    }

    func testADeleteWithNoMetaDoesNotCreateOneAndAStrayRecordIsRemoved() throws {
        let vault = VoiceMemoryVault()
        let store = makeStore(vault)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("0123456789abcdef0123456789abcdef.qvt"))
        XCTAssertTrue(try store.delete("a"))
        XCTAssertFalse(names().contains("meta.bin"))
        XCTAssertEqual(vault.addCount, 0)
        XCTAssertNil(vault.current)
    }

    func testSummariesReadTheRecordWithItsDateAndProgress() throws {
        let vault = VoiceMemoryVault()
        let store = makeStore(vault)
        let rec = VoiceStoreFixtures.record(cfg)
        rec.enrolledS = 1_791_806_400
        try store.save("a", rec)
        let out = try store.summaries(contactIds: ["a", "none"], cfg: cfg)
        XCTAssertEqual(Set(out.keys), ["a"])
        XCTAssertEqual(out["a"]?.kind, .learned)
        XCTAssertEqual(out["a"]?.enrolledS, 1_791_806_400)
        XCTAssertLessThanOrEqual(out["a"]?.speechS ?? 0, out["a"]?.targetS ?? 0)
        XCTAssertEqual(out["a"]?.sessions, 1)
    }

    func testEveryStateOfARecordHasItsRowState() {
        let expected: [(Int, ContactVoiceSummary.Kind)] = [
            (TemplateState.learning, .learning), (TemplateState.provisional, .partlyLearned),
            (TemplateState.enrolled, .learned), (TemplateState.needsRefresh, .mayHaveChanged),
        ]
        for (state, kind) in expected {
            let summary = ContactVoiceSummary.of(VoiceStoreFixtures.record(cfg, state: state), cfg)
            XCTAssertEqual(summary.kind, kind)
            XCTAssertEqual(summary.canRelearn, kind == .mayHaveChanged)
        }
    }
}
