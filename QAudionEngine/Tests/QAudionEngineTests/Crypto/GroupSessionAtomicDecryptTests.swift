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

    /// Shape of the catalogue's base scenario (see `makeAttempt`): Bob has
    /// received idx 0 and idx 4, so the next expected index is 5 and idx 1, 2
    /// and 3 sit in the skipped-key cache. The indices of the skip-ahead cases
    /// are derived from this shape and from the real limits in
    /// `GroupSenderKey`, and each one is checked by `assertSkipIdx`, so a
    /// change of a limit cannot quietly turn a case into a duplicate of
    /// another one.
    private let baseExpectedIdx: UInt64 = 5
    private let baseCachedCount: Int = 3

    /// Start of the error message of a frame that reached the AEAD check.
    private let aeadFailurePrefix: String = "AEAD decrypt failed"
    /// Start of the error message of a frame rejected at the nonce check.
    private let nonceFailurePrefix: String = "derived-nonce vs wire-nonce mismatch"
    /// Start of the error message of a frame rejected by the skip window.
    private let windowFailurePrefix: String = "skip-ahead"

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
        /// When set, the failure must be a `SessionError.ratchet` whose
        /// message starts with this text (used for the forged frames, to prove
        /// they were rejected at the intended stage and not earlier).
        var reasonPrefix: String? = nil
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
    /// filler bytes (never a valid AEAD output). It carries the fixture's own
    /// group epoch, so it passes the group, epoch and sender checks and is
    /// only rejected further down (skip window, nonce check or AEAD tag).
    private func forgedWire(_ pair: Pair, chainIdx: UInt64, nonce: Data) throws -> Data {
        let junk = Data(repeating: 0xEE, count: 32)
        let epoch: UInt32 = pair.bobState.groupEpoch
        return try GroupSenderKey.packGroupWire(
            groupIdBytes: groupId,
            groupEpoch: epoch,
            senderId: "alice",
            chainIdx: chainIdx,
            nonce: nonce,
            ciphertextWithTag: junk)
    }

    /// The message of the `SessionError.ratchet` thrown when Bob decrypts
    /// `wire` (from Alice), or a marker text when the call does not throw
    /// that error.
    private func ratchetFailure(_ pair: Pair, _ wire: Data) -> String {
        do {
            _ = try deliver(pair, wire)
            return "accepted"
        } catch GroupSession.SessionError.ratchet(let message) {
            return message
        } catch {
            return "other error"
        }
    }

    /// A forged frame must be rejected, must be rejected for `reasonPrefix`
    /// (so it really got as far as the intended check), and must leave the
    /// receive state byte-identical to `before`.
    private func assertForgedRejected(
        _ pair: Pair, wire: Data, reasonPrefix: String, before: Data, label: String
    ) {
        let out: Data? = pair.bob.decryptFromGroup(
            state: pair.bobState, senderId: "alice", wire: wire, nowMs: nowMs)
        XCTAssertNil(out, label)
        XCTAssertEqual(snapshot(pair.bobState), before, label)

        let reason: String = ratchetFailure(pair, wire)
        let reasonLabel: String = "\(label): rejected with '\(reason)'"
        XCTAssertTrue(reason.hasPrefix(reasonPrefix), reasonLabel)
        XCTAssertEqual(snapshot(pair.bobState), before, label)
    }

    /// Smallest chain index for which a skip-ahead from the base scenario
    /// leaves more than `skippedKeysCacheMax` keys in the cache, i.e. the
    /// first index where the eviction step has something to drop.
    private func firstCacheOverflowIdx() -> UInt64 {
        let cap: UInt64 = UInt64(GroupSenderKey.skippedKeysCacheMax)
        let cached: UInt64 = UInt64(baseCachedCount)
        return baseExpectedIdx + cap - cached + 1
    }

    /// Precondition of a skip-ahead case: `idx` must be reachable from the
    /// base scenario inside the skip window and, depending on
    /// `overflowsCache`, must (or must not) push the skipped-key cache past
    /// its cap. Fails loudly when a limit change breaks that.
    private func assertSkipIdx(_ idx: UInt64, overflowsCache: Bool, _ label: String) {
        guard idx >= baseExpectedIdx else {
            let message: String = "index \(idx) is below the next expected index: \(label)"
            XCTFail(message)
            return
        }
        let skipCount: UInt64 = idx - baseExpectedIdx
        XCTAssertLessThanOrEqual(skipCount, GroupSenderKey.maxSkipAhead, label)
        let firstOverflow: UInt64 = firstCacheOverflowIdx()
        if overflowsCache {
            XCTAssertGreaterThanOrEqual(idx, firstOverflow, label)
        } else {
            XCTAssertLessThan(idx, firstOverflow, label)
        }
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
            // Inside the skip window and below the cache overflow point.
            let highIdx: UInt64 = 60
            assertSkipIdx(highIdx, overflowsCache: false, "junkTagHighIndex")
            let nonce: Data = nonceAt(ck0: pair.ck0, index: Int(highIdx))
            let w = try forgedWire(pair, chainIdx: highIdx, nonce: nonce)
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs, reasonPrefix: aeadFailurePrefix)
        case .junkNonceHighIndex:
            let highIdx: UInt64 = 60
            assertSkipIdx(highIdx, overflowsCache: false, "junkNonceHighIndex")
            let w = try forgedWire(pair, chainIdx: highIdx, nonce: wrongNonce)
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs, reasonPrefix: nonceFailurePrefix)
        case .jumpBeyondWindow:
            // One past the last index the skip window still allows.
            let far: UInt64 = baseExpectedIdx + GroupSenderKey.maxSkipAhead + 1
            let w = try forgedWire(pair, chainIdx: far, nonce: wrongNonce)
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs, reasonPrefix: windowFailurePrefix)
        case .jumpBeyondCacheCap:
            // Inside the skip window but well past the point where the
            // skipped-key cache overflows, so the eviction step would have to
            // run on the scratch copy.
            let overflowIdx: UInt64 = firstCacheOverflowIdx() + 100
            assertSkipIdx(overflowIdx, overflowsCache: true, "jumpBeyondCacheCap")
            let nonce: Data = nonceAt(ck0: pair.ck0, index: Int(overflowIdx))
            let w = try forgedWire(pair, chainIdx: overflowIdx, nonce: nonce)
            return Attempt(wire: w, senderId: "alice", nowMs: nowMs, reasonPrefix: aeadFailurePrefix)
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

        // This index has to stay inside the skip window and below the cache
        // cap (nothing has been received yet, so the skip starts at idx 0),
        // otherwise the case would exercise the window or the eviction
        // instead of a plain skip-ahead.
        let highIdx: UInt64 = 50
        XCTAssertLessThanOrEqual(highIdx, GroupSenderKey.maxSkipAhead, "high index vs skip window")
        let cap: UInt64 = UInt64(GroupSenderKey.skippedKeysCacheMax)
        XCTAssertLessThan(highIdx, cap, "high index vs cache cap")

        // Correct derived nonce for the index, filler ciphertext + tag: gets
        // as far as the AEAD check.
        let goodNonce: Data = nonceAt(ck0: pair.ck0, index: Int(highIdx))
        let forgedAead = try forgedWire(pair, chainIdx: highIdx, nonce: goodNonce)
        assertForgedRejected(
            pair, wire: forgedAead, reasonPrefix: aeadFailurePrefix,
            before: before, label: "forged tag, high index")

        // Same index with a wrong nonce: rejected at the nonce check.
        let wrongNonce = Data(repeating: 0x42, count: 12)
        let forgedNonce = try forgedWire(pair, chainIdx: highIdx, nonce: wrongNonce)
        assertForgedRejected(
            pair, wire: forgedNonce, reasonPrefix: nonceFailurePrefix,
            before: before, label: "forged nonce, high index")

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
            XCTAssertEqual(base.nextIdx, baseExpectedIdx)
            XCTAssertEqual(base.skipped.count, baseCachedCount)
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

            if let prefix = attempt.reasonPrefix {
                let reason: String = ratchetFailure(pair, attempt.wire)
                let reasonLabel: String = "\(label): rejected with '\(reason)'"
                XCTAssertTrue(reason.hasPrefix(prefix), reasonLabel)
                XCTAssertEqual(snapshot(pair.bobState), before, label)
            }

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

        // The indices come from the base scenario and the real limits: the
        // next expected index and a few short skip-aheads, a mid-range one,
        // both sides of the point where the skipped-key cache starts to
        // overflow, and two well past it (still inside the skip window).
        // `assertSkipIdx` checks every one of them against the limits.
        let cap: Int = GroupSenderKey.skippedKeysCacheMax
        let expected: Int = Int(baseExpectedIdx)
        let overflow: Int = Int(firstCacheOverflowIdx())
        let midIdx: Int = 40
        let justBelowOverflow: Int = overflow - 1
        let justPastOverflow: Int = overflow + 1
        let pastOverflow: Int = overflow + 41
        let farPastOverflow: Int = overflow + 3 * cap
        let expectedPlus1: Int = expected + 1
        let expectedPlus2: Int = expected + 2
        let expectedPlus3: Int = expected + 3
        let indices: [Int] = [
            expected, expectedPlus1, expectedPlus2, expectedPlus3,
            midIdx,
            justBelowOverflow, overflow, justPastOverflow,
            pastOverflow, farPastOverflow
        ]
        let wrongNonce = Data(repeating: 0x42, count: 12)
        for index in indices {
            let idx: UInt64 = UInt64(index)
            let overflows: Bool = index >= overflow
            let idxLabel: String = "junk index \(index)"
            assertSkipIdx(idx, overflowsCache: overflows, idxLabel)

            let goodNonce: Data = nonceAt(ck0: pair.ck0, index: index)
            let withGoodNonce = try forgedWire(pair, chainIdx: idx, nonce: goodNonce)
            assertForgedRejected(
                pair, wire: withGoodNonce, reasonPrefix: aeadFailurePrefix,
                before: before, label: "junk tag, index \(index)")

            let withBadNonce = try forgedWire(pair, chainIdx: idx, nonce: wrongNonce)
            assertForgedRejected(
                pair, wire: withBadNonce, reasonPrefix: nonceFailurePrefix,
                before: before, label: "junk nonce, index \(index)")
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

        // Nothing has been received yet, so jumping to idx `target` skips
        // idx 0..<target: exactly `evictedCount` more keys than the cache
        // holds, and the oldest `evictedCount` of them are dropped. The jump
        // has to fit the skip window, or it would be rejected instead.
        let cap: Int = GroupSenderKey.skippedKeysCacheMax
        let evictedCount: Int = 44
        let target: Int = cap + evictedCount
        XCTAssertGreaterThan(evictedCount, 0)
        XCTAssertLessThanOrEqual(UInt64(target), GroupSenderKey.maxSkipAhead, "jump vs skip window")
        let wires = try encryptFrames(pair, count: target + 1)

        let pt = try deliver(pair, wires[target])
        XCTAssertEqual(pt, payload(target))

        let expectedLast: UInt64? = UInt64(target)
        let expectedNext: UInt64 = UInt64(target + 1)
        let expectedOldest: UInt64? = UInt64(evictedCount)
        let expectedNewest: UInt64? = UInt64(target - 1)
        let recv = try XCTUnwrap(pair.bobState.recvChain(for: "alice"))
        XCTAssertEqual(recv.lastSeenIdx, expectedLast)
        XCTAssertEqual(recv.nextIdx, expectedNext)
        XCTAssertEqual(recv.skipped.count, cap)
        let firstIdx: UInt64? = recv.skipped.first?.0
        let lastIdx: UInt64? = recv.skipped.last?.0
        XCTAssertEqual(firstIdx, expectedOldest)
        XCTAssertEqual(lastIdx, expectedNewest)
        XCTAssertEqual(recv.ck, chainKey(pair.ck0, at: target + 1))

        // The newest evicted entry is gone for good ...
        XCTAssertThrowsError(try deliver(pair, wires[evictedCount - 1]))
        XCTAssertEqual(recv.skipped.count, cap)

        // ... and the oldest surviving entry is still deliverable late.
        let late = try deliver(pair, wires[evictedCount])
        XCTAssertEqual(late, payload(evictedCount))
        XCTAssertEqual(recv.skipped.count, cap - 1)
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
