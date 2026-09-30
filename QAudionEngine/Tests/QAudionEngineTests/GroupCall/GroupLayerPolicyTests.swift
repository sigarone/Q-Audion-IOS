import XCTest
@testable import QAudionEngine

final class GroupLayerPolicyTests: XCTestCase {

    private let a = "feedA|1"
    private let b = "feedB|1"

    private func makePolicy(_ keys: [String]) -> GroupLayerPolicy {
        let policy = GroupLayerPolicy()
        for key in keys { policy.register(key: key) }
        return policy
    }

    private func configures(_ actions: [GroupLayerPolicy.Action]) -> [GroupLayerPolicy.Action] {
        actions.filter { if case .configure = $0 { return true } else { return false } }
    }

    // MARK: target by tile

    func testTargetSubstreamFollowsTheTileSize() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .thumbnail, visible: true)
        XCTAssertEqual(policy.evaluate(nowMs: 0), [.configure(key: a, substream: 0, temporal: 2, from: -1, reason: "subscribe")])
        policy.setTile(key: a, tile: .grid, visible: true)
        XCTAssertEqual(policy.evaluate(nowMs: 1), [.configure(key: a, substream: 1, temporal: 2, from: 0, reason: "tile")])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        XCTAssertEqual(policy.evaluate(nowMs: 2), [.configure(key: a, substream: 2, temporal: 2, from: 1, reason: "tile")])
    }

    func testNoActionWhenNothingChanged() {
        let policy = makePolicy([a])
        _ = policy.evaluate(nowMs: 0)
        XCTAssertTrue(policy.evaluate(nowMs: 500).isEmpty)
    }

    func testTemporalLayerIsAlwaysTwo() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        guard case .configure(_, _, let temporal, _, _)? = policy.evaluate(nowMs: 0).first else { return XCTFail("no configure") }
        XCTAssertEqual(temporal, 2)
    }

    // MARK: visibility

    func testOffScreenTilesAreUnsubscribedAndComeBackSubscribed() {
        let policy = makePolicy([a, b])
        _ = policy.evaluate(nowMs: 0)
        policy.setTile(key: a, tile: .grid, visible: false)
        XCTAssertEqual(policy.evaluate(nowMs: 10), [.unsubscribe(key: a)])
        XCTAssertFalse(policy.isSubscribed(key: a))
        XCTAssertTrue(policy.isSubscribed(key: b))
        policy.setTile(key: a, tile: .grid, visible: true)
        let back = policy.evaluate(nowMs: 20)
        XCTAssertEqual(back.first, .subscribe(key: a))
        XCTAssertEqual(configures(back), [.configure(key: a, substream: 1, temporal: 2, from: -1, reason: "subscribe")])
    }

    func testBackgroundUnsubscribesEveryVideoAndForegroundRestoresIt() {
        let policy = makePolicy([a, b])
        _ = policy.evaluate(nowMs: 0)
        policy.setBackgrounded(true)
        XCTAssertEqual(Set(policy.evaluate(nowMs: 5)), [.unsubscribe(key: a), .unsubscribe(key: b)])
        policy.setBackgrounded(false)
        XCTAssertEqual(Set(policy.evaluate(nowMs: 10).filter { if case .subscribe = $0 { return true } else { return false } }),
                       [.subscribe(key: a), .subscribe(key: b)])
    }

    // MARK: step down

    func testSlowlinkStepsDownOneSubstreamImmediately() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)                     // substream 2
        policy.onSlowlink(nowMs: 1_000)
        XCTAssertEqual(policy.evaluate(nowMs: 1_000), [.configure(key: a, substream: 1, temporal: 2, from: 2, reason: "slowlink")])
    }

    func testLossAboveFivePercentOverTwoSecondsStepsDown() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onLossSample(key: a, packetsLostDelta: 4, packetsReceivedDelta: 46, nowMs: 1_000)   // 8 % but one sample
        XCTAssertEqual(policy.currentSubstream(key: a), 2, "commanded state only changes at evaluate")
        XCTAssertEqual(policy.evaluate(nowMs: 1_000), [.configure(key: a, substream: 1, temporal: 2, from: 2, reason: "loss")])
    }

    func testLossAtOrBelowFivePercentIsIgnored() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onLossSample(key: a, packetsLostDelta: 5, packetsReceivedDelta: 95, nowMs: 1_000)   // exactly 5 %
        policy.onLossSample(key: a, packetsLostDelta: 0, packetsReceivedDelta: 100, nowMs: 2_000)
        XCTAssertTrue(policy.evaluate(nowMs: 2_000).isEmpty)
    }

    func testTooFewPacketsDoNotJudgeLoss() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onLossSample(key: a, packetsLostDelta: 5, packetsReceivedDelta: 5, nowMs: 1_000)     // 50 % of 10 packets
        XCTAssertTrue(policy.evaluate(nowMs: 1_000).isEmpty)
    }

    func testOldLossSamplesLeaveTheWindow() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onLossSample(key: a, packetsLostDelta: 1, packetsReceivedDelta: 30, nowMs: 1_000)    // 3 %
        policy.onLossSample(key: a, packetsLostDelta: 0, packetsReceivedDelta: 30, nowMs: 5_000)    // first sample aged out
        XCTAssertTrue(policy.evaluate(nowMs: 5_000).isEmpty)
    }

    func testTheLowestSubstreamNeverGoesBelowZero() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .thumbnail, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onSlowlink(nowMs: 100)
        XCTAssertTrue(policy.evaluate(nowMs: 100).isEmpty)
        XCTAssertEqual(policy.currentSubstream(key: a), 0)
    }

    func testBandwidthBelowOnePointTwoTimesTheCurrentLayersStepsTheHighestStreamDown() {
        let policy = makePolicy([a, b])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        policy.setTile(key: b, tile: .grid, visible: true)
        _ = policy.evaluate(nowMs: 0)                    // a: h (1.2 Mbps), b: m (450 kbps)
        policy.onBandwidthSample(availableBps: 1_500_000, nowMs: 3_000)   // needs 1.2 * 1.65 Mbps = 1.98 Mbps
        let actions = policy.evaluate(nowMs: 3_000)
        XCTAssertEqual(actions, [.configure(key: a, substream: 1, temporal: 2, from: 2, reason: "bandwidth")])
    }

    func testEnoughBandwidthChangesNothing() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onBandwidthSample(availableBps: 2_000_000, nowMs: 3_000)
        XCTAssertTrue(policy.evaluate(nowMs: 3_000).isEmpty)
    }

    func testBandwidthStepsAreRateLimited() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onBandwidthSample(availableBps: 100_000, nowMs: 5_000)
        _ = policy.evaluate(nowMs: 5_000)                // -> substream 1
        policy.onBandwidthSample(availableBps: 100_000, nowMs: 5_500)   // inside the 2 s guard
        XCTAssertTrue(policy.evaluate(nowMs: 5_500).isEmpty)
        policy.onBandwidthSample(availableBps: 100_000, nowMs: 7_500)
        XCTAssertEqual(policy.evaluate(nowMs: 7_500), [.configure(key: a, substream: 0, temporal: 2, from: 1, reason: "bandwidth")])
    }

    // MARK: step up

    func testStepsBackUpOnlyAfterTenCleanSecondsAndOneSubstreamAtATime() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onSlowlink(nowMs: 1_000)
        _ = policy.evaluate(nowMs: 1_000)                                    // h -> m
        policy.onSlowlink(nowMs: 2_000)
        _ = policy.evaluate(nowMs: 2_000)                                    // m -> l
        XCTAssertEqual(policy.currentSubstream(key: a), 0)
        XCTAssertTrue(policy.evaluate(nowMs: 11_999).isEmpty, "not yet 10 s since the last degrade")
        XCTAssertEqual(policy.evaluate(nowMs: 12_000), [.configure(key: a, substream: 1, temporal: 2, from: 0, reason: "recover")])
        XCTAssertTrue(policy.evaluate(nowMs: 20_000).isEmpty, "one step per 10 s")
        XCTAssertEqual(policy.evaluate(nowMs: 22_000), [.configure(key: a, substream: 2, temporal: 2, from: 1, reason: "recover")])
    }

    func testAFreshDegradeRestartsTheCleanPeriod() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.onSlowlink(nowMs: 1_000)
        _ = policy.evaluate(nowMs: 1_000)                                    // h -> m
        policy.onSlowlink(nowMs: 9_000)
        _ = policy.evaluate(nowMs: 9_000)                                    // m -> l
        XCTAssertTrue(policy.evaluate(nowMs: 15_000).isEmpty)
        XCTAssertFalse(policy.evaluate(nowMs: 19_000).isEmpty)
    }

    func testTheTileNeverExceedsWhatCongestionAllows() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .grid, visible: true)
        _ = policy.evaluate(nowMs: 0)                                        // m
        policy.onSlowlink(nowMs: 100)
        _ = policy.evaluate(nowMs: 100)                                      // l
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        XCTAssertTrue(policy.evaluate(nowMs: 200).isEmpty, "fullscreen wants h but the ceiling is l")
        XCTAssertEqual(policy.ceiling(key: a), 0)
    }

    // MARK: bookkeeping

    func testUnregisteredStreamsAreForgotten() {
        let policy = makePolicy([a])
        policy.unregister(key: a)
        XCTAssertTrue(policy.evaluate(nowMs: 0).isEmpty)
        XCTAssertNil(policy.currentSubstream(key: a))
    }

    func testRegisteringTwiceKeepsTheState() {
        let policy = makePolicy([a])
        policy.setTile(key: a, tile: .fullscreen, visible: true)
        _ = policy.evaluate(nowMs: 0)
        policy.register(key: a)
        XCTAssertEqual(policy.currentSubstream(key: a), 2)
    }
}
