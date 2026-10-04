import XCTest
@testable import QAudionEngine

/// MEDIA-5 (W-INNERAUDIOAAD) — the inner sealed-audio replay window as the ENGINE drives it:
/// read-only check BEFORE the AEAD open, commit ONLY AFTER the open succeeded (RFC 3711 order).
///
/// Everything goes through `initSession(..., adaptivePadding: true, innerAudioAadV1: true)` and the
/// real `processOutgoingAudio` / `processIncomingAudio` of two engines (role A and role B), so a
/// forged or replayed frame meets the same code a live call does. `QAudionCallIntegration` keeps
/// the capability OFF (`innerAudioAadV1Enabled = false`); this file is about the core being
/// correct before anyone turns it on.
final class InnerAudioReplayEngineTests: XCTestCase {

    private let secret1 = Data(repeating: 0x37, count: 32)
    private let secret2 = Data(repeating: 0x5A, count: 32)
    private let callId = "call-replay-tests"

    private var oneFrame: Data { Data(count: AudioProfile.defaultProfile.bytesPerFrame) }

    private func install(
        _ e: QAudionEngine, roleA: Bool, secret: Data, epoch: UInt32, innerAad: Bool = true
    ) throws {
        try e.initSession(
            sharedSecret: secret, adaptivePadding: true,
            innerAudioAadV1: innerAad, callId: callId,
            selfIsRoleA: roleA, epoch: epoch
        )
    }

    private func makeEngine(
        roleA: Bool, secret: Data? = nil, epoch: UInt32 = 1, innerAad: Bool = true
    ) throws -> QAudionEngine {
        let e = QAudionEngine(config: .development())
        try e.initialize()
        try install(e, roleA: roleA, secret: secret ?? secret1, epoch: epoch, innerAad: innerAad)
        return e
    }

    /// Role A sender + role B receiver, epoch 1.
    private func makePair() throws -> (a: QAudionEngine, b: QAudionEngine) {
        (try makeEngine(roleA: true), try makeEngine(roleA: false))
    }

    private func seal(_ e: QAudionEngine, _ count: Int = 1) throws -> [Data] {
        try (0..<count).map { _ in try e.processOutgoingAudio(pcmFrame: oneFrame) }
    }

    private func wireSeq(_ wire: Data) throws -> UInt32 {
        try FrameEncoder.deserialize(wire).sequenceNumber
    }

    /// The same sealed frame, claiming another wire seq. The tag does not cover that, so the
    /// receiver's AEAD open must fail (seq is bound in the AAD).
    private func reseq(_ wire: Data, to seq: UInt32) throws -> Data {
        let f = try FrameEncoder.deserialize(wire)
        return FrameEncoder.serialize(EncryptedFrame(
            sequenceNumber: seq, timestamp: f.timestamp, nonce: f.nonce, payload: f.payload, tag: f.tag))
    }

    /// The same frame with one tag byte flipped: same seq, fails authentication.
    private func corruptTag(_ wire: Data) throws -> Data {
        let f = try FrameEncoder.deserialize(wire)
        var tag = f.tag
        tag[tag.startIndex] ^= 0xFF
        return FrameEncoder.serialize(EncryptedFrame(
            sequenceNumber: f.sequenceNumber, timestamp: f.timestamp, nonce: f.nonce, payload: f.payload, tag: tag))
    }

    private func assertRejectedAsReplay(
        _ e: QAudionEngine, _ wire: Data, tooOld: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try e.processIncomingAudio(serializedFrame: wire), file: file, line: line) { error in
            guard case QAudionEngineError.replayedFrame(_, let old) = error else {
                return XCTFail("expected a replay rejection, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(old, tooOld, "tooOld flag", file: file, line: line)
        }
    }

    private func assertRejectedAsAuthFailure(
        _ e: QAudionEngine, _ wire: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try e.processIncomingAudio(serializedFrame: wire), file: file, line: line) { error in
            if case QAudionEngineError.replayedFrame = error {
                XCTFail("an unauthenticated frame must fail authentication, not read as a replay", file: file, line: line)
            }
        }
    }

    // MARK: - D1: every accepted frame stays protected, not only the highest

    func test_replayOfEveryAcceptedFrameIsRejected_notJustTheHighest() throws {
        let (a, b) = try makePair()
        let wires = try seal(a, 6)
        for w in wires { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: w)) }
        for w in wires { assertRejectedAsReplay(b, w) }
    }

    func test_replayInsideTheWindowAfterTheHighestJumped1000() throws {
        let (a, b) = try makePair()
        let first = try seal(a)[0]
        a.txSeqAdaptive = 1000
        let far = try seal(a)[0]
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: first))
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: far))
        assertRejectedAsReplay(b, first)
        assertRejectedAsReplay(b, far)
    }

    func test_outOfOrderGenuineFramesAreAcceptedOnceEach() throws {
        let (a, b) = try makePair()
        let wires = try seal(a, 8)
        for i in [7, 3, 5, 0, 6, 1, 4, 2] {
            XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wires[i]), "frame \(i)")
        }
        for w in wires { assertRejectedAsReplay(b, w) }
    }

    func test_aFrameOlderThanTheWindowIsRejectedAsStale_andTheBoundaryFrameIsNot() throws {
        let (a, b) = try makePair()
        let oldest = try seal(a)[0]          // seq 0
        let boundary = try seal(a)[0]        // seq 1
        a.txSeqAdaptive = 1024
        let top = try seal(a)[0]             // seq 1024: seq 0 is now 1024 behind, seq 1 is 1023 behind
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: top))
        assertRejectedAsReplay(b, oldest, tooOld: true)
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: boundary))
    }

    // MARK: - D2: the window only moves for authenticated frames

    func test_aForgedFarAheadFrameIsRejectedAndDoesNotPoisonTheWindow() throws {
        let (a, b) = try makePair()
        let wires = try seal(a, 10)
        for i in 0..<3 { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wires[i])) }
        // A genuine ciphertext relabelled with a seq 5 million ahead: AEAD must fail.
        let forged = try reseq(wires[3], to: 5_000_000)
        assertRejectedAsAuthFailure(b, forged)
        // The genuine stream keeps decoding. If the forged seq had been recorded, every one of
        // these would be "too old".
        for i in 3..<10 { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wires[i]), "frame \(i)") }
    }

    func test_theFirstFrameAfterInstallDoesNotInitialiseTheWindowUnlessItAuthenticates() throws {
        let (a, b) = try makePair()
        let wires = try seal(a, 3)
        // Nothing accepted yet on b: the forged frame would be the one to initialise the window.
        assertRejectedAsAuthFailure(b, try reseq(wires[0], to: 9_000_000))
        for w in wires { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: w)) }
    }

    func test_aFrameThatFailsAeadDoesNotBurnItsSeq() throws {
        let (a, b) = try makePair()
        let wires = try seal(a, 3)
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wires[0]))
        assertRejectedAsAuthFailure(b, try corruptTag(wires[1]))
        // The genuine copy of the same seq is still accepted ...
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wires[1]))
        // ... exactly once.
        assertRejectedAsReplay(b, wires[1])
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wires[2]))
    }

    func test_aReplayIsRejectedBeforeAnyAeadWork_soEvenACorruptedCopyReadsAsAReplay() throws {
        let (a, b) = try makePair()
        let wires = try seal(a, 2)
        for w in wires { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: w)) }
        // Seq 0 was accepted; a copy of it with a broken tag never reaches the AEAD open.
        assertRejectedAsReplay(b, try corruptTag(wires[0]))
    }

    // MARK: - Re-key / epoch

    func test_rekey_anOldEpochFrameDoesNotPoisonTheNewEpoch_andTheCounterRestarts() throws {
        let (a, b) = try makePair()
        // Epoch 1: A sends a frame with a high seq.
        let early = try seal(a)[0]
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: early))
        a.txSeqAdaptive = 5000
        let oldEpoch = try seal(a)[0]
        XCTAssertEqual(try wireSeq(oldEpoch), 5000)

        // The responder (b) installs the new round first; a is still sending epoch-1 frames.
        try install(b, roleA: false, secret: secret2, epoch: 2)
        assertRejectedAsAuthFailure(b, oldEpoch)

        // a installs the same round: its counter restarts at 0.
        try install(a, roleA: true, secret: secret2, epoch: 2)
        let fresh = try seal(a, 3)
        XCTAssertEqual(try wireSeq(fresh[0]), 0)
        // The old frame's seq (5000) must not have been recorded: seq 0, 1, 2 decode, including
        // seq 0, which epoch 1 had already used.
        for w in fresh { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: w)) }
        for w in fresh { assertRejectedAsReplay(b, w) }
    }

    func test_rekey_aFrameAcceptedInTheOldEpochIsNotAReplayInTheNewOne() throws {
        let (a, b) = try makePair()
        let old = try seal(a, 2)
        for w in old { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: w)) }
        try install(a, roleA: true, secret: secret2, epoch: 2)
        try install(b, roleA: false, secret: secret2, epoch: 2)
        let new = try seal(a, 2)   // seq 0 and 1 again
        for w in new { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: w)) }
    }

    // MARK: - D3: TX and RX bind the same seq

    func test_txAndRxBindTheSameSeqAcrossTheUInt32Edge_andTxRefusesInsteadOfWrapping() throws {
        let (a, b) = try makePair()
        a.txSeqAdaptive = UInt64(UInt32.max) - 2
        let last3 = try seal(a, 3)
        XCTAssertEqual(try wireSeq(last3[0]), UInt32.max - 2)
        XCTAssertEqual(try wireSeq(last3[2]), UInt32.max)
        // Same seq in the AAD on both sides: all three open.
        for w in last3 { XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: w)) }
        // The next counter value does not fit the wire seq: refuse, every time, no wrap.
        for _ in 0..<2 {
            XCTAssertThrowsError(try a.processOutgoingAudio(pcmFrame: oneFrame)) { error in
                guard case QAudionEngineError.txSequenceExhausted = error else {
                    return XCTFail("expected txSequenceExhausted, got \(error)")
                }
            }
        }
        // A new session restarts the counter and sending works again.
        try install(a, roleA: true, secret: secret2, epoch: 2)
        XCTAssertEqual(try wireSeq(try seal(a)[0]), 0)
    }

    func test_legacyPathKeepsTruncatingTheWireSeq() throws {
        let a = try makeEngine(roleA: true, innerAad: false)
        let b = try makeEngine(roleA: false, innerAad: false)
        a.txSeqAdaptive = UInt64(UInt32.max) + 1
        let wire = try seal(a)[0]
        XCTAssertEqual(try wireSeq(wire), 0)
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wire))
    }

    // MARK: - D5: release and error classification

    func test_releaseDropsTheDirectionalKeysLikeDestroySessionDoes() throws {
        let released = try makeEngine(roleA: true)
        XCTAssertTrue(released.innerAudioAadKeyMaterialHeld)
        released.release()
        XCTAssertFalse(released.innerAudioAadKeyMaterialHeld)

        let destroyed = try makeEngine(roleA: true)
        destroyed.destroySession()
        XCTAssertFalse(destroyed.innerAudioAadKeyMaterialHeld)
    }

    func test_aReplayRejectionIsDistinctFromAnAeadFailureButCountedAsBefore() throws {
        let (a, b) = try makePair()
        let wire = try seal(a)[0]
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wire))
        var replayError: Error?
        XCTAssertThrowsError(try b.processIncomingAudio(serializedFrame: wire)) { replayError = $0 }
        guard let thrown = replayError else { return XCTFail("no error thrown") }
        guard case QAudionEngineError.replayedFrame(let seq, let tooOld) = thrown else {
            return XCTFail("expected replayedFrame, got \(thrown)")
        }
        XCTAssertEqual(seq, 0)
        XCTAssertFalse(tooOld)
        // Callers keep counting it the way they always did.
        XCTAssertEqual(RxDecodeFailureKind.classify(thrown), .decrypt)
    }
}
