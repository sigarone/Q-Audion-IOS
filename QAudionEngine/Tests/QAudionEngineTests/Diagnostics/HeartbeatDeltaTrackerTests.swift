import XCTest
@testable import QAudionEngine

/// W-HBTELEM (2026-09-21) — the per-window deltas behind the extra `call.media.heartbeat`
/// attributes. The tracker is fed cumulative snapshots and must return counts since the
/// previous heartbeat of the same call, never negative, surviving counter resets.
final class HeartbeatDeltaTrackerTests: XCTestCase {

    // MARK: - Snapshot builders

    private func base() -> HeartbeatSnapshot {
        var s = HeartbeatSnapshot()
        s.rxFramesDc = 100
        s.rxFramesWs = 0
        s.txFramesDc = 90
        s.txFramesWs = 0
        s.rxGapLost = 4
        s.jbUnderruns = 10
        s.jbOverruns = 2
        s.jbHardDrops = 1
        s.jbSilenceDrops = 5
        s.jbConcealed = 7
        s.jbStretch = 30
        s.fecRecovered = 3
        s.jbDepthNow = 3
        s.jbTargetNow = 4
        s.interArrivalMaxMs = 60
        return s
    }

    private func primedTracker(baseline: HeartbeatSnapshot) -> HeartbeatDeltaTracker {
        var tracker = HeartbeatDeltaTracker()
        tracker.reset(baseline: baseline)
        return tracker
    }

    // MARK: - Deltas

    func test_theWindowReportsCountsSinceTheBaseline() {
        var tracker = primedTracker(baseline: base())
        var next = base()
        next.rxFramesDc = 350        // +250
        next.txFramesDc = 340        // +250
        next.rxGapLost = 6           // +2
        next.jbUnderruns = 11        // +1
        next.jbOverruns = 2          // +0
        next.jbHardDrops = 4         // +3
        next.jbSilenceDrops = 9      // +4
        next.jbConcealed = 8         // +1
        next.jbStretch = 55          // +25
        next.fecRecovered = 5        // +2
        next.jbDepthNow = 2
        next.jbTargetNow = 5
        next.interArrivalMaxMs = 180
        next.mainStallMsMax = 2150

        let window = tracker.advance(to: next)
        XCTAssertEqual(window.numbers["rx_frames_d"], 250)
        XCTAssertEqual(window.numbers["tx_frames_d"], 250)
        XCTAssertEqual(window.numbers["rx_gap_d"], 2)
        XCTAssertEqual(window.numbers["jb_underrun_d"], 1)
        XCTAssertEqual(window.numbers["jb_overrun_d"], 0)
        XCTAssertEqual(window.numbers["jb_hard_drop_d"], 3)
        XCTAssertEqual(window.numbers["jb_silence_drop_d"], 4)
        XCTAssertEqual(window.numbers["jb_concealed_d"], 1)
        XCTAssertEqual(window.numbers["jb_stretch_d"], 25)
        XCTAssertEqual(window.numbers["fec_rec_d"], 2)
        XCTAssertEqual(window.numbers["jb_depth_now"], 2)
        XCTAssertEqual(window.numbers["jb_target_now"], 5)
        XCTAssertEqual(window.numbers["iat_max_ms"], 180)
        XCTAssertEqual(window.numbers["main_stall_ms_max"], 2150)
        XCTAssertEqual(window.transport, "dc")
    }

    func test_eachWindowIsRelativeToThePreviousOne() {
        var tracker = primedTracker(baseline: base())
        var second = base()
        second.jbUnderruns = 12      // +2 over the baseline
        _ = tracker.advance(to: second)
        var third = second
        third.jbUnderruns = 15       // +3 over the second
        let window = tracker.advance(to: third)
        XCTAssertEqual(window.numbers["jb_underrun_d"], 3)
    }

    func test_anIdleWindowReportsZeroDeltas() {
        var tracker = primedTracker(baseline: base())
        let window = tracker.advance(to: base())
        XCTAssertEqual(window.numbers["rx_frames_d"], 0)
        XCTAssertEqual(window.numbers["jb_underrun_d"], 0)
        XCTAssertNil(window.transport, "no frames moved and the call is not known to be on native SRTP")
    }

    // MARK: - Baselines and resets

    func test_withNoBaselineTheFirstWindowHasNoDeltasOnlyTheInstantaneousReadings() {
        var tracker = HeartbeatDeltaTracker()
        XCTAssertFalse(tracker.hasBaseline)
        var first = base()
        first.mainStallMsMax = 12
        let window = tracker.advance(to: first)
        XCTAssertNil(window.numbers["rx_frames_d"])
        XCTAssertNil(window.numbers["jb_underrun_d"])
        XCTAssertNil(window.numbers["rx_gap_d"])
        XCTAssertNil(window.transport)
        XCTAssertEqual(window.numbers["jb_depth_now"], 3)
        XCTAssertEqual(window.numbers["jb_target_now"], 4)
        XCTAssertEqual(window.numbers["iat_max_ms"], 60)
        XCTAssertEqual(window.numbers["main_stall_ms_max"], 12)
        XCTAssertTrue(tracker.hasBaseline, "and that snapshot is the baseline of the next window")
    }

    func test_aCounterThatRestartsReportsTheCountSinceTheRestartNeverANegative() {
        var tracker = primedTracker(baseline: base())
        var next = base()
        next.jbUnderruns = 2           // was 10: the playout buffer was reset
        next.rxFramesDc = 40           // was 100: the frame counters were reset
        next.fecRecovered = 0          // was 3
        let window = tracker.advance(to: next)
        XCTAssertEqual(window.numbers["jb_underrun_d"], 2)
        XCTAssertEqual(window.numbers["rx_frames_d"], 40)
        XCTAssertEqual(window.numbers["fec_rec_d"], 0)
        for (key, value) in window.numbers {
            XCTAssertGreaterThanOrEqual(value, 0, "\(key) must never be negative")
        }
    }

    func test_aNewCallStartsFromItsOwnBaselineNotTheLastCallsTotals() {
        var tracker = primedTracker(baseline: base())
        var endOfFirstCall = base()
        endOfFirstCall.rxFramesDc = 9_000
        endOfFirstCall.jbUnderruns = 400
        _ = tracker.advance(to: endOfFirstCall)

        // New call: counters start from zero and the baseline is re-taken.
        var freshCounters = HeartbeatSnapshot()
        freshCounters.jbUnderruns = 0
        tracker.reset(baseline: freshCounters)
        var firstWindow = HeartbeatSnapshot()
        firstWindow.rxFramesDc = 250
        firstWindow.jbUnderruns = 1
        let window = tracker.advance(to: firstWindow)
        XCTAssertEqual(window.numbers["rx_frames_d"], 250)
        XCTAssertEqual(window.numbers["jb_underrun_d"], 1)
    }

    func test_resetToNilForgetsTheBaseline() {
        var tracker = primedTracker(baseline: base())
        tracker.reset(baseline: nil)
        XCTAssertFalse(tracker.hasBaseline)
    }

    func test_theGapCounterCanFallWithoutBeingARestart() {
        var tracker = primedTracker(baseline: base())     // rxGapLost = 4
        var next = base()
        next.rxGapLost = 3             // a late frame filled a gap
        let window = tracker.advance(to: next)
        XCTAssertEqual(window.numbers["rx_gap_d"], 0, "not 3: a decrease here is not a counter restart")
    }

    // MARK: - Missing counters

    func test_aCounterMissingFromEitherSnapshotProducesNoAttribute() {
        var withoutPlayout = HeartbeatSnapshot()
        withoutPlayout.rxFramesDc = 100
        var tracker = primedTracker(baseline: withoutPlayout)
        var later = HeartbeatSnapshot()
        later.rxFramesDc = 200
        later.jbUnderruns = 5
        later.jbDepthNow = 2
        let window = tracker.advance(to: later)
        XCTAssertEqual(window.numbers["rx_frames_d"], 100)
        XCTAssertNil(window.numbers["jb_underrun_d"], "no baseline for it: omitted, never sent as a guess")
        XCTAssertNil(window.numbers["rx_gap_d"])
        XCTAssertNil(window.numbers["fec_rec_d"])
        XCTAssertEqual(window.numbers["jb_depth_now"], 2)
        XCTAssertNil(window.numbers["iat_max_ms"])
        XCTAssertNil(window.numbers["main_stall_ms_max"])
    }

    func test_aCounterThatDisappearsProducesNoAttribute() {
        var tracker = primedTracker(baseline: base())
        var later = HeartbeatSnapshot()
        later.rxFramesDc = 200
        let window = tracker.advance(to: later)
        XCTAssertNil(window.numbers["jb_underrun_d"])
        XCTAssertNil(window.numbers["fec_rec_d"])
        XCTAssertNil(window.numbers["jb_depth_now"])
    }

    func test_negativeInstantaneousReadingsAreClampedToZero() {
        var tracker = HeartbeatDeltaTracker()
        var s = HeartbeatSnapshot()
        s.interArrivalMaxMs = -5
        s.mainStallMsMax = -9
        let window = tracker.advance(to: s)
        XCTAssertEqual(window.numbers["iat_max_ms"], 0)
        XCTAssertEqual(window.numbers["main_stall_ms_max"], 0)
    }

    // MARK: - Transport label

    func test_transportNamesTheLegTheWindowsFramesUsed() {
        XCTAssertEqual(HeartbeatDeltaTracker.transportLabel(dcFrames: 10, wsFrames: 0, nativeSrtp: nil), "dc")
        XCTAssertEqual(HeartbeatDeltaTracker.transportLabel(dcFrames: 0, wsFrames: 10, nativeSrtp: nil), "ws")
        XCTAssertEqual(HeartbeatDeltaTracker.transportLabel(dcFrames: 5, wsFrames: 5, nativeSrtp: nil), "dc+ws")
        XCTAssertEqual(HeartbeatDeltaTracker.transportLabel(dcFrames: 0, wsFrames: 0, nativeSrtp: true), "srtp")
        XCTAssertNil(HeartbeatDeltaTracker.transportLabel(dcFrames: 0, wsFrames: 0, nativeSrtp: false))
        XCTAssertNil(HeartbeatDeltaTracker.transportLabel(dcFrames: 0, wsFrames: 0, nativeSrtp: nil))
    }

    func test_frameDirectionsBothCountTowardTheTransport() {
        var tracker = primedTracker(baseline: HeartbeatSnapshot())
        var s = HeartbeatSnapshot()
        s.txFramesWs = 50               // only transmitted, and only on the relay
        let window = tracker.advance(to: s)
        XCTAssertEqual(window.numbers["tx_frames_d"], 50)
        XCTAssertEqual(window.numbers["rx_frames_d"], 0)
        XCTAssertEqual(window.transport, "ws")
    }

    // MARK: - What leaves the device

    func test_attributesAreNumbersAndOneFixedString() {
        var tracker = primedTracker(baseline: base())
        var next = base()
        next.rxFramesDc = 200
        next.mainStallMsMax = 40
        let attrs = tracker.advance(to: next).attributes()
        for (key, value) in attrs {
            if key == "transport" {
                XCTAssertTrue(value is String)
            } else {
                XCTAssertTrue(value is Int64, "\(key) must be a plain number")
            }
        }
        XCTAssertEqual(attrs["transport"] as? String, "dc")
        XCTAssertEqual(attrs["rx_frames_d"] as? Int64, 100)
    }

    func test_aFullWindowUsesExactlyTheSpecifiedAttributeNames() {
        var tracker = primedTracker(baseline: base())
        var next = base()
        next.rxFramesDc = 200
        next.mainStallMsMax = 0
        let names = Set(tracker.advance(to: next).attributes().keys)
        let expected: Set<String> = [
            "rx_frames_d", "tx_frames_d", "rx_gap_d",
            "jb_underrun_d", "jb_overrun_d", "jb_hard_drop_d", "jb_silence_drop_d",
            "jb_concealed_d", "jb_stretch_d", "jb_depth_now", "jb_target_now",
            "iat_max_ms", "fec_rec_d", "main_stall_ms_max", "transport"
        ]
        XCTAssertEqual(names, expected)
    }

    // MARK: - Timer drift (main_stall_ms_max)

    func test_timerDriftIsTheOvershootOfTheNominalIntervalInMs() {
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: 5.0, nominalSeconds: 5.0), 0)
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: 4.9, nominalSeconds: 5.0), 0)
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: 7.15, nominalSeconds: 5.0), 2150)
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: 9.47, nominalSeconds: 5.0), 4470)
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: 5.7, nominalSeconds: 5.0), 700)
    }

    func test_timerDriftIsNeverNegativeOrNonsense() {
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: 0, nominalSeconds: 5.0), 0)
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: -3, nominalSeconds: 5.0), 0)
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: Double.nan, nominalSeconds: 5.0), 0)
        XCTAssertEqual(HeartbeatTiming.timerDriftMs(elapsedSeconds: Double.infinity, nominalSeconds: 5.0), 0)
    }
}
