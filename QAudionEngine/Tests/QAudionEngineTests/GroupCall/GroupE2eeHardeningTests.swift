import XCTest
@testable import QAudionEngine

/// Spec §12 (security amendments after the Opus review), the parts that are
/// pure protocol: the pseudonym binding of `media_key` (12.5), slot retirement
/// (12.6), the nack budget and roster-ahead handling (12.7), key wiping (12.11)
/// and the control-channel wire policy (12.3). The WebRTC-shaped parts (12.1,
/// 12.8, 12.9) are in `GroupPeerIntegrationTests` / `GroupSdpRulesTests`.

// MARK: - Zeroable key buffer (12.11)

final class GroupKeyBufferTests: XCTestCase {

    func testABufferHoldsExactlyOneMediaKey() {
        XCTAssertNil(GroupKeyBuffer(Data()))
        XCTAssertNil(GroupKeyBuffer(Data(repeating: 1, count: 31)))
        XCTAssertNil(GroupKeyBuffer(Data(repeating: 1, count: 33)))
        XCTAssertNotNil(GroupKeyBuffer(Data(repeating: 1, count: 32)))
    }

    func testDataIsACopyAndWipeZeroesTheBufferInPlace() throws {
        let key = Data((0..<32).map { UInt8($0 + 1) })
        let buffer = try XCTUnwrap(GroupKeyBuffer(key))
        XCTAssertEqual(buffer.data, key)
        XCTAssertFalse(buffer.isWiped)
        let copy = buffer.data
        buffer.wipe()
        XCTAssertTrue(buffer.isWiped)
        XCTAssertEqual(buffer.data, Data(repeating: 0, count: 32), "the live bytes are zero")
        XCTAssertEqual(copy, key, "a copy handed out earlier belongs to its holder")
        buffer.wipe()
        XCTAssertTrue(buffer.isWiped, "idempotent")
    }

    func testComparisonIsByValue() throws {
        let a = try XCTUnwrap(GroupKeyBuffer(Data(repeating: 7, count: 32)))
        let same = try XCTUnwrap(GroupKeyBuffer(Data(repeating: 7, count: 32)))
        var other = Data(repeating: 7, count: 32)
        other[31] ^= 0x01
        let different = try XCTUnwrap(GroupKeyBuffer(other))
        XCTAssertTrue(a.matches(same))
        XCTAssertFalse(a.matches(different))
        same.wipe()
        XCTAssertFalse(a.matches(same), "a wiped key no longer equals the original")
    }

    func testRandomKeysAreStill32DifferentBytes() {
        let a = GroupE2ee.randomKey()
        let b = GroupE2ee.randomKey()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, Data(repeating: 0, count: 32))
    }
}

// MARK: - Control channel wire policy (12.3)

final class GroupControlChannelPolicyTests: XCTestCase {

    func testOnlyAV5ControlFrameIsAccepted() {
        XCTAssertTrue(GroupControlChannelPolicy.accepts(wire: Data([MessageWireFormat.magicV5, 1, 2, 3])))
    }

    func testEveryOtherMessageCryptoFormatIsRefused() {
        let refused: [(UInt8, String)] = [
            (MessageWireFormat.magicV4, "v4_wire_refused"),
            (MessageWireFormat.magicV3, "v3_wire_refused"),
            (MessageWireFormat.magicV2, "v2_wire_refused"),
            (0x00, "legacy_wire_refused"),
            (0x7F, "legacy_wire_refused"),
        ]
        for (magic, reason) in refused {
            let wire = Data([magic, 9, 9, 9, 9])
            XCTAssertFalse(GroupControlChannelPolicy.accepts(wire: wire), reason)
            XCTAssertEqual(GroupControlChannelPolicy.rejectionReason(for: wire), reason)
        }
    }

    func testAnEmptyBlobIsRefused() {
        XCTAssertFalse(GroupControlChannelPolicy.accepts(wire: Data()))
        XCTAssertEqual(GroupControlChannelPolicy.rejectionReason(for: Data()), "legacy_wire_refused")
    }

    func testTheReasonNeverCarriesWireBytes() {
        let reason = GroupControlChannelPolicy.rejectionReason(for: Data([MessageWireFormat.magicV3, 0xAB, 0xCD]))
        XCTAssertFalse(reason.lowercased().contains("ab"))
        XCTAssertFalse(reason.lowercased().contains("cd"))
    }
}

// MARK: - Coordinator hardening

final class GroupE2eeHardeningTests: XCTestCase {

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

    private func key(epoch: UInt32, fill: UInt8, pseudonym: String = GroupCallFixtures.pseudoB) -> GroupKeyEnvelope {
        .mediaKey(callId: call, epoch: epoch, index: GroupE2ee.keyIndex(forEpoch: epoch), key: Data(repeating: fill, count: 32),
                  pseudonym: pseudonym)
    }

    private func mediaKeysSent(_ env: FakeE2eeEnvironment, to user: String? = nil) -> [GroupKeyEnvelope] {
        env.parsedSent().filter { user == nil || $0.user == user }.compactMap { item in
            if case .mediaKey = item.envelope { return item.envelope }
            return nil
        }
    }

    // MARK: pseudonym binding (12.5)

    func testOurMediaKeyNamesOurOwnPseudonym() throws {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 5, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        let sent = mediaKeysSent(env)
        XCTAssertEqual(sent.count, 2)
        for envelope in sent {
            guard case .mediaKey(_, _, _, _, let pseudonym) = envelope else { return XCTFail("not a media key") }
            XCTAssertEqual(pseudonym, GroupCallFixtures.pseudoA)
        }
        let json = try XCTUnwrap(env.sent.first?.json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["p"] as? String, GroupCallFixtures.pseudoA)
    }

    func testAKeyThatNamesAnotherPseudonymThanTheRostersIsRefused() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        env.installs.removeAll()
        env.sent.removeAll()
        // userB claims to be userC, and claims to be us.
        coordinator.onEnvelope(key(epoch: 3, fill: 0x11, pseudonym: GroupCallFixtures.pseudoC), from: userB)
        coordinator.onEnvelope(key(epoch: 3, fill: 0x12, pseudonym: GroupCallFixtures.pseudoA), from: userB)
        coordinator.onEnvelope(key(epoch: 3, fill: 0x13, pseudonym: String(repeating: "ee", count: 16)), from: userB)
        XCTAssertTrue(env.installs.isEmpty, "nothing is installed under anybody's pseudonym")
        XCTAssertTrue(env.sent.isEmpty, "a refused key is not acked")
        XCTAssertTrue(coordinator.heldKeys(of: userB).isEmpty)
        XCTAssertFalse(env.e2eeEvents().contains("key_installed"))
        // The honest key of the same (member, epoch) is still accepted afterwards.
        coordinator.onEnvelope(key(epoch: 3, fill: 0x14), from: userB)
        XCTAssertEqual(env.installs, [.init(key: Data(repeating: 0x14, count: 32), index: 3, participantId: GroupCallFixtures.pseudoB)])
    }

    func testAHeldKeyIsCheckedAgainstTheRosterOnceTheSenderIsKnown() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 6, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        // Two members' keys arrive before the roster that introduces them: B names itself
        // correctly, C names B.
        coordinator.onEnvelope(key(epoch: 7, fill: 0x21), from: userB)
        coordinator.onEnvelope(key(epoch: 7, fill: 0x22, pseudonym: GroupCallFixtures.pseudoB), from: userC)
        env.installs.removeAll()
        coordinator.onRoster(epoch: 7, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        XCTAssertTrue(env.installs.contains(.init(key: Data(repeating: 0x21, count: 32), index: 7, participantId: GroupCallFixtures.pseudoB)))
        XCTAssertFalse(env.installs.contains { $0.key == Data(repeating: 0x22, count: 32) }, "C's key claimed B's pseudonym")
        XCTAssertTrue(coordinator.heldKeys(of: userC).isEmpty)
    }

    // MARK: slot retirement (12.6)

    func testOlderSlotsOfASenderAreOverwrittenWithRandomBytes10sAfterItsNewestKey() throws {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x11), from: userB)
        let old = try XCTUnwrap(coordinator.heldKeys(of: userB)[4])
        coordinator.onEnvelope(key(epoch: 5, fill: 0x22), from: userB)
        let newest = try XCTUnwrap(coordinator.heldKeys(of: userB)[5])
        env.installs.removeAll()

        env.advance(9_999)
        XCTAssertTrue(env.installs.isEmpty, "not before 10 s")
        XCTAssertFalse(old.isWiped)

        env.advance(1)
        XCTAssertEqual(env.installs.count, 1)
        let overwrite = try XCTUnwrap(env.installs.first)
        XCTAssertEqual(overwrite.index, 4, "the OLD slot")
        XCTAssertEqual(overwrite.participantId, GroupCallFixtures.pseudoB)
        XCTAssertEqual(overwrite.key.count, 32)
        XCTAssertNotEqual(overwrite.key, Data(repeating: 0x11, count: 32), "overwritten with fresh bytes, not the old key")
        XCTAssertNotEqual(overwrite.key, Data(repeating: 0x22, count: 32))
        XCTAssertTrue(old.isWiped, "the coordinator's own copy is zeroed too")
        XCTAssertFalse(newest.isWiped)
        XCTAssertEqual(Set(coordinator.heldKeys(of: userB).keys), [5])
    }

    func testANewerKeyPostponesTheRetirement() throws {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x11), from: userB)
        env.advance(6_000)
        coordinator.onEnvelope(key(epoch: 5, fill: 0x22), from: userB)
        env.installs.removeAll()
        env.advance(9_999)                                   // 10 s after epoch 4's key, 4 s after epoch 5's
        XCTAssertTrue(env.installs.isEmpty, "the clock restarts with the newest key")
        env.advance(1)
        XCTAssertEqual(env.installs.map { $0.index }, [4])
    }

    func testAMembersOnlyKeyIsNeverRetired() throws {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x11), from: userB)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x33, pseudonym: GroupCallFixtures.pseudoC), from: userC)
        env.installs.removeAll()
        env.advance(60_000)
        XCTAssertTrue(env.installs.isEmpty, "the key a sender is using is never overwritten")
        XCTAssertEqual(Set(coordinator.heldKeys(of: userB).keys), [4])
        XCTAssertEqual(Set(coordinator.heldKeys(of: userC).keys), [4])
    }

    func testEachSendersRetirementIsIndependent() throws {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x11), from: userB)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x33, pseudonym: GroupCallFixtures.pseudoC), from: userC)
        coordinator.onEnvelope(key(epoch: 5, fill: 0x22), from: userB)         // only B moved on
        env.installs.removeAll()
        env.advance(10_000)
        XCTAssertEqual(env.installs.map { $0.participantId }, [GroupCallFixtures.pseudoB])
        XCTAssertEqual(env.installs.map { $0.index }, [4])
    }

    func testOurOwnOlderKeysAreWipedAfterTheSwitchAndTheirSlotsOverwritten() throws {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 1, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        let first = try XCTUnwrap(coordinator.heldOwnKeys[1])
        coordinator.onRoster(epoch: 2, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])   // switches at once
        let second = try XCTUnwrap(coordinator.heldOwnKeys[2])
        XCTAssertEqual(coordinator.sendingEpoch, 2)
        env.installs.removeAll()

        env.advance(9_999)
        XCTAssertFalse(first.isWiped)
        XCTAssertTrue(env.installs.isEmpty)
        env.advance(1)
        XCTAssertTrue(first.isWiped)
        XCTAssertFalse(second.isWiped, "the key we send with stays")
        XCTAssertEqual(env.installs.count, 1)
        XCTAssertEqual(env.installs[0].index, 1)
        XCTAssertEqual(env.installs[0].participantId, GroupCallFixtures.pseudoA)
        XCTAssertNotEqual(env.installs[0].key, Data(repeating: 1, count: 32), "overwritten with fresh bytes")
        XCTAssertEqual(Set(coordinator.heldOwnKeys.keys), [2])
    }

    func testAPeriodicEpochBumpWithoutARosterChangeIsAnOrdinaryRotation() {
        // Spec 12.6: the server bumps the epoch every 30 minutes even when nobody joined or left.
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 8, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(.ack(callId: call, epoch: 8), from: userB)
        env.sent.removeAll()
        env.installs.removeAll()
        coordinator.onRoster(epoch: 9, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertEqual(env.installs.count, 1)
        XCTAssertEqual(env.installs[0].index, 9)
        XCTAssertNotEqual(env.installs[0].key, Data(repeating: 1, count: 32), "a FRESH key, nothing derived from the last one")
        XCTAssertEqual(mediaKeysSent(env, to: userB).map { $0.epoch }, [9])
        coordinator.onEnvelope(.ack(callId: call, epoch: 9), from: userB)
        XCTAssertEqual(coordinator.sendingEpoch, 9)
    }

    // MARK: key wiping (12.11)

    func testAMemberWhoLeftHasItsKeysWiped() throws {
        let (coordinator, _) = make()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x11), from: userB)
        let held = try XCTUnwrap(coordinator.heldKeys(of: userB)[4])
        coordinator.onRoster(epoch: 5, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        XCTAssertTrue(held.isWiped)
        XCTAssertTrue(coordinator.heldKeys(of: userB).isEmpty)
    }

    func testARetransmittedKeyLeavesNoLiveCopyBehindAndAReplacingKeyWipesTheOldOne() throws {
        let (coordinator, _) = make()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x11), from: userB)
        let held = try XCTUnwrap(coordinator.heldKeys(of: userB)[4])
        coordinator.onEnvelope(key(epoch: 4, fill: 0x11), from: userB)
        XCTAssertFalse(held.isWiped, "a retransmission leaves the installed key untouched")
        XCTAssertEqual(held.data, Data(repeating: 0x11, count: 32))
        // A different key for the same (member, epoch) replaces it: the old buffer is zeroed.
        coordinator.onEnvelope(key(epoch: 4, fill: 0x99), from: userB)
        XCTAssertTrue(held.isWiped, "the replaced key is zeroed")
        let replacement = try XCTUnwrap(coordinator.heldKeys(of: userB)[4])
        XCTAssertFalse(replacement.isWiped)
        XCTAssertEqual(replacement.data, Data(repeating: 0x99, count: 32))
    }

    func testAKeyOutOfTheRingWindowIsWiped() throws {
        let (coordinator, _) = make()
        coordinator.onRoster(epoch: 1, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(key(epoch: 1, fill: 0x11), from: userB)
        let first = try XCTUnwrap(coordinator.heldKeys(of: userB)[1])
        coordinator.onEnvelope(key(epoch: 17, fill: 0x22), from: userB)    // slot 1 is reused
        XCTAssertTrue(first.isWiped)
        XCTAssertEqual(Set(coordinator.heldKeys(of: userB).keys), [17])
    }

    func testStopWipesEveryKeyTheCoordinatorHolds() throws {
        let (coordinator, _) = make()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x11), from: userB)
        coordinator.onEnvelope(key(epoch: 4, fill: 0x44, pseudonym: String(repeating: "f4", count: 16)), from: "u-unknown")
        let own = try XCTUnwrap(coordinator.heldOwnKeys[4])
        let theirs = try XCTUnwrap(coordinator.heldKeys(of: userB)[4])
        let held = try XCTUnwrap(coordinator.heldPendingKeys.first)
        coordinator.stop()
        XCTAssertTrue(own.isWiped)
        XCTAssertTrue(theirs.isWiped)
        XCTAssertTrue(held.isWiped)
        XCTAssertTrue(coordinator.heldOwnKeys.isEmpty)
        XCTAssertTrue(coordinator.heldKeys(of: userB).isEmpty)
        XCTAssertTrue(coordinator.heldPendingKeys.isEmpty)
    }

    func testAPendingKeyThatExpiresIsWiped() throws {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 6, members: [selfUser], pseudonyms: [selfUser: GroupCallFixtures.pseudoA])
        coordinator.onEnvelope(key(epoch: 7, fill: 9), from: userB)
        let held = try XCTUnwrap(coordinator.heldPendingKeys.first)
        env.now += 10_001
        coordinator.onRoster(epoch: 7, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertTrue(held.isWiped)
        XCTAssertTrue(coordinator.heldPendingKeys.isEmpty)
    }

    // MARK: nack budget (12.7)

    func testAtMostFourNacksPerRequesterPerEpochAreAnswered() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB, userC], pseudonyms: pseudonyms)
        env.sent.removeAll()
        for _ in 0..<8 {
            coordinator.onEnvelope(.nack(callId: call, epoch: 3), from: userB)
            env.now += 600                                      // clear of the 500 ms guard
        }
        XCTAssertEqual(mediaKeysSent(env, to: userB).count, 4, "a fifth nack of the same epoch is not answered")
        // Another requester has its own budget.
        coordinator.onEnvelope(.nack(callId: call, epoch: 3), from: userC)
        XCTAssertEqual(mediaKeysSent(env, to: userC).count, 1)
    }

    func testANewEpochGivesTheRequesterANewBudget() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        for _ in 0..<6 {
            coordinator.onEnvelope(.nack(callId: call, epoch: 3), from: userB)
            env.now += 600
        }
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.sent.removeAll()
        coordinator.onEnvelope(.nack(callId: call, epoch: 4), from: userB)
        XCTAssertEqual(mediaKeysSent(env, to: userB).map { $0.epoch }, [4])
    }

    func testANackAheadOfOurRosterIsNotAnsweredUntilTheRosterArrives() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        env.sent.removeAll()
        // B's roster is already at epoch 4, ours is not: no key of epoch 4 exists yet.
        coordinator.onEnvelope(.nack(callId: call, epoch: 4), from: userB)
        XCTAssertTrue(env.sent.isEmpty)
        // Our update for epoch 4 distributes the key to B, which is the answer.
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertEqual(mediaKeysSent(env, to: userB).map { $0.epoch }, [4], "exactly one key, no duplicate")
    }

    func testANackAheadOfOurRosterFromAnOutsiderGetsNothingWhenTheRosterArrives() {
        let (coordinator, env) = make()
        coordinator.onRoster(epoch: 3, members: [selfUser, userB], pseudonyms: pseudonyms)
        coordinator.onEnvelope(.nack(callId: call, epoch: 4), from: userC)
        env.sent.removeAll()
        coordinator.onRoster(epoch: 4, members: [selfUser, userB], pseudonyms: pseudonyms)
        XCTAssertTrue(mediaKeysSent(env, to: userC).isEmpty, "C is not a member of epoch 4")
    }
}
