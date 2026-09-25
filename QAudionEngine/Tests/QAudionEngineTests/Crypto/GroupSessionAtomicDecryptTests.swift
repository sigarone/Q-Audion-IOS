import XCTest
@testable import QAudionEngine

/// Group receive path is all-or-nothing.
///
/// `GroupSession.decryptFromGroupOrThrow` must leave the receive chain (chain
/// key, last-seen index, next index and the skipped-key cache, contents AND
/// order) exactly as it was when the frame does not decrypt, and must commit
/// the skip-ahead only once the frame's AEAD tag has verified.
///
/// State equality is checked on the byte level through
/// `GroupSessionSnapshotCodec.encode`, which serializes every one of those
/// fields in a fixed order.
final class GroupSessionAtomicDecryptTests: XCTestCase {

    private let groupId = Data([0xDE, 0xAD, 0xBE, 0xEF])
    private let nowMs: Int64 = 1_700_000_000_000

    // MARK: - Fixtures

    /// Alice sends, Bob receives. Bob holds Alice's chain installed at idx 0.
    private struct Pair {
        let alice: GroupSession
        let bob: GroupSession
        let aliceState: GroupState
        let bobState: GroupState
        /// Alice's chain key at index 0 (what Bob installed).
        let ck0: Data
    }

    private struct Attempt {
        let wire: Data
        let senderId: String
        let nowMs: Int64
    }

    private enum FailureKind: CaseIterable {
        case badTagInOrder
        case badTagSkipAhead
        case badNonceSkipAhead
        case badCiphertextSkipAhead
        case junkTagHighIndex
        case junkNonceHighIndex
        case jumpBeyondWindow
        case jumpBeyondCacheCap
        case badTagAfterEntriesExpired
        case replayOfCurrentFrame
        case replayOfOlderFrame
        case lateBadTag
        case lateBadNonce
        case lateBadCiphertext
        case wrongSenderId
        case malformedWire
    }

    private func makePair() throws -> Pair {
        let alice = GroupSession(vault: nil)
        let bob = GroupSession(vault: nil)
        let aliceState = try alice.create(
            groupIdBytes: groupId,
            members: ["alice", "bob"],
            selfId: "alice",
            selfSeed: Data(repeating: 0xAA, count: 32))
        let bobState = try bob.create(
            groupIdBytes: groupId,
            members: ["alice", "bob"],
            selfId: "bob",
            selfSeed: Data(repeating: 0xBB, count: 32))
        let ck0: Data = aliceState.sendChain.ck
        let env = SenderKeyInitEnvelope(
            g: GroupSenderKey.toHex(groupId),
            e: bobState.groupEpoch,
            seed: ck0.base64EncodedString(),
            idx: 0)
        try bob.handleSenderKeyInit(state: bobState, env: env, fromUserId: "alice")
        return Pair(alice: alice, bob: bob, aliceState: aliceState, bobState: bobState, ck0: ck0)
    }

    private func payload(_ index: Int) -> Data {
        var d = Data("group-frame-payload".utf8)
        d.append(UInt8(truncatingIfNeeded: index))
        d.append(UInt8(truncatingIfNeeded: index >> 8))
        return d
    }

    /// Alice encrypts `count` frames (chain indices 0..<count) and returns
    /// their wire bytes.
    private func encryptFrames(_ pair: Pair, count: Int) throws -> [Data] {
        var wires: [Data] = []
        var i: Int = 0
        while i < count {
            let result = try pair.alice.encryptForGroup(state: pair.aliceState, plaintext: payload(i))
            XCTAssertEqual(result.chainIdx, UInt64(i))
            wires.append(result.wire)
            i += 1
        }
        return wires
    }

    /// Bob decrypts `wire` from Alice at the fixed test time.
    @discardableResult
    private func deliver(_ pair: Pair, _ wire: Data) throws -> Data {
        return try pair.bob.decryptFromGroupOrThrow(
            state: pair.bobState, senderId: "alice", wire: wire, nowMs: nowMs)
    }

    private func snapshot(_ state: GroupState) -> Data {
        return GroupSessionSnapshotCodec.encode(state)
    }

    /// CK_index of Alice's chain, derived independently of the session code.
    private func chainKey(_ ck0: Data, at index: Int) -> Data {
        var ck: Data = ck0
        var i: Int = 0
        while i < index {
            ck = GroupSenderKey.stepChain(ck: ck)
            i += 1
        }
        return ck
    }

    /// The nonce Alice's chain derives for `index`.
    private func nonceAt(ck0: Data, index: Int) -> Data {
        let ck: Data = chainKey(ck0, at: index)
        let keys = GroupSenderKey.deriveMsgKeys(ck: ck)
        return keys.nonce
    }

    // MARK: - Frame tampering helpers

    private func flipTag(_ wire: Data) -> Data {
        var out: Data = wire
        let last = out.index(before: out.endIndex)
        out[last] = out[last] ^ 0x01
        return out
    }

    private func flipNonce(_ wire: Data) throws -> Data {
        let p = try GroupSenderKey.unpackGroupWire(wire)
        var nonce: Data = p.nonce
        let first = nonce.startIndex
        nonce[first] = nonce[first] ^ 0x01
        let ctWithTag: Data = p.ciphertext + p.tag
        return try GroupSenderKey.packGroupWire(
            groupIdBytes: p.groupId,
            groupEpoch: p.groupEpoch,
            senderId: p.senderId,
            chainIdx: p.chainIdx,
            nonce: nonce,
            ciphertextWithTag: ctWithTag)
    }

    private func flipCiphertext(_ wire: Data) throws -> Data {
        let p = try GroupSenderKey.unpackGroupWire(wire)
        var ct: Data = p.ciphertext
        XCTAssertFalse(ct.isEmpty)
        let first = ct.startIndex
        ct[first] = ct[first] ^ 0x01
        let ctWithTag: Data = ct + p.tag
        return try GroupSenderKey.packGroupWire(
            groupIdBytes: p.groupId,
            groupEpoch: p.groupEpoch,
            senderId: p.senderId,
            chainIdx: p.chainIdx,
            nonce: p.nonce,
            ciphertextWithTag: ctWithTag)
    }

    /// A frame for Alice's chain at `chainIdx` whose ciphertext and tag are
    /// filler bytes (never a valid AEAD output).
    private func forgedWire(chainIdx: UInt64, nonce: Data) throws -> Data {
        let junk = Data(repeating: 0xEE, count: 32)
        return try GroupSenderKey.packGroupWire(
            groupIdBytes: groupId,
            groupEpoch: 1,
            senderId: "alice",
            chainIdx: chainIdx,
            nonce: nonce,
            ciphertextWithTag: junk)
    }

    // MARK: - Failure catalogue

    /// Base scenario for the catalogue: Bob has received idx 0 and idx 4
    /// (skip-ahead), so lastSeen = 4, nextIdx = 5 and idx 1, 2, 3 sit in the
    /// skipped-key cache. Genuine frames 5, 6, 7 are still to come.
    private func makeAttempt(_ kind: FailureKind, pair: Pair, wires: [Data]) throws -> Attempt {
        let ttl: Int64 = GroupSenderKey.skippedKeysTtlMs
        let wrongNonce = Data(repeating: 0x42, count: 12)
        switch kind {
        case .badTagInOrder:
            return Attempt(wire: flipTag(wires[5]), senderId: "alice", nowMs: nowMs)
        case .badTagSkipAhead:
            return Attempt(wire: flipTag(wires[7]), senderId: "alice", nowMs: nowMs)
        case .badNonceSkipAhead:
            let w = try flipNonce(wires[7])
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs)
        case .badCiphertextSkipAhead:
            let w = try flipCiphertext(wires[7])
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs)
        case .junkTagHighIndex:
            let nonce: Data = nonceAt(ck0: pair.ck0, index: 60)
            let w = try forgedWire(chainIdx: 60, nonce: nonce)
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs)
        case .junkNonceHighIndex:
            let w = try forgedWire(chainIdx: 60, nonce: wrongNonce)
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs)
        case .jumpBeyondWindow:
            let far: UInt64 = GroupSenderKey.maxSkipAhead + 6
            let w = try forgedWire(chainIdx: far, nonce: wrongNonce)
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs)
        case .jumpBeyondCacheCap:
            // Inside the skip window but far past the cache cap, so the
            // eviction step would have to run on the scratch copy.
            let nonce: Data = nonceAt(ck0: pair.ck0, index: 400)
            let w = try forgedWire(chainIdx: 400, nonce: nonce)
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs)
        case .badTagAfterEntriesExpired:
            // By this time the cached entries 1, 2, 3 are past their TTL.
            let later: Int64 = nowMs + ttl + 1
            return Attempt(wire: flipTag(wires[7]), senderId: "alice", nowMs: later)
        case .replayOfCurrentFrame:
            return Attempt(wire: wires[4], senderId: "alice", nowMs: nowMs)
        case .replayOfOlderFrame:
            return Attempt(wire: wires[0], senderId: "alice", nowMs: nowMs)
        case .lateBadTag:
            return Attempt(wire: flipTag(wires[2]), senderId: "alice", nowMs: nowMs)
        case .lateBadNonce:
            let w = try flipNonce(wires[2])
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs)
        case .lateBadCiphertext:
            let w = try flipCiphertext(wires[2])
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs)
        case .wrongSenderId:
            return Attempt(wire: wires[5], senderId: "mallory", nowMs: nowMs)
        case .malformedWire:
            return Attempt(wire: Data([0xE4, 0x01]), senderId: "alice", nowMs: nowMs)
        }
    }

    /// After whatever failed, the genuine frames of the base scenario must
    /// all still decrypt (in order, then the late ones from the cache) and
    /// the chain must end where an undisturbed run would end.
    private func assertGenuineFramesStillDecrypt(_ pair: Pair, wires: [Data]) throws {
        let order: [Int] = [5, 6, 7, 1, 2, 3]
        for i in order {
            let pt = try deliver(pair, wires[i])
            XCTAssertEqual(pt, payload(i))
        }
        let recv = try XCTUnwrap(pair.bobState.recvChain(for: "alice"))
        XCTAssertEqual(recv.lastSeenIdx, 7)
        XCTAssertEqual(recv.nextIdx, 8)
        XCTAssertTrue(recv.skipped.isEmpty)
        XCTAssertEqual(recv.ck, chainKey(pair.ck0, at: 8))
    }

    // MARK: - (a) forged frame with a high chain index

    func testForgedHighIndexFrameLeavesStateUntouchedThenGenuineFramesDecrypt() throws {
        let pair = try makePair()
        let wires = try encryptFrames(pair, count: 4)
        let before = snapshot(pair.bobState)

        // Correct derived nonce for idx 50, filler ciphertext + tag: gets as
        // far as the AEAD check.
        let goodNonce: Data = nonceAt(ck0: pair.ck0, index: 50)
        let forgedAead = try forgedWire(chainIdx: 50, nonce: goodNonce)
        let out1: Data? = pair.bob.decryptFromGroup(
            state: pair.bobState, senderId: "alice", wire: forgedAead, nowMs: nowMs)
        XCTAssertNil(out1)
        XCTAssertEqual(snapshot(pair.bobState), before)

        // Same index with a wrong nonce: rejected at the nonce check.
        let forgedNonce = try forgedWire(chainIdx: 50, nonce: Data(repeating: 0x42, count: 12))
        let out2: Data? = pair.bob.decryptFromGroup(
            state: pair.bobState, senderId: "alice", wire: forgedNonce, nowMs: nowMs)
        XCTAssertNil(out2)
        XCTAssertEqual(snapshot(pair.bobState), before)

        // The genuine frames were not affected.
        var i: Int = 0
        while i < 4 {
            let pt = try deliver(pair, wires[i])
            XCTAssertEqual(pt, payload(i))
            i += 1
        }
        let recv = try XCTUnwrap(pair.bobState.recvChain(for: "alice"))
        XCTAssertEqual(recv.lastSeenIdx, 3)
        XCTAssertEqual(recv.nextIdx, 4)
        XCTAssertTrue(recv.skipped.isEmpty)
        XCTAssertEqual(recv.ck, chainKey(pair.ck0, at: 4))
    }

    // MARK: - (b) every failure kind leaves the state byte-identical

    func testEveryFailureKindLeavesReceiveStateByteIdentical() throws {
        for kind in FailureKind.allCases {
            let pair = try makePair()
            let wires = try encryptFrames(pair, count: 8)
            try deliver(pair, wires[0])
            try deliver(pair, wires[4])

            let base = try XCTUnwrap(pair.bobState.recvChain(for: "alice"))
            XCTAssertEqual(base.lastSeenIdx, 4)
            XCTAssertEqual(base.skipped.count, 3)
            let before = snapshot(pair.bobState)

            let attempt = try makeAttempt(kind, pair: pair, wires: wires)
            let out: Data? = pair.bob.decryptFromGroup(
                state: pair.bobState,
                senderId: attempt.senderId,
                wire: attempt.wire,
                nowMs: attempt.nowMs)
            let label: String = String(describing: kind)
            XCTAssertNil(out, label)
            XCTAssertEqual(snapshot(pair.bobState), before, label)

            try assertGenuineFramesStillDecrypt(pair, wires: wires)
        }
    }

    /// Many junk frames at many indices on ONE state, checking the snapshot
    /// after every single attempt.
    func testJunkFramesAtManyIndicesNeverMoveTheChain() throws {
        let pair = try makePair()
        let wires = try encryptFrames(pair, count: 8)
        try deliver(pair, wires[0])
        try deliver(pair, wires[4])
        let before = snapshot(pair.bobState)

        let indices: [Int] = [5, 6, 7, 8, 40, 255, 256, 257, 300, 1000]
        for index in indices {
            let goodNonce: Data = nonceAt(ck0: pair.ck0, index: index)
            let withGoodNonce = try forgedWire(chainIdx: UInt64(index), nonce: goodNonce)
            let out1: Data? = pair.bob.decryptFromGroup(
                state: pair.bobState, senderId: "alice", wire: withGoodNonce, nowMs: nowMs)
            XCTAssertNil(out1, "junk tag, index \(index)")
            XCTAssertEqual(snapshot(pair.bobState), before, "junk tag, index \(index)")

            let withBadNonce = try forgedWire(chainIdx: UInt64(index), nonce: Data(repeating: 0x42, count: 12))
            let out2: Data? = pair.bob.decryptFromGroup(
                state: pair.bobState, senderId: "alice", wire: withBadNonce, nowMs: nowMs)
            XCTAssertNil(out2, "junk nonce, index \(index)")
            XCTAssertEqual(snapshot(pair.bobState), before, "junk nonce, index \(index)")
        }

        try assertGenuineFramesStillDecrypt(pair, wires: wires)
    }

    // MARK: - (c) a valid skip-ahead still commits exactly as before

    func testValidSkipAheadWithinWindowDeliversAndCachesSkippedKeys() throws {
        let pair = try makePair()
        let wires = try encryptFrames(pair, count: 6)

        // Only idx 4 arrives: idx 0...3 are skipped.
        let pt4 = try deliver(pair, wires[4])
        XCTAssertEqual(pt4, payload(4))

        let recv = try XCTUnwrap(pair.bobState.recvChain(for: "alice"))
        XCTAssertEqual(recv.lastSeenIdx, 4)
        XCTAssertEqual(recv.nextIdx, 5)
        XCTAssertEqual(recv.ck, chainKey(pair.ck0, at: 5))
        XCTAssertEqual(recv.skipped.count, 4)

        let expiry: Int64 = nowMs + GroupSenderKey.skippedKeysTtlMs
        var k: Int = 0
        while k < 4 {
            let entry = recv.skipped[k]
            let keys = GroupSenderKey.deriveMsgKeys(ck: chainKey(pair.ck0, at: k))
            XCTAssertEqual(entry.0, UInt64(k))
            XCTAssertEqual(entry.1.key, keys.key)
            XCTAssertEqual(entry.1.nonce, keys.nonce)
            XCTAssertEqual(entry.1.expiresAtMs, expiry)
            k += 1
        }

        // A late frame is served from the cache and consumes its entry.
        let pt2 = try deliver(pair, wires[2])
        XCTAssertEqual(pt2, payload(2))
        XCTAssertEqual(recv.skipped.count, 3)
        let stillCached: [UInt64] = recv.skipped.map { $0.0 }
        let expectedCached: [UInt64] = [0, 1, 3]
        XCTAssertEqual(stillCached, expectedCached)

        // The same late frame again is a replay now.
        XCTAssertThrowsError(try deliver(pair, wires[2]))

        // In-order delivery carries on after the skip-ahead.
        let pt5 = try deliver(pair, wires[5])
        XCTAssertEqual(pt5, payload(5))
        XCTAssertEqual(recv.lastSeenIdx, 5)
        XCTAssertEqual(recv.nextIdx, 6)
        XCTAssertEqual(recv.ck, chainKey(pair.ck0, at: 6))
    }

    /// A valid skip-ahead larger than the cache cap keeps the newest
    /// `skippedKeysCacheMax` entries and drops the oldest ones.
    func testValidSkipAheadBeyondCacheCapEvictsOldestEntries() throws {
        let pair = try makePair()
        let wires = try encryptFrames(pair, count: 301)

        let pt = try deliver(pair, wires[300])
        XCTAssertEqual(pt, payload(300))

        let recv = try XCTUnwrap(pair.bobState.recvChain(for: "alice"))
        XCTAssertEqual(recv.lastSeenIdx, 300)
        XCTAssertEqual(recv.nextIdx, 301)
        XCTAssertEqual(recv.skipped.count, GroupSenderKey.skippedKeysCacheMax)
        let firstIdx: UInt64? = recv.skipped.first?.0
        let lastIdx: UInt64? = recv.skipped.last?.0
        XCTAssertEqual(firstIdx, 44)
        XCTAssertEqual(lastIdx, 299)
        XCTAssertEqual(recv.ck, chainKey(pair.ck0, at: 301))

        // An entry that survived eviction is still deliverable late.
        let late = try deliver(pair, wires[100])
        XCTAssertEqual(late, payload(100))
        XCTAssertEqual(recv.skipped.count, GroupSenderKey.skippedKeysCacheMax - 1)
    }

    /// A committed skip-ahead still expires stale cache entries, as it did
    /// before the scratch-copy change.
    func testValidSkipAheadStillEvictsExpiredEntriesOnCommit() throws {
        let pair = try makePair()
        let wires = try encryptFrames(pair, count: 10)

        try deliver(pair, wires[4])
        let recv = try XCTUnwrap(pair.bobState.recvChain(for: "alice"))
        XCTAssertEqual(recv.skipped.count, 4)

        // idx 9 arrives after the TTL of the entries 0...3 has passed.
        let later: Int64 = nowMs + GroupSenderKey.skippedKeysTtlMs + 1
        let pt9 = try pair.bob.decryptFromGroupOrThrow(
            state: pair.bobState, senderId: "alice", wire: wires[9], nowMs: later)
        XCTAssertEqual(pt9, payload(9))

        let cached: [UInt64] = recv.skipped.map { $0.0 }
        let expectedCached: [UInt64] = [5, 6, 7, 8]
        XCTAssertEqual(cached, expectedCached)
        XCTAssertEqual(recv.lastSeenIdx, 9)
        XCTAssertEqual(recv.ck, chainKey(pair.ck0, at: 10))
    }
}
