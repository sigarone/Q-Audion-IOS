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
}
