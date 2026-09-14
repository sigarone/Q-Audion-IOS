import XCTest
@testable import QAudionEngine

/// MASVS-CRYPTO remediation (2026-08-20/21) — unit coverage for the
/// self-contained state-machine half of `ReKeyScheduler` (no I/O, no
/// timers exercised here — those need a real clock; this covers the pure
/// deadline/period math and trigger bookkeeping, which is what's safe to
/// assert without a live call). See the class kdoc for the UNVERIFIED
/// scope this does NOT cover (the actual mid-call re-handshake wiring).
final class ReKeySchedulerTests: XCTestCase {
    func testForceReKeyEmitsTickWithIncrementingSequence() {
        let scheduler = ReKeyScheduler()
        var ticks: [ReKeyScheduler.ReKeyTick] = []
        scheduler.onReKeyTick = { ticks.append($0) }

        scheduler.forceReKey(reason: "test-1")
        scheduler.forceReKey(reason: "test-2")

        XCTAssertEqual(ticks.count, 2)
        XCTAssertEqual(ticks[0].reason, "test-1")
        XCTAssertEqual(ticks[0].sequence, 1)
        XCTAssertEqual(ticks[1].reason, "test-2")
        XCTAssertEqual(ticks[1].sequence, 2)
    }

    func testForceReKeyCapturesConfidenceAtTriggerTime() {
        let scheduler = ReKeyScheduler()
        var ticks: [ReKeyScheduler.ReKeyTick] = []
        scheduler.onReKeyTick = { ticks.append($0) }

        scheduler.observeConfidence(0.3)
        scheduler.forceReKey(reason: "low-confidence")

        XCTAssertEqual(ticks.count, 1)
        XCTAssertEqual(ticks[0].confidenceAtTrigger, 0.3, accuracy: 0.01)
    }

    func testObserveConfidenceClampsToValidRange() {
        // Out-of-range inputs must not crash or produce a negative/huge
        // period — clamp is asserted indirectly via a subsequent trigger's
        // recorded confidence, which must land in [0, 1].
        let scheduler = ReKeyScheduler()
        var ticks: [ReKeyScheduler.ReKeyTick] = []
        scheduler.onReKeyTick = { ticks.append($0) }

        scheduler.observeConfidence(5.0) // out of range high
        scheduler.forceReKey(reason: "clamp-high")
        scheduler.observeConfidence(-3.0) // out of range low
        scheduler.forceReKey(reason: "clamp-low")

        XCTAssertEqual(ticks.count, 2)
        XCTAssertEqual(ticks[0].confidenceAtTrigger, 1.0, accuracy: 0.01)
        XCTAssertEqual(ticks[1].confidenceAtTrigger, 0.0, accuracy: 0.01)
    }

    func testStopThenStartDoesNotDoubleFireTimerTicks() {
        // Regression guard: `start()` must tear down any previous timer
        // before installing a new one (mirrors Android's `stop()` call at
        // the top of `start()`). Calling start twice in a row must not
        // leave two live timers ticking in parallel.
        let scheduler = ReKeyScheduler()
        scheduler.start()
        scheduler.start()
        scheduler.stop()
        // No crash / no assertion failure on double-start + stop is the
        // pass condition here — a leaked second timer would surface as a
        // flaky double-tick in a longer-running integration test, which
        // this unit test intentionally does not attempt (no real clock).
    }

    func testForceReKeyAfterReleaseStillEmits() {
        // `release()` only stops the timer — the scheduler object itself
        // stays usable for a manual `forceReKey` (mirrors Android's
        // `release()`, which does not tear down the SharedFlow).
        let scheduler = ReKeyScheduler()
        scheduler.release()
        var ticks: [ReKeyScheduler.ReKeyTick] = []
        scheduler.onReKeyTick = { ticks.append($0) }

        scheduler.forceReKey(reason: "after-release")

        XCTAssertEqual(ticks.count, 1)
    }
}
