import XCTest
@testable import QAudionEngine

/// W-HBTELEM (2026-09-21) — the `call.disturbance.marker` event and the one-per-second
/// debounce that protects it.
final class DisturbanceMarkerTests: XCTestCase {

    // MARK: - Attributes

    func test_theEventKindAndSourceAreTheSpecifiedStrings() {
        XCTAssertEqual(DisturbanceMarker.kind, "call.disturbance.marker")
        XCTAssertEqual(DisturbanceMarker.sourceButton, "button")
    }

    func test_theMarkerCopiesTheLastCompletedWindowAndAddsItsOwnFields() {
        let lastWindow: [String: Any] = [
            "tick": 12,
            "uptime_ms": Int64(60_000),
            "rx_frames_d": Int64(248),
            "jb_underrun_d": Int64(3),
            "transport": "dc",
            "jb_depth_now": Int64(2)
        ]
        let attrs = DisturbanceMarker.attributes(sinceStartMs: 61_234, lastWindowAttributes: lastWindow, jbDepthNow: 5)
        XCTAssertEqual(attrs["since_start_ms"] as? Int64, 61_234)
        XCTAssertEqual(attrs["source"] as? String, "button")
        XCTAssertEqual(attrs["rx_frames_d"] as? Int64, 248)
        XCTAssertEqual(attrs["jb_underrun_d"] as? Int64, 3)
        XCTAssertEqual(attrs["transport"] as? String, "dc")
        XCTAssertEqual(attrs["tick"] as? Int, 12)
        XCTAssertEqual(attrs["uptime_ms"] as? Int64, 60_000)
        XCTAssertEqual(attrs["jb_depth_now"] as? Int64, 5, "the depth NOW replaces the window's copy")
    }

    func test_theWindowsDepthIsKeptWhenNoLiveReadingIsAvailable() {
        let attrs = DisturbanceMarker.attributes(sinceStartMs: 1_000,
                                                 lastWindowAttributes: ["jb_depth_now": Int64(2)],
                                                 jbDepthNow: nil)
        XCTAssertEqual(attrs["jb_depth_now"] as? Int64, 2)
    }

    func test_aMarkerBeforeTheFirstHeartbeatStillCarriesItsOwnFields() {
        let attrs = DisturbanceMarker.attributes(sinceStartMs: 2_000, lastWindowAttributes: [:], jbDepthNow: nil)
        XCTAssertEqual(Set(attrs.keys), Set(["since_start_ms", "source"]))
    }

    func test_theMarkerDoesNotModifyTheWindowItCopied() {
        let lastWindow: [String: Any] = ["rx_frames_d": Int64(1)]
        _ = DisturbanceMarker.attributes(sinceStartMs: 5, lastWindowAttributes: lastWindow, jbDepthNow: 1)
        XCTAssertEqual(Set(lastWindow.keys), Set(["rx_frames_d"]))
    }

    func test_aNegativeElapsedTimeIsClampedToZero() {
        let attrs = DisturbanceMarker.attributes(sinceStartMs: -50, lastWindowAttributes: [:], jbDepthNow: nil)
        XCTAssertEqual(attrs["since_start_ms"] as? Int64, 0)
    }

    // MARK: - Debounce

    func test_theFirstPressAlwaysEmits() {
        var debouncer = DisturbanceMarkerDebouncer()
        XCTAssertTrue(debouncer.shouldEmit(now: 5_000))
    }

    func test_pressesInsideOneSecondAreSuppressed() {
        var debouncer = DisturbanceMarkerDebouncer()
        XCTAssertTrue(debouncer.shouldEmit(now: 100.0))
        XCTAssertFalse(debouncer.shouldEmit(now: 100.2))
        XCTAssertFalse(debouncer.shouldEmit(now: 100.99))
    }

    func test_aPressExactlyOneSecondLaterEmits() {
        var debouncer = DisturbanceMarkerDebouncer()
        XCTAssertTrue(debouncer.shouldEmit(now: 100.0))
        XCTAssertTrue(debouncer.shouldEmit(now: 101.0))
    }

    func test_aSuppressedPressDoesNotExtendTheWindow() {
        var debouncer = DisturbanceMarkerDebouncer()
        XCTAssertTrue(debouncer.shouldEmit(now: 100.0))
        XCTAssertFalse(debouncer.shouldEmit(now: 100.9))
        XCTAssertTrue(debouncer.shouldEmit(now: 101.0), "measured from the last EMITTED marker, not the last press")
    }

    func test_atMostOneMarkerPerSecondUnderAHammer() {
        var debouncer = DisturbanceMarkerDebouncer()
        var emitted = 0
        var now: TimeInterval = 50
        for _ in 0..<100 {
            if debouncer.shouldEmit(now: now) { emitted += 1 }
            now += 0.1
        }
        // 10 seconds of presses every 100 ms: one per second, so 10 markers.
        XCTAssertLessThanOrEqual(emitted, 10)
        XCTAssertGreaterThanOrEqual(emitted, 9)
    }

    func test_aClockThatRunsBackwardsNeverBlocks() {
        var debouncer = DisturbanceMarkerDebouncer()
        XCTAssertTrue(debouncer.shouldEmit(now: 100))
        XCTAssertTrue(debouncer.shouldEmit(now: 50))
    }

    func test_resetForgetsTheLastMarker() {
        var debouncer = DisturbanceMarkerDebouncer()
        XCTAssertTrue(debouncer.shouldEmit(now: 100))
        debouncer.reset()
        XCTAssertTrue(debouncer.shouldEmit(now: 100.1))
    }
}
