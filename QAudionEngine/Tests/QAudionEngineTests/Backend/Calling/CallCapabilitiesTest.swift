import XCTest
@testable import QAudionEngine

/// Cross-platform parity tests for the SFrame capability handshake.
/// Mirrors Kotlin `feature/feature-call/.../CallCapabilitiesTest.kt`
/// case-for-case so any divergence between Android & iOS shows up
/// immediately in CI on the side that drifted.
final class CallCapabilitiesTest: XCTestCase {

    func test_useSFrame_trueWhenBothSidesAdvertiseSFrameV1() {
        let n = CallCapabilities.negotiate(
            local: [CallCapabilities.sframeV1],
            peer: [CallCapabilities.sframeV1]
        )
        XCTAssertTrue(n.useSFrame)
        XCTAssertEqual(n.agreedTags, [CallCapabilities.sframeV1])
    }

    func test_legacyPeer_nilCapabilities_downgrades() {
        let n = CallCapabilities.negotiate(local: CallCapabilities.local, peer: nil)
        XCTAssertFalse(n.useSFrame)
        XCTAssertTrue(n.agreedTags.isEmpty)
    }

    func test_legacyPeer_emptyCapabilities_downgrades() {
        let n = CallCapabilities.negotiate(local: CallCapabilities.local, peer: [])
        XCTAssertFalse(n.useSFrame)
        XCTAssertTrue(n.agreedTags.isEmpty)
    }

    func test_peerWithUnrelatedCaps_downgrades() {
        let n = CallCapabilities.negotiate(
            local: CallCapabilities.local,
            peer: ["foo-v1", "bar-v9"]
        )
        XCTAssertFalse(n.useSFrame)
        XCTAssertTrue(n.agreedTags.isEmpty)
    }

    func test_intersection_skipsLocalOnlyTags() {
        let n = CallCapabilities.negotiate(
            local: [CallCapabilities.sframeV1, "future-cap-v2"],
            peer: [CallCapabilities.sframeV1]
        )
        XCTAssertTrue(n.useSFrame)
        XCTAssertEqual(n.agreedTags, [CallCapabilities.sframeV1])
    }

    func test_agreedTags_areDeduplicatedAndSorted() {
        let n = CallCapabilities.negotiate(
            local: ["alpha", CallCapabilities.sframeV1, "alpha"],
            peer: [CallCapabilities.sframeV1, "alpha", "alpha"]
        )
        // Kotlin: listOf(SFRAME_V1, "alpha").sorted() → ["alpha", "sframe-v1"]
        XCTAssertEqual(n.agreedTags, ["alpha", CallCapabilities.sframeV1].sorted())
        XCTAssertTrue(n.useSFrame)
    }

    func test_LOCAL_containsSFrameV1() {
        XCTAssertTrue(CallCapabilities.local.contains(CallCapabilities.sframeV1))
    }

    // ── ratchet-v3 parity tests (mirrors Kotlin CallCapabilitiesTest) ──

    func test_useRatchetV3_trueWhenBothSidesAdvertiseRatchetV3() {
        let n = CallCapabilities.negotiate(
            local: CallCapabilities.local,
            peer: [CallCapabilities.sframeV1, CallCapabilities.ratchetV3]
        )
        XCTAssertTrue(n.useRatchetV3)
    }

    func test_useRatchetV3_falseWhenOnlyPeerAdvertisesAndLocalDoesNot() {
        let n = CallCapabilities.negotiate(
            local: [CallCapabilities.sframeV1], // no ratchetV3
            peer: [CallCapabilities.sframeV1, CallCapabilities.ratchetV3]
        )
        XCTAssertFalse(n.useRatchetV3)
    }

    func test_useRatchetV3_falseWhenPeerIsLegacyNil() {
        let n = CallCapabilities.negotiate(local: CallCapabilities.local, peer: nil)
        XCTAssertFalse(n.useRatchetV3)
    }

    func test_LOCAL_containsRatchetV3() {
        XCTAssertTrue(CallCapabilities.local.contains(CallCapabilities.ratchetV3))
    }

    // W-ICEBATCH (2026-08-25) — RX support shipped with this tag, so
    // advertising it is honest; the string must stay byte-identical to
    // Android's `ICE_BATCH_V1`.
    func test_LOCAL_containsIceBatchV1() {
        XCTAssertEqual(CallCapabilities.iceBatchV1, "ice-batch-v1")
        XCTAssertTrue(CallCapabilities.local.contains(CallCapabilities.iceBatchV1))
    }
}
