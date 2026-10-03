import XCTest
@testable import QAudionEngine

/// iPhone 1.0.1205, group call 190cb052: camera on, `Failed to initialize the encoder ... VP8.
/// Error: -15` and `frames=0` on every heartbeat. -15 is libvpx refusing a simulcast set whose
/// layers differ in `maxFramerate` (the ladder was 15 / 20 / 25 fps). These tests pin the
/// invariants libvpx needs from the ladder.
final class GroupSimulcastLadderTests: XCTestCase {

    func testEveryLayerHasTheSameFrameRate() {
        let rates = Set(GroupSimulcastLadder.layers.map(\.fps))
        XCTAssertEqual(rates, [GroupSimulcastLadder.fps], "libvpx refuses simulcast layers with different maxFramerate (-15)")
    }

    func testEveryLayerHasTheSameNumberOfTemporalLayers() {
        let counts = Set(GroupSimulcastLadder.layers.map(\.temporalLayers))
        XCTAssertEqual(counts, [GroupSimulcastLadder.temporalLayers])
    }

    func testTheShippedLadderIsAcceptedByLibvpx() {
        XCTAssertTrue(GroupSimulcastLadder.isAcceptedByLibvpx(GroupSimulcastLadder.layers))
    }

    /// The ladder that failed on the iPhone must be recognised as the invalid one it is.
    func testTheOldPerLayerRateLadderIsRefused() {
        let old = [
            GroupSimulcastLadder.Layer(rid: "l", scale: 4, fps: 15, maxBps: 150_000, temporalLayers: 3),
            GroupSimulcastLadder.Layer(rid: "m", scale: 2, fps: 20, maxBps: 450_000, temporalLayers: 3),
            GroupSimulcastLadder.Layer(rid: "h", scale: 1, fps: 25, maxBps: 1_200_000, temporalLayers: 3),
        ]
        XCTAssertFalse(GroupSimulcastLadder.isAcceptedByLibvpx(old))
    }

    func testMixedTemporalLayersOrGrowingScaleOrNoLayersAreRefused() {
        var mixed = GroupSimulcastLadder.layers
        mixed[1] = GroupSimulcastLadder.Layer(rid: "m", scale: 2, fps: 25, maxBps: 450_000, temporalLayers: 2)
        XCTAssertFalse(GroupSimulcastLadder.isAcceptedByLibvpx(mixed))
        XCTAssertFalse(GroupSimulcastLadder.isAcceptedByLibvpx(Array(GroupSimulcastLadder.layers.reversed())),
                       "the downscale must not grow from a layer to the next")
        XCTAssertFalse(GroupSimulcastLadder.isAcceptedByLibvpx([]))
    }

    /// The bitrate / resolution ladder itself is unchanged: l, m, h ascending (the `rid_order` Janus gets is "lmh").
    func testTheLadderKeepsItsRidsScalesAndBitrates() {
        XCTAssertEqual(GroupSimulcastLadder.layers.map(\.rid), ["l", "m", "h"])
        XCTAssertEqual(GroupSimulcastLadder.layers.map(\.scale), [4, 2, 1])
        XCTAssertEqual(GroupSimulcastLadder.layers.map(\.maxBps), [150_000, 450_000, 1_200_000])
    }
}
