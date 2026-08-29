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

    // W-DCHANGUP (2026-08-25) — RX support shipped with this tag (control-mux
    // peek → same teardown as call_hangup), so advertising it is honest; the
    // string must stay byte-identical to Android's `DC_HANGUP_V1`.
    func test_LOCAL_containsDcHangupV1() {
        XCTAssertEqual(CallCapabilities.dcHangupV1, "dc-hangup-v1")
        XCTAssertTrue(CallCapabilities.local.contains(CallCapabilities.dcHangupV1))
    }

    // W-RESTARTICEREQ (2026-08-29) — RX support shipped with this tag (the
    // `restart_ice_request` handler runs a real full ICE restart), so
    // advertising it is honest. The string must stay byte-identical to
    // Android's `RESTART_ICE_REQUEST_V1`: this is compared with plain string
    // equality on both platforms, and a mismatch here is exactly the silent
    // interop failure that left every iOS<->Android handoff pinned to the
    // relay (call fa7d0ee5, 2026-08-29 — Android logged
    // `useRestartIceRequest=false` and could never ask).
    func test_LOCAL_containsRestartIceReqV1() {
        XCTAssertEqual(CallCapabilities.restartIceReqV1, "restart-ice-req-v1")
        XCTAssertTrue(CallCapabilities.local.contains(CallCapabilities.restartIceReqV1))
    }

    /// The tag is transport recovery, unrelated to key custody: an earbud or
    /// sovereign-only call must keep it, unlike the audio/video tags those
    /// gates deliberately strip.
    func test_restartIceReqV1_survivesEarbudAndSovereignGates() {
        let earbud = CallCapabilities.localCaps(earbudActive: true, sovereignOnly: true,
                                                earbudPaired: true)
        XCTAssertTrue(earbud.contains(CallCapabilities.restartIceReqV1))
    }

    /// Send is gated on the intersection; receiving is not. A peer that does
    /// not advertise it must resolve `useRestartIceRequest == false` so we
    /// never send into the void.
    func test_useRestartIceRequest_requiresBothSides() {
        let both = CallCapabilities.negotiate(peer: [CallCapabilities.restartIceReqV1])
        XCTAssertTrue(both.useRestartIceRequest)
        let legacy = CallCapabilities.negotiate(peer: ["sframe-v1"])
        XCTAssertFalse(legacy.useRestartIceRequest)
        let none = CallCapabilities.negotiate(peer: nil)
        XCTAssertFalse(none.useRestartIceRequest)
    }
}
