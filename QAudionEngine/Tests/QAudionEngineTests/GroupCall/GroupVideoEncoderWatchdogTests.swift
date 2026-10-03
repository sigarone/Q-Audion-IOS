import XCTest
@testable import QAudionEngine

/// The decision of the single-layer fallback (`GroupVideoEncoderWatchdog`): only a camera that is
/// on, on a connected publisher, whose encoder stays silent past the threshold, once per watch.
final class GroupVideoEncoderWatchdogTests: XCTestCase {

    private func decide(start: Int? = 0, now: Int? = 0, elapsed: Int64 = 9_000, threshold: Int64 = 8_000,
                        connected: Bool = true, fellBack: Bool = false) -> Bool {
        GroupVideoEncoderWatchdog.shouldFallBackToSingleLayer(
            framesAtStart: start, framesNow: now, elapsedMs: elapsed, thresholdMs: threshold,
            publisherConnected: connected, alreadyFellBack: fellBack)
    }

    func testASilentEncoderPastTheThresholdFallsBack() {
        XCTAssertTrue(decide())
        XCTAssertTrue(decide(elapsed: 8_000), "the threshold itself counts")
        XCTAssertTrue(decide(start: nil, now: 0), "no stats at the start counts as zero frames")
    }

    func testBeforeTheThresholdItWaits() {
        XCTAssertFalse(decide(elapsed: 7_999))
    }

    func testAnEncoderThatProducedFramesNeverFallsBack() {
        XCTAssertFalse(decide(start: 0, now: 1))
        XCTAssertFalse(decide(start: 120, now: 121, elapsed: 60_000))
    }

    func testAFrameCountThatDidNotGrowIsSilence() {
        XCTAssertTrue(decide(start: 120, now: 120))
    }

    func testWithoutStatsNothingIsKnownSoItNeverFallsBack() {
        XCTAssertFalse(decide(now: nil, elapsed: 60_000))
    }

    func testAPublisherThatIsNotConnectedMayLegitimatelyBeIdle() {
        XCTAssertFalse(decide(connected: false, elapsed: 60_000))
    }

    func testItRunsOncePerWatch() {
        XCTAssertFalse(decide(fellBack: true, elapsed: 60_000))
    }
}
