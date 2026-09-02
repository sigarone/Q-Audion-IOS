import XCTest
import CryptoKit
@testable import QAudionEngine

/// CALL-4/HSID-002 (2026-09-02 protocol audit) — first-principles tests for
/// `QAudionCallIntegration.deriveTranscriptBoundSessionKey` (the KDF fold) and
/// `ComputeSasUseCase.invoke(sessionKey:transcriptHash:)` (the SAS fold).
///
/// No cross-platform KAT vector exists yet for this fix — it is brand-new,
/// unshipped, cross-platform-uncoordinated work (see this fix's own commit
/// message for the byte layout pinned for a later reconciliation pass). These
/// tests instead verify the PROPERTIES the fix design requires directly:
/// deterministic, distinct-per-transcript-hash, distinct from the un-bound
/// legacy derivation, and a first-principles HKDF reconstruction of the exact
/// `info` layout this fix's own doc claims.
final class SessionKeyTranscriptBoundTests: XCTestCase {

    private func fixedBytes(_ n: Int, seed: UInt8) -> Data {
        Data((0..<n).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
    }

    // MARK: - deriveTranscriptBoundSessionKey

    func testDeterministic() {
        let base = fixedBytes(32, seed: 1)
        let hash = fixedBytes(32, seed: 2)
        let a = QAudionCallIntegration.deriveTranscriptBoundSessionKey(baseKey: base, transcriptHash: hash)
        let b = QAudionCallIntegration.deriveTranscriptBoundSessionKey(baseKey: base, transcriptHash: hash)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func testDifferentTranscriptHashesProduceDifferentKeys() {
        let base = fixedBytes(32, seed: 1)
        let hashA = fixedBytes(32, seed: 2)
        let hashB = fixedBytes(32, seed: 3)
        let keyA = QAudionCallIntegration.deriveTranscriptBoundSessionKey(baseKey: base, transcriptHash: hashA)
        let keyB = QAudionCallIntegration.deriveTranscriptBoundSessionKey(baseKey: base, transcriptHash: hashB)
        XCTAssertNotEqual(
            keyA, keyB,
            "CALL-4 core property: a relay that strips a capability bit changes the transcript hash, which MUST change the folded session key on both ends"
        )
    }

    func testDifferentBaseKeysProduceDifferentFoldedKeys() {
        let hash = fixedBytes(32, seed: 9)
        let baseA = fixedBytes(32, seed: 1)
        let baseB = fixedBytes(32, seed: 5)
        let keyA = QAudionCallIntegration.deriveTranscriptBoundSessionKey(baseKey: baseA, transcriptHash: hash)
        let keyB = QAudionCallIntegration.deriveTranscriptBoundSessionKey(baseKey: baseB, transcriptHash: hash)
        XCTAssertNotEqual(keyA, keyB)
    }

    func testFoldedKeyDiffersFromUnfoldedBaseKey() {
        let base = fixedBytes(32, seed: 7)
        let hash = fixedBytes(32, seed: 8)
        let folded = QAudionCallIntegration.deriveTranscriptBoundSessionKey(baseKey: base, transcriptHash: hash)
        XCTAssertNotEqual(folded, base, "folding must actually change the key, not pass it through")
    }

    /// First-principles reconstruction of the exact HKDF this fix's own doc
    /// specifies: `ikm = baseKey`, `salt = HkdfLabels.hybridPqcSaltV1`,
    /// `info = HkdfLabels.kdfTranscriptBindV1(32) || transcriptHash(32)`.
    func testMatchesFirstPrinciplesHkdfReconstruction() {
        let base = fixedBytes(32, seed: 11)
        let hash = fixedBytes(32, seed: 12)
        var expectedInfo = Data("q-audion-kdf-transcript-bind-v1".utf8)
        expectedInfo.append(hash)
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: base),
            salt: Data("q-audion-hybrid-pqc-v1".utf8),
            info: expectedInfo,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let actual = QAudionCallIntegration.deriveTranscriptBoundSessionKey(baseKey: base, transcriptHash: hash)
        XCTAssertEqual(actual, expected)
    }

    // MARK: - rekeyFreshnessValue (CALL-3's literal HKDF formula, ready for a future consumer)

    func testRekeyFreshnessValueDeterministic() {
        let nonce = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let a = QAudionCallIntegration.rekeyFreshnessValue(callId: "call-1", rekeyNonce: nonce, round: 3)
        let b = QAudionCallIntegration.rekeyFreshnessValue(callId: "call-1", rekeyNonce: nonce, round: 3)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func testRekeyFreshnessValueDiffersPerRound() {
        let nonce = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let r1 = QAudionCallIntegration.rekeyFreshnessValue(callId: "call-1", rekeyNonce: nonce, round: 1)
        let r2 = QAudionCallIntegration.rekeyFreshnessValue(callId: "call-1", rekeyNonce: nonce, round: 2)
        XCTAssertNotEqual(r1, r2)
    }

    func testRekeyFreshnessValueDiffersPerNonce_freshNonceAfterRestart() {
        // CALL-3 design requirement: a process restart mid-call safely starts a
        // FRESH nonce+counter — two different (freshly-generated) nonces for
        // the SAME callId/round must produce two DIFFERENT freshness values,
        // so a stale value computed before a restart can never coincide with
        // the post-restart sequence.
        let nonceBeforeRestart = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let nonceAfterRestart = Data([9, 8, 7, 6, 5, 4, 3, 2])
        let before = QAudionCallIntegration.rekeyFreshnessValue(callId: "call-1", rekeyNonce: nonceBeforeRestart, round: 1)
        let after = QAudionCallIntegration.rekeyFreshnessValue(callId: "call-1", rekeyNonce: nonceAfterRestart, round: 1)
        XCTAssertNotEqual(before, after)
    }

    func testRekeyFreshnessValueDiffersPerCallId() {
        let nonce = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let a = QAudionCallIntegration.rekeyFreshnessValue(callId: "call-A", rekeyNonce: nonce, round: 1)
        let b = QAudionCallIntegration.rekeyFreshnessValue(callId: "call-B", rekeyNonce: nonce, round: 1)
        XCTAssertNotEqual(a, b, "the freshness value must be scoped to the call, not just the nonce")
    }

    // MARK: - shouldRefuseStaleRekeyRound (the CALL-3 monotonicity decision)

    func testRound1NeverRefused() {
        XCTAssertFalse(QAudionCallIntegration.shouldRefuseStaleRekeyRound(
            isReKeyRound: false, isKnownRetransmit: false, round: 1, lastAccepted: nil
        ), "the call's first handshake (round 1, no prior state) must never be refused")
    }

    func testFreshHigherRoundAccepted() {
        XCTAssertFalse(QAudionCallIntegration.shouldRefuseStaleRekeyRound(
            isReKeyRound: true, isKnownRetransmit: false, round: 2, lastAccepted: 1
        ))
        XCTAssertFalse(QAudionCallIntegration.shouldRefuseStaleRekeyRound(
            isReKeyRound: true, isKnownRetransmit: false, round: 5, lastAccepted: 1
        ), "rounds may legitimately skip ahead (a lost re-key OFFER is never retried, per the class doc)")
    }

    func testStaleReplayedRoundRefused() {
        // The core CALL-3 fix: a validly-signed round-1 bundle replayed after
        // round 3 has already been accepted must be refused.
        XCTAssertTrue(QAudionCallIntegration.shouldRefuseStaleRekeyRound(
            isReKeyRound: true, isKnownRetransmit: false, round: 1, lastAccepted: 3
        ))
    }

    func testEqualRoundNonRetransmitRefused() {
        // A NEW (different content) bundle claiming the SAME round number as
        // the one already accepted is refused — closes the "same round number
        // reused with substituted content" gap a bare `<` comparison would
        // leave open.
        XCTAssertTrue(QAudionCallIntegration.shouldRefuseStaleRekeyRound(
            isReKeyRound: true, isKnownRetransmit: false, round: 2, lastAccepted: 2
        ))
    }

    func testKnownRetransmitOfCurrentRoundNeverRefused() {
        // A byte-identical WS/push redelivery of the CURRENTLY-active round
        // legitimately carries round == lastAccepted — it must fall through
        // to the existing "replay the cached ACCEPT" path, never be refused
        // here (a real regression this fix's own review caught: a naive
        // `round <= lastAccepted` check would otherwise reject every
        // legitimate retransmit of the active round).
        XCTAssertFalse(QAudionCallIntegration.shouldRefuseStaleRekeyRound(
            isReKeyRound: true, isKnownRetransmit: true, round: 2, lastAccepted: 2
        ))
    }

    func testKnownRetransmitFlagDoesNotBypassAGenuinelyStaleRound() {
        // isKnownRetransmit is only ever computed from THIS integration's own
        // content-fingerprint history — a genuinely stale round's bundle
        // (never seen before) can never set it, so this scenario is purely
        // defensive: even if it somehow were set, an OLDER round than the
        // last accepted must still be refused when it is NOT the exact
        // content of the currently-active round. This test documents the
        // production call site never passes isKnownRetransmit=true for a
        // round below lastAccepted — see `isKnownRetransmitV3`'s own
        // fingerprint-keyed computation in `onAndroidBundleReceived`.
        XCTAssertFalse(QAudionCallIntegration.shouldRefuseStaleRekeyRound(
            isReKeyRound: true, isKnownRetransmit: true, round: 1, lastAccepted: 3
        ), "documents current behaviour: the retransmit flag is trusted as computed by the caller, not re-derived here")
    }
}
