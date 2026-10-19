import XCTest
@testable import QAudionEngine

final class GroupSessionTests: XCTestCase {

    private let groupId = Data([0xDE, 0xAD, 0xBE, 0xEF])

    private func newSession() -> GroupSession {
        return GroupSession(vault: InMemoryGroupSessionVault())
    }

    // MARK: - create

    func testCreateRequiresSelfInMembers() throws {
        let s = newSession()
        XCTAssertThrowsError(try s.create(groupIdBytes: groupId,
                                          members: ["alice", "bob"],
                                          selfId: "carol"))
    }

    func testCreateInitializesSendChain() throws {
        let s = newSession()
        let seed = Data(repeating: 0x77, count: 32)
        let st = try s.create(groupIdBytes: groupId, members: ["alice", "bob"],
                                selfId: "alice", selfSeed: seed)
        XCTAssertEqual(st.sendChain.ck.count, 32)
        XCTAssertEqual(st.sendChain.nextIdx, 0)
        XCTAssertNil(st.sendChain.lastSeenIdx)
        XCTAssertTrue(st.recvChains.isEmpty)
    }

    // MARK: - encrypt + decrypt round trip via sender_key_init

    func testGroupRoundTripAliceBobViaInit() throws {
        let aliceVault = InMemoryGroupSessionVault()
        let bobVault = InMemoryGroupSessionVault()
        let alice = GroupSession(vault: aliceVault)
        let bob = GroupSession(vault: bobVault)

        // 1. Both create their own state with shared known seeds (KAT-friendly).
        let aliceSeed = Data(repeating: 0xAA, count: 32)
        let bobSeed = Data(repeating: 0xBB, count: 32)
        let aliceState = try alice.create(groupIdBytes: groupId,
                                            members: ["alice", "bob"],
                                            selfId: "alice", selfSeed: aliceSeed)
        let bobState = try bob.create(groupIdBytes: groupId,
                                        members: ["alice", "bob"],
                                        selfId: "bob", selfSeed: bobSeed)

        // 2. Each ships their own SenderKeyInit to the other (out-of-band
        //    via the 1:1 ratchet). We replay it here directly.
        let aliceInit = try alice.handleMemberAdded(state: aliceState, newMember: "ignored-just-build-init")
        // Actually — the proper pattern is for each peer to package an init
        // for the other. Use the explicit envelope shape used internally.
        _ = aliceInit
        let aliceInitEnv = SenderKeyInitEnvelope(
            g: GroupSenderKey.toHex(groupId),
            e: aliceState.groupEpoch,
            seed: aliceState.sendChain.ck.base64EncodedString(),
            idx: aliceState.sendChain.nextIdx
        )
        let bobInitEnv = SenderKeyInitEnvelope(
            g: GroupSenderKey.toHex(groupId),
            e: bobState.groupEpoch,
            seed: bobState.sendChain.ck.base64EncodedString(),
            idx: bobState.sendChain.nextIdx
        )
        try alice.handleSenderKeyInit(state: aliceState, env: bobInitEnv, fromUserId: "bob")
        try bob.handleSenderKeyInit(state: bobState, env: aliceInitEnv, fromUserId: "alice")

        // 3. Alice encrypts → Bob decrypts.
        let pt = Data("hello group".utf8)
        let r = try alice.encryptForGroup(state: aliceState, plaintext: pt)
        XCTAssertEqual(r.chainIdx, 0)
        let decrypted = try bob.decryptFromGroupOrThrow(state: bobState,
                                                          senderId: "alice",
                                                          wire: r.wire)
        XCTAssertEqual(decrypted, pt)

        // 4. Bob → Alice on his chain.
        let pt2 = Data("howdy alice".utf8)
        let r2 = try bob.encryptForGroup(state: bobState, plaintext: pt2)
        let decrypted2 = try alice.decryptFromGroupOrThrow(state: aliceState,
                                                            senderId: "bob",
                                                            wire: r2.wire)
        XCTAssertEqual(decrypted2, pt2)
    }

    func testReplayRejected() throws {
        let alice = newSession()
        let bob = newSession()
        let aliceSeed = Data(repeating: 0xAA, count: 32)
        let bobSeed = Data(repeating: 0xBB, count: 32)
        let aliceState = try alice.create(groupIdBytes: groupId,
                                            members: ["alice", "bob"], selfId: "alice", selfSeed: aliceSeed)
        let bobState = try bob.create(groupIdBytes: groupId,
                                        members: ["alice", "bob"], selfId: "bob", selfSeed: bobSeed)
        try bob.handleSenderKeyInit(state: bobState,
            env: SenderKeyInitEnvelope(g: GroupSenderKey.toHex(groupId),
                                        e: 1,
                                        seed: aliceState.sendChain.ck.base64EncodedString(),
                                        idx: 0),
            fromUserId: "alice")

        let pt = Data("once".utf8)
        let r = try alice.encryptForGroup(state: aliceState, plaintext: pt)
        _ = try bob.decryptFromGroupOrThrow(state: bobState, senderId: "alice", wire: r.wire)
        // Replay the same wire — must throw.
        XCTAssertThrowsError(try bob.decryptFromGroupOrThrow(state: bobState, senderId: "alice", wire: r.wire))
    }

    // MARK: - membership ops

    func testMemberAddedDoesntBumpEpoch() throws {
        let s = newSession()
        let st = try s.create(groupIdBytes: groupId, members: ["a", "b"], selfId: "a")
        let beforeEpoch = st.groupEpoch
        let pkg = try s.handleMemberAdded(state: st, newMember: "c")
        XCTAssertEqual(st.groupEpoch, beforeEpoch)
        XCTAssertTrue(st.members.contains("c"))
        XCTAssertEqual(pkg.initForNewMember.t, "sender_key_init")
        XCTAssertEqual(pkg.initForNewMember.g, GroupSenderKey.toHex(groupId))
    }

    func testMemberRemovedBumpsEpochAndDropsRecvChains() throws {
        let s = newSession()
        let st = try s.create(groupIdBytes: groupId, members: ["a", "b", "c"], selfId: "a")
        // Pretend we've installed sender keys for b and c.
        st.setRecvChain("b", GroupSenderChain.newRecv(ck: Data(repeating: 0x10, count: 32), lastSeenIdx: nil))
        st.setRecvChain("c", GroupSenderChain.newRecv(ck: Data(repeating: 0x20, count: 32), lastSeenIdx: nil))
        let beforeEpoch = st.groupEpoch
        let pkg = try s.handleMemberRemoved(state: st, removed: "c")
        XCTAssertEqual(st.groupEpoch, beforeEpoch + 1)
        XCTAssertFalse(st.members.contains("c"))
        XCTAssertTrue(st.recvChains.isEmpty, "all recv chains should be dropped on member removal")
        XCTAssertEqual(pkg.rotateEnvelope.t, "sender_key_rotate")
        XCTAssertEqual(pkg.rotateEnvelope.e, st.groupEpoch)
    }

    func testRotateOwnSenderKeyResetsChainAtSameEpoch() throws {
        let s = newSession()
        let st = try s.create(groupIdBytes: groupId, members: ["a", "b"], selfId: "a")
        // Send one msg so nextIdx > 0.
        _ = try s.encryptForGroup(state: st, plaintext: Data("x".utf8))
        XCTAssertEqual(st.sendChain.nextIdx, 1)
        let pkg = try s.rotateOwnSenderKey(state: st)
        XCTAssertEqual(st.groupEpoch, 1) // unchanged
        XCTAssertEqual(st.sendChain.nextIdx, 0) // fresh chain
        XCTAssertEqual(pkg.rotateEnvelope.t, "sender_key_rotate")
    }

    // MARK: - envelope sanity

    func testHandleSenderKeyInitRejectsOwnSelf() throws {
        let s = newSession()
        let st = try s.create(groupIdBytes: groupId, members: ["a", "b"], selfId: "a")
        let env = SenderKeyInitEnvelope(g: GroupSenderKey.toHex(groupId),
                                          e: st.groupEpoch,
                                          seed: Data(repeating: 0x01, count: 32).base64EncodedString(),
                                          idx: 0)
        XCTAssertThrowsError(try s.handleSenderKeyInit(state: st, env: env, fromUserId: "a"))
    }

    func testHandleSenderKeyInitRejectsEpochMismatch() throws {
        let s = newSession()
        let st = try s.create(groupIdBytes: groupId, members: ["a", "b"], selfId: "a")
        let env = SenderKeyInitEnvelope(g: GroupSenderKey.toHex(groupId),
                                          e: 999,  // wrong epoch
                                          seed: Data(repeating: 0x01, count: 32).base64EncodedString(),
                                          idx: 0)
        XCTAssertThrowsError(try s.handleSenderKeyInit(state: st, env: env, fromUserId: "b"))
    }

    // MARK: - dropUnaddedMembers (the creator's roster after the server left members out)

    func testDropUnaddedMembersRemovesThemFromTheRosterWithoutRekeying() throws {
        let vault = InMemoryGroupSessionVault()
        let s = GroupSession(vault: vault)
        let st = try s.create(groupIdBytes: groupId, members: ["a", "b", "c", "d"], admins: ["a", "c"], selfId: "a",
                              selfSeed: Data(repeating: 0x42, count: 32))
        let epochBefore = st.groupEpoch
        let keyBefore = st.sendChain.ck
        let removed = s.dropUnaddedMembers(state: st, unadded: ["c", "d", "not-a-member"])
        XCTAssertEqual(removed, ["c", "d"])
        XCTAssertEqual(st.members, ["a", "b"])
        XCTAssertEqual(st.admins, ["a"], "an admin who is out leaves the admin list too")
        XCTAssertEqual(st.groupEpoch, epochBefore, "nobody who is out ever got a key: no epoch bump")
        XCTAssertEqual(st.sendChain.ck, keyBefore, "and no new send key")
        let saved = try XCTUnwrap(vault.load(groupIdBytes: groupId, groupEpoch: epochBefore, selfId: "a"))
        XCTAssertEqual(saved.members, ["a", "b"], "the cut roster is what the vault holds")
    }

    func testDropUnaddedMembersNeverRemovesTheCreatorAndIgnoresUnknownIds() throws {
        let s = newSession()
        let st = try s.create(groupIdBytes: groupId, members: ["a", "b"], admins: ["a"], selfId: "a")
        XCTAssertEqual(s.dropUnaddedMembers(state: st, unadded: ["a"]), [])
        XCTAssertEqual(st.members, ["a", "b"])
        XCTAssertEqual(s.dropUnaddedMembers(state: st, unadded: []), [])
        XCTAssertEqual(s.dropUnaddedMembers(state: st, unadded: ["zzz"]), [])
        XCTAssertEqual(st.members, ["a", "b"])
        XCTAssertEqual(st.admins, ["a"])
    }

    func testDropUnaddedMembersLeavesTheKeysOfTheOthersAlone() throws {
        let s = newSession()
        let st = try s.create(groupIdBytes: groupId, members: ["a", "b", "c"], admins: ["a"], selfId: "a")
        let env = SenderKeyInitEnvelope(g: GroupSenderKey.toHex(groupId), e: st.groupEpoch,
                                        seed: Data(repeating: 0x05, count: 32).base64EncodedString(), idx: 0)
        try s.handleSenderKeyInit(state: st, env: env, fromUserId: "b")
        _ = s.dropUnaddedMembers(state: st, unadded: ["c"])
        XCTAssertNotNil(st.recvChain(for: "b"), "a member who stays keeps the chain installed for them")
        XCTAssertNil(st.recvChain(for: "c"))
    }
}
