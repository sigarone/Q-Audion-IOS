import XCTest
@testable import QAudionEngine

// MARK: - Fake environment

final class FakeE2eeTimer: GroupE2eeTimer {
    let dueMs: Int64
    var block: (() -> Void)?
    init(dueMs: Int64, block: @escaping () -> Void) {
        self.dueMs = dueMs
        self.block = block
    }
    func cancel() { block = nil }
}

final class FakeE2eeEnvironment: GroupE2eeEnvironment {
    struct Install: Equatable {
        let key: Data
        let index: Int32
        let participantId: String
    }

    private var counter: UInt8 = 0
    var now: Int64 = 1_000
    var installs: [Install] = []
    var sendIndexes: [Int32] = []
    var keyFrames = 0
    var sent: [(user: String, json: String)] = []
    var sendResults: [Bool] = []          // consumed per send; default true
    var events: [GroupTelemetryEvent] = []
    private var timers: [FakeE2eeTimer] = []

    func randomKey() -> Data {
        counter += 1
        return Data(repeating: counter, count: 32)
    }

    func installKey(_ key: Data, index: Int32, participantId: String) {
        installs.append(Install(key: key, index: index, participantId: participantId))
    }

    func setSendKeyIndex(_ index: Int32) { sendIndexes.append(index) }
    func requestKeyFrame() { keyFrames += 1 }

    func sendControl(to userId: String, envelopeJson: String, completion: @escaping (Bool) -> Void) {
        sent.append((user: userId, json: envelopeJson))
        completion(sendResults.isEmpty ? true : sendResults.removeFirst())
    }

    func nowMs() -> Int64 { now }

    func schedule(afterMs: Int64, _ block: @escaping () -> Void) -> GroupE2eeTimer {
        let timer = FakeE2eeTimer(dueMs: now + afterMs, block: block)
        timers.append(timer)
        return timer
    }

    func emit(_ event: GroupTelemetryEvent) { events.append(event) }

    /// Moves the clock and fires every due, not cancelled timer in due order.
    func advance(_ ms: Int64) {
        now += ms
        while let next = timers.filter({ $0.block != nil && $0.dueMs <= now }).min(by: { $0.dueMs < $1.dueMs }) {
            let block = next.block
            next.block = nil
            block?()
        }
    }

    func parsedSent() -> [(user: String, envelope: GroupKeyEnvelope)] {
        sent.compactMap { item in
            if case .envelope(let envelope) = GroupKeyEnvelope.parse(json: item.json) { return (item.user, envelope) }
            return nil
        }
    }

    func e2eeEvents() -> [String] {
        events.filter { $0.kind == GroupTelemetry.Kind.e2ee }.compactMap { $0.attrs["event"] as? String }
    }
}

// MARK: - Envelope codec

final class GroupKeyEnvelopeTests: XCTestCase {

    func testKeyIndexIsTheEpochModuloSixteen() {
        XCTAssertEqual(GroupE2ee.keyIndex(forEpoch: 1), 1)
        XCTAssertEqual(GroupE2ee.keyIndex(forEpoch: 15), 15)
        XCTAssertEqual(GroupE2ee.keyIndex(forEpoch: 16), 0)
        XCTAssertEqual(GroupE2ee.keyIndex(forEpoch: 17), 1)
        XCTAssertEqual((1...17).map { GroupE2ee.keyIndex(forEpoch: UInt32($0)) },
                       [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1])
    }

    func testRingWindowIsSixteenEpochsAndOverflowSafe() {
        XCTAssertTrue(GroupE2ee.withinRing(10, newest: 25))
        XCTAssertFalse(GroupE2ee.withinRing(9, newest: 25))
        XCTAssertTrue(GroupE2ee.withinRing(30, newest: 25), "newer than the newest is never out of the ring")
        XCTAssertTrue(GroupE2ee.withinRing(UInt32.max, newest: UInt32.max))
        XCTAssertFalse(GroupE2ee.withinRing(0, newest: UInt32.max))
    }

    func testRandomKeysAre32BytesAndDifferent() {
        let a = GroupE2ee.randomKey()
        let b = GroupE2ee.randomKey()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testMediaKeyRoundTrip() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let original = GroupKeyEnvelope.mediaKey(callId: "call-1", epoch: 19, index: 3, key: key)
        let json = try XCTUnwrap(original.encode())
        XCTAssertEqual(GroupKeyEnvelope.parse(json: json), .envelope(original))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["qa_grp"] as? Int, 2)
        XCTAssertEqual(object["t"] as? String, "media_key")
        XCTAssertEqual(object["g"] as? String, "call-1")
        XCTAssertEqual(object["e"] as? Int, 19)
        XCTAssertEqual(object["k"] as? Int, 3)
        XCTAssertEqual(object["key"] as? String, key.base64EncodedString())
    }

    func testNackAndAckRoundTrip() throws {
        for original in [GroupKeyEnvelope.nack(callId: "c", epoch: 4), GroupKeyEnvelope.ack(callId: "c", epoch: 4)] {
            let json = try XCTUnwrap(original.encode())
            XCTAssertEqual(GroupKeyEnvelope.parse(json: json), .envelope(original))
            XCTAssertFalse(json.contains("\"key\""), "no key material on nack / ack")
        }
    }

    func testTypeNames() throws {
        XCTAssertTrue(try XCTUnwrap(GroupKeyEnvelope.nack(callId: "c", epoch: 1).encode()).contains("media_key_nack"))
        XCTAssertTrue(try XCTUnwrap(GroupKeyEnvelope.ack(callId: "c", epoch: 1).encode()).contains("media_key_ack"))
    }

    func testV1EnvelopesAreNotV2() {
        let v1 = #"{"qa_grp":1,"t":"sender_key_init","g":"00","e":1,"seed":"AAAA","idx":0}"#
        XCTAssertEqual(GroupKeyEnvelope.parse(json: v1), .notV2)
        XCTAssertEqual(GroupKeyEnvelope.parse(json: #"{"hello":"world"}"#), .notV2)
    }

    func testMalformedEnvelopes() {
        func malformed(_ json: String) -> Bool {
            if case .malformed = GroupKeyEnvelope.parse(json: json) { return true }
            return false
        }
        let goodKey = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertTrue(malformed("not json"))
        XCTAssertTrue(malformed(#"{"qa_grp":2,"g":"c","e":1}"#), "no type")
        XCTAssertTrue(malformed(#"{"qa_grp":2,"t":"media_key","e":1,"k":1,"key":"\#(goodKey)"}"#), "no call id")
        XCTAssertTrue(malformed(#"{"qa_grp":2,"t":"media_key","g":"c","k":1,"key":"\#(goodKey)"}"#), "no epoch")
        XCTAssertTrue(malformed(#"{"qa_grp":2,"t":"media_key","g":"c","e":17,"k":2,"key":"\#(goodKey)"}"#), "index must be epoch mod 16")
        XCTAssertTrue(malformed(#"{"qa_grp":2,"t":"media_key","g":"c","e":1,"k":1,"key":"AAAA"}"#), "key must be 32 bytes")
        XCTAssertTrue(malformed(#"{"qa_grp":2,"t":"media_key","g":"c","e":1,"k":1,"key":"***"}"#))
        XCTAssertTrue(malformed(#"{"qa_grp":2,"t":"media_key","g":"c","e":-1,"k":15,"key":"\#(goodKey)"}"#))
        XCTAssertTrue(malformed(#"{"qa_grp":2,"t":"surprise","g":"c","e":1}"#))
    }
}

// MARK: - Coordinator

final class GroupE2eeCoordinatorTests: XCTestCase {

    private let selfUser = "u-self"
    private let userB = "u-b"
    private let userC = "u-c"
    private let call = "call-1"

    private var pseudonyms: [String: String] {
        [selfUser: GroupCallFixtures.pseudoA, userB: GroupCallFixtures.pseudoB, userC: GroupCallFixtures.pseudoC]
    }

    private func make(config: GroupE2eeCoordinator.Config = GroupE2eeCoordinator.Config()) -> (GroupE2eeCoordinator, FakeE2eeEnvironment) {
        let env = FakeE2eeEnvironment()
        return (GroupE2eeCoordinator(callId: call, selfUserId: selfUser, environment: env, config: config), env)
    }

    private func mediaKey(epoch: UInt32, fill: UInt8) -> GroupKeyEnvelope {
        .mediaKey(callId: call, epoch: epoch, index: GroupE2ee.keyIndex(forEpoch: epoch), key: Data(repeating: fill, count: 32))
    }

    // MARK: own key

    func testAnEpochBumpGeneratesAFreshKeyInstallsItAndSendsItToEveryOtherMember() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        XCTAssertEqual(env.installs, [.init(key: Data(repeating: 1, count: 32), index: 5, participantId: GroupCallFixtures.pseudoA)])
        let sent = env.parsedSent()
        XCTAssertEqual(Set(sent.map { $0.user }), [userB, userC])
        for item in sent {
            XCTAssertEqual(item.envelope, .mediaKey(callId: call, epoch: 5, index: 5, key: Data(repeating: 1, count: 32)))
        }
        XCTAssertTrue(env.sendIndexes.isEmpty, "the send index only moves after the acks or the wait")
        XCTAssertEqual(env.e2eeEvents(), ["key_sent"])
    }

    func testTheSendIndexSwitchesWhenEveryMemberAckedThenAKeyFrameIsForced() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        coordinator.onEnvelope(.ack(callId: call, epoch: 5), from: userB)
        XCTAssertTrue(env.sendIndexes.isEmpty)
        coordinator.onEnvelope(.ack(callId: call, epoch: 5), from: userC)
        XCTAssertEqual(env.sendIndexes, [5])
        XCTAssertEqual(env.keyFrames, 1)
        XCTAssertEqual(coordinator.sendingEpoch, 5)
    }

    func testTheSendIndexSwitchesAfter1500msWithoutAcks() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.advance(1_499)
        XCTAssertTrue(env.sendIndexes.isEmpty)
        env.advance(1)
        XCTAssertEqual(env.sendIndexes, [5])
        XCTAssertEqual(env.keyFrames, 1)
    }

    func testTheSwitchHappensOnlyOnce() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(.ack(callId: call, epoch: 5), from: userB)
        env.advance(5_000)
        coordinator.onEnvelope(.ack(callId: call, epoch: 5), from: userB)
        XCTAssertEqual(env.sendIndexes, [5])
        XCTAssertEqual(env.keyFrames, 1)
    }

    func testAloneInTheCallSwitchesAtOnce() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 1, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        XCTAssertEqual(env.sendIndexes, [1])
        XCTAssertTrue(env.sent.isEmpty)
    }

    func testEveryEpochGetsANewKeyAndTheIndexWraps() {
        let (coordinator, env) = make()
        var seen = Set<Data>()
        for epoch in UInt32(1)...17 {
            coordinator.onRoster(epoch: epoch, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        }
        for install in env.installs { seen.insert(install.key) }
        XCTAssertEqual(seen.count, 17, "no key is ever reused")
        XCTAssertEqual(env.installs.map { $0.index }, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1])
        XCTAssertEqual(env.sendIndexes, env.installs.map { $0.index })
    }

    func testANewEpochCancelsThePendingSwitchOfTheOldOne() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.advance(1_000)
        coordinator.onRoster(epoch: 6, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.advance(1_000)                                    // the epoch-5 timer would have fired here
        XCTAssertTrue(env.sendIndexes.isEmpty)
        env.advance(500)
        XCTAssertEqual(env.sendIndexes, [6])
    }

    func testAStaleRosterIsIgnoredAndASameEpochRosterOnlyUpdatesPseudonyms() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        // Same epoch, now with the media block: the key is generated then.
        XCTAssertTrue(env.installs.count == 1 && env.installs[0].participantId == GroupCallFixtures.pseudoA)
        coordinator.onRoster(epoch: 4, members: [selfUser], pseudonyms: pseudonyms)
        XCTAssertEqual(coordinator.epoch, 5)
        XCTAssertEqual(env.installs.count, 1)
        // The stale roster (without userB) changed nothing: userB is still a member
        // of the epoch-5 roster and gets its key re-sent on a nack.
        env.sent.removeAll()
        coordinator.onEnvelope(.nack(callId: call, epoch: 5), from: userB)
        XCTAssertEqual(env.parsedSent().map { $0.user }, [userB])
    }

    func testAStaleOrFutureAckDoesNotCompleteTheSwitch() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(.ack(callId: call, epoch: 4), from: userB)
        coordinator.onEnvelope(.ack(callId: call, epoch: 6), from: userB)
        XCTAssertTrue(env.sendIndexes.isEmpty, "only an ack of the CURRENT epoch counts")
        coordinator.onEnvelope(.ack(callId: call, epoch: 5), from: userB)
        XCTAssertEqual(env.sendIndexes, [5])
    }

    func testALeaverGetsNoKeyOfTheNextEpochAndAJoinerOnlyKeysOfItsOwnEpochOnward() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        // userC leaves: the new epoch's key goes to userB only, and a nack of the
        // leaver is not answered.
        env.sent.removeAll()
        coordinator.onRoster(epoch: 6, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertEqual(env.parsedSent().map { $0.user }, [userB])
        env.now += 5_000
        coordinator.onEnvelope(.nack(callId: call, epoch: 6), from: userC)
        coordinator.onEnvelope(.nack(callId: call, epoch: 5), from: userC)
        XCTAssertEqual(env.parsedSent().map { $0.user }, [userB], "nothing was sent to the leaver")
        // userC joins again at epoch 7: it gets epoch 7 and nothing older, even if it asks.
        env.sent.removeAll()
        coordinator.onRoster(epoch: 7, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        env.now += 5_000
        coordinator.onEnvelope(.nack(callId: call, epoch: 5), from: userC)
        coordinator.onEnvelope(.nack(callId: call, epoch: 6), from: userC)
        let toC = env.parsedSent().filter { $0.user == userC }.map { $0.envelope }
        XCTAssertEqual(toC.count, 1)
        guard case .mediaKey(_, let epoch, _, _)? = toC.first else { return XCTFail("expected a media key") }
        XCTAssertEqual(epoch, 7)
    }

    func testTheKeyWaitsForTheMediaBlockOfTheUpdate() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 2, members: [selfUser, userB], pseudonyms: [:])
        XCTAssertTrue(env.installs.isEmpty, "no pseudonym yet, no key yet")
        coordinator.onRoster(epoch: 2, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertEqual(env.installs.count, 1)
        XCTAssertEqual(env.installs[0].index, 2)
        XCTAssertEqual(env.parsedSent().count, 1)
    }

    func testAFailedSendIsRetriedWithBackoffAndStopsWhenTheEpochMoves() {
        let (coordinator, env) = make()
        env.sendResults = [false, false, false, false]       // every attempt fails
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertEqual(env.sent.count, 1)
        env.advance(1_000)
        XCTAssertEqual(env.sent.count, 2)
        env.advance(2_000)
        XCTAssertEqual(env.sent.count, 3)
        env.advance(4_000)
        XCTAssertEqual(env.sent.count, 4)
        env.advance(60_000)
        XCTAssertEqual(env.sent.count, 4, "bounded: three retries")
    }

    func testARetryDoesNotFireForAMemberWhoLeftOrAnOldEpoch() {
        let (coordinator, env) = make()
        env.sendResults = [false]
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onRoster(epoch: 4, members: [selfUser], pseudonyms: pseudonyms)
        let before = env.sent.count
        env.advance(10_000)
        XCTAssertEqual(env.sent.count, before)
    }

    // MARK: incoming keys

    func testAReceivedKeyIsInstalledAtItsRingSlotForTheSendersPseudonymAndAcked() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 17, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.installs.removeAll()
        env.sent.removeAll()
        coordinator.onEnvelope(mediaKey(epoch: 17, fill: 0x42), from: userB)
        XCTAssertEqual(env.installs, [.init(key: Data(repeating: 0x42, count: 32), index: 1, participantId: GroupCallFixtures.pseudoB)])
        XCTAssertEqual(env.parsedSent().map { $0.envelope }, [.ack(callId: call, epoch: 17)])
        XCTAssertEqual(env.parsedSent().map { $0.user }, [userB])
        XCTAssertTrue(env.e2eeEvents().contains("key_installed"))
    }

    func testAKeyOlderThanOurEpochIsRefused() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 9, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.installs.removeAll()
        env.sent.removeAll()
        coordinator.onEnvelope(mediaKey(epoch: 8, fill: 1), from: userB)
        XCTAssertTrue(env.installs.isEmpty)
        XCTAssertTrue(env.sent.isEmpty, "no ack for a refused key")
    }

    func testAKeyFromTheFutureIsInstalled() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 9, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.installs.removeAll()
        coordinator.onEnvelope(mediaKey(epoch: 10, fill: 2), from: userB)
        XCTAssertEqual(env.installs.count, 1)
        XCTAssertEqual(env.installs[0].index, 10)
    }

    func testARetransmittedKeyIsAckedAgainButNotReinstalledAndADifferentKeyIsRefused() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.installs.removeAll()
        env.sent.removeAll()
        coordinator.onEnvelope(mediaKey(epoch: 4, fill: 5), from: userB)
        coordinator.onEnvelope(mediaKey(epoch: 4, fill: 5), from: userB)
        XCTAssertEqual(env.installs.count, 1)
        XCTAssertEqual(env.parsedSent().count, 2, "two acks")
        coordinator.onEnvelope(mediaKey(epoch: 4, fill: 6), from: userB)
        XCTAssertEqual(env.installs.count, 1, "a different key for the same (member, epoch) is never accepted")
        XCTAssertEqual(env.parsedSent().count, 2)
    }

    func testAKeyFromAnUnknownSenderIsHeldUntilTheRosterIntroducesThem() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 6, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        env.installs.removeAll()
        coordinator.onEnvelope(mediaKey(epoch: 7, fill: 9), from: userB)
        XCTAssertTrue(env.installs.isEmpty)
        coordinator.onRoster(epoch: 7, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertTrue(env.installs.contains(.init(key: Data(repeating: 9, count: 32), index: 7, participantId: GroupCallFixtures.pseudoB)))
    }

    func testAHeldKeyExpires() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 6, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        coordinator.onEnvelope(mediaKey(epoch: 7, fill: 9), from: userB)
        env.now += 10_001
        env.installs.removeAll()
        coordinator.onRoster(epoch: 7, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertFalse(env.installs.contains { $0.participantId == GroupCallFixtures.pseudoB })
    }

    func testTheHeldKeyBufferIsBounded() {
        var config = GroupE2eeCoordinator.Config()
        config.pendingLimit = 2
        let (coordinator, env) = make(config: config)
        coordinator.onRoster(epoch: 1, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        for i in 0..<5 { coordinator.onEnvelope(mediaKey(epoch: UInt32(2 + i), fill: UInt8(i + 1)), from: "u-\(i)") }
        env.installs.removeAll()
        var all = pseudonyms
        for i in 0..<5 { all["u-\(i)"] = String(repeating: "d\(i)", count: 16) }
        coordinator.onRoster(epoch: 1, members: [selfUser] + (0..<5).map { "u-\($0)" }, pseudonyms: all)
        XCTAssertEqual(env.installs.count, 2)
    }

    func testEnvelopesForAnotherCallOrFromOurselvesAreIgnored() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 1, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.installs.removeAll()
        env.sent.removeAll()
        coordinator.onEnvelope(.mediaKey(callId: "other", epoch: 1, index: 1, key: Data(repeating: 1, count: 32)), from: userB)
        coordinator.onEnvelope(mediaKey(epoch: 1, fill: 1), from: selfUser)
        XCTAssertTrue(env.installs.isEmpty)
        XCTAssertTrue(env.sent.isEmpty)
    }

    // MARK: nack

    func testMissingKeyNacksAtMostFourTimesEveryTwoSeconds() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.sent.removeAll()
        func nacks() -> Int { env.parsedSent().filter { if case .nack = $0.envelope { return true } else { return false } }.count }
        coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoB)
        XCTAssertEqual(nacks(), 1)
        coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoB)
        XCTAssertEqual(nacks(), 1, "inside the 2 s interval")
        for _ in 0..<6 {
            env.now += 2_000
            coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoB)
        }
        XCTAssertEqual(nacks(), 4, "capped at four attempts")
        XCTAssertTrue(env.e2eeEvents().contains("missing_key"))
        XCTAssertTrue(env.e2eeEvents().contains("nack"))
    }

    func testAnInstalledKeyResetsTheNackBudget() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        for _ in 0..<4 {
            coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoB)
            env.now += 2_000
        }
        coordinator.onEnvelope(mediaKey(epoch: 3, fill: 3), from: userB)
        env.sent.removeAll()
        env.now += 2_000
        coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoB)
        XCTAssertEqual(env.parsedSent().count, 1)
    }

    func testTheNackBudgetOfAnOlderEpochDoesNotSilenceTheNextEpoch() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        func nacks() -> Int { env.parsedSent().filter { if case .nack = $0.envelope { return true } else { return false } }.count }
        for _ in 0..<4 {
            coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoB)
            env.now += 2_000
        }
        XCTAssertEqual(nacks(), 4)
        coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoB)
        XCTAssertEqual(nacks(), 4, "the budget of epoch 3 is spent")
        // The next epoch's key is missing too: a new budget.
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoB)
        XCTAssertEqual(nacks(), 5)
    }

    func testMissingKeyOfOurOwnPseudonymOrAnUnknownOneNacksNobody() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.sent.removeAll()
        coordinator.onMissingKey(pseudonym: GroupCallFixtures.pseudoA)
        coordinator.onMissingKey(pseudonym: String(repeating: "ee", count: 16))
        XCTAssertTrue(env.sent.isEmpty)
    }

    func testANackMakesUsResendTheSameKeyButNotFasterThanTheGuard() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.sent.removeAll()
        coordinator.onEnvelope(.nack(callId: call, epoch: 3), from: userB)
        coordinator.onEnvelope(.nack(callId: call, epoch: 3), from: userB)
        XCTAssertEqual(env.parsedSent().count, 1)
        XCTAssertEqual(env.parsedSent()[0].envelope, .mediaKey(callId: call, epoch: 3, index: 3, key: Data(repeating: 1, count: 32)))
        env.now += 600
        coordinator.onEnvelope(.nack(callId: call, epoch: 3), from: userB)
        XCTAssertEqual(env.parsedSent().count, 2)
    }

    func testANackForAnEpochWeNeverHadOrFromANonMemberIsIgnored() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.sent.removeAll()
        coordinator.onEnvelope(.nack(callId: call, epoch: 2), from: userB)
        coordinator.onEnvelope(.nack(callId: call, epoch: 3), from: userC)
        XCTAssertTrue(env.sent.isEmpty)
    }

    func testANackForAnOlderEpochIsNeverAnsweredEvenIfTheKeyIsStillInTheRing() {
        // Backward secrecy: a member (say one that joined at epoch 4) asks for the key of
        // epoch 3, which we still hold in the ring - it must not get it.
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onRoster(epoch: 4, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        env.sent.removeAll()
        coordinator.onEnvelope(.nack(callId: call, epoch: 3), from: userC)
        XCTAssertTrue(env.sent.isEmpty, "only the current epoch's key is re-sent")
        coordinator.onEnvelope(.nack(callId: call, epoch: 4), from: userC)
        XCTAssertEqual(env.parsedSent().map { $0.envelope.epoch }, [4])
    }

    // MARK: lifecycle

    func testAMemberWhoLeftIsForgottenAndNoLongerAwaited() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        coordinator.onEnvelope(.ack(callId: call, epoch: 3), from: userB)
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)      // C dropped, same epoch
        coordinator.onEnvelope(.ack(callId: call, epoch: 3), from: userB)
        XCTAssertEqual(env.sendIndexes, [3])
    }

    func testStopWipesEverythingAndIgnoresLaterInput() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.stop()
        env.installs.removeAll()
        env.sent.removeAll()
        env.advance(10_000)
        coordinator.onEnvelope(mediaKey(epoch: 3, fill: 1), from: userB)
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertTrue(env.installs.isEmpty)
        XCTAssertTrue(env.sent.isEmpty)
        XCTAssertTrue(env.sendIndexes.isEmpty)
    }

    func testDecryptFailureIsReportedAsTelemetryOnly() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.sent.removeAll()
        coordinator.onDecryptFailure(pseudonym: GroupCallFixtures.pseudoB)
        XCTAssertTrue(env.e2eeEvents().contains("decrypt_fail"))
        XCTAssertTrue(env.sent.isEmpty)
    }

    func testTelemetryNeverCarriesKeyBytes() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(mediaKey(epoch: 3, fill: 0x42), from: userB)
        let dump = env.events.map { "\($0.kind) \($0.attrs)" }.joined()
        XCTAssertFalse(dump.contains(Data(repeating: 0x42, count: 32).base64EncodedString()))
        XCTAssertFalse(dump.contains(Data(repeating: 1, count: 32).base64EncodedString()))
    }
}
