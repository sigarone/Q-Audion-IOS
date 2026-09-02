import XCTest
@testable import QAudionEngine

/// MEDIA-3/MEDIA-4/MEDIA-5 (2026-09-02 protocol audit, backlog item 4) —
/// per-direction keys + AAD + replay window on the "inner sealed-audio wire"
/// (`QAudionEngine`'s `adaptivePadding` branch, the Android-JSON-bundle
/// interop path). These tests exercise `QAudionEngine.initSession`'s
/// `innerAudioAadV1`/`callId`/`selfIsRoleA`/`epoch` parameters directly —
/// the capability negotiation that decides WHETHER to pass `true` lives one
/// layer up in `QAudionCallIntegration` (see
/// `QAudionCallIntegration.innerAudioAadV1Enabled`, default false) and is
/// not exercised here; this file is about the crypto core being correct
/// once negotiated, and byte-identical to today when it is not.
final class InnerAudioAadV1Tests: XCTestCase {

    private let secret = Data(repeating: 0x37, count: 32)
    private let callIdA = "11111111-2222-3333-4444-555555555555"

    private func adaptiveEngine(
        innerAudioAadV1: Bool,
        callId: String = "",
        selfIsRoleA: Bool = false,
        epoch: UInt32 = 1
    ) throws -> QAudionEngine {
        let e = QAudionEngine(config: .development())
        try e.initialize()
        try e.initSession(
            sharedSecret: secret, adaptivePadding: true,
            innerAudioAadV1: innerAudioAadV1, callId: callId,
            selfIsRoleA: selfIsRoleA, epoch: epoch
        )
        return e
    }

    private var oneFrame: Data { Data(count: AudioProfile.defaultProfile.bytesPerFrame) }

    // MARK: - Legacy (bit not negotiated) — byte-identical to today

    /// With `innerAudioAadV1: false` (the default), two engines sharing only
    /// `sessionKey` — no role, no callId — still round-trip, exactly the
    /// pre-existing static-key/no-AAD behaviour. Locks in that the new
    /// plumbing is genuinely opt-in.
    func test_legacyPath_roundTripsWithNoRoleOrCallId() throws {
        let tx = try adaptiveEngine(innerAudioAadV1: false)
        let rx = try adaptiveEngine(innerAudioAadV1: false)
        let wire = try tx.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertNoThrow(try rx.processIncomingAudio(serializedFrame: wire))
    }

    // MARK: - Negotiated: directional keys actually decrypt each other

    /// Role A's sender and role B's receiver must be the SAME channel (A
    /// sends with k_a2b, B receives with k_a2b) — this is the core
    /// per-direction-key contract MEDIA-3 asks for.
    func test_negotiated_roleASendsRoleBReceives() throws {
        let a = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: true, epoch: 1)
        let b = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: false, epoch: 1)
        let wire = try a.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wire))
    }

    /// And the mirror direction: B sends (k_b2a), A receives (k_b2a).
    func test_negotiated_roleBSendsRoleAReceives() throws {
        let a = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: true, epoch: 1)
        let b = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: false, epoch: 1)
        let wire = try b.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertNoThrow(try a.processIncomingAudio(serializedFrame: wire))
    }

    /// MEDIA-3's whole point: A's own TX and A's own RX must NOT be the same
    /// key (that was the original bug — one shared key both directions).
    /// Feeding A's outbound frame back into A itself (as if it were an echo
    /// of its own traffic) must fail — A's "receive" key is k_b2a, not the
    /// k_a2b it just sealed with.
    func test_negotiated_senderCannotOpenItsOwnFrameWithItsOwnRecvKey() throws {
        let a = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: true, epoch: 1)
        let wire = try a.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertThrowsError(try a.processIncomingAudio(serializedFrame: wire))
    }

    // MARK: - AAD actually binds callId (MEDIA-4)

    /// Two peers that agree on keys/roles but NOT on callId must fail to
    /// decrypt each other — proves the AAD is bound into the AEAD call
    /// (not just computed and discarded).
    func test_negotiated_mismatchedCallIdFailsAad() throws {
        let a = try adaptiveEngine(innerAudioAadV1: true, callId: "call-A", selfIsRoleA: true, epoch: 1)
        let b = try adaptiveEngine(innerAudioAadV1: true, callId: "call-B", selfIsRoleA: false, epoch: 1)
        let wire = try a.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertThrowsError(try b.processIncomingAudio(serializedFrame: wire))
    }

    /// Same for epoch — a re-key round's frames must not be openable under
    /// the previous round's AAD expectation.
    func test_negotiated_mismatchedEpochFailsAad() throws {
        let a = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: true, epoch: 2)
        let b = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: false, epoch: 1)
        let wire = try a.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertThrowsError(try b.processIncomingAudio(serializedFrame: wire))
    }

    // MARK: - Replay window (MEDIA-5)

    /// A frame opened once cannot be opened again — the defining property
    /// of the new replay window.
    func test_negotiated_replayedFrameIsRejectedSecondTime() throws {
        let a = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: true, epoch: 1)
        let b = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: false, epoch: 1)
        let wire = try a.processOutgoingAudio(pcmFrame: oneFrame)
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wire))
        XCTAssertThrowsError(try b.processIncomingAudio(serializedFrame: wire),
                              "a replayed frame must be rejected the second time")
    }

    /// Reordered-but-fresh frames within the window are still accepted —
    /// the window tolerates real network reordering, it does not require
    /// strict in-order delivery.
    func test_negotiated_outOfOrderWithinWindowStillAccepted() throws {
        let a = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: true, epoch: 1)
        let b = try adaptiveEngine(innerAudioAadV1: true, callId: callIdA, selfIsRoleA: false, epoch: 1)
        let wire0 = try a.processOutgoingAudio(pcmFrame: oneFrame)
        let wire1 = try a.processOutgoingAudio(pcmFrame: oneFrame)
        // Frame 1 arrives before frame 0 (reordered, not replayed).
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wire1))
        XCTAssertNoThrow(try b.processIncomingAudio(serializedFrame: wire0))
    }
}
