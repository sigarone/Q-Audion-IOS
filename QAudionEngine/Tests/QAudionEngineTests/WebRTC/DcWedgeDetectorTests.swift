import XCTest
@testable import QAudionEngine

/// W-DCWEDGE (2026-09-25) -- the thresholds, the hysteresis and the two real-call
/// timelines of `DcWedgeDetector`, plus the pure routing rule around it
/// (`AudioDcSendOutcome.preSend`) and the kill switch.
///
/// The detector is a pure state machine (no clock, no WebRTC types), so every case
/// below is a list of `(time, reading)` samples and an expectation on the transitions
/// they cause; it runs on the CI simulator lane without the WebRTC binary. The
/// boundaries are tested on both sides (999 ms / 1000 ms, 2999 ms / 3000 ms,
/// 500 ms / 501 ms) because the whole point of the rule is those numbers. Most cases
/// are the Android twin's own tests (`DcWedgeDetectorTest.kt`) ported one to one: the
/// two platforms must agree.
final class DcWedgeDetectorTests: XCTestCase {

    private var d = DcWedgeDetector()

    @discardableResult
    private func sample(_ t: Int64, _ buffered: Int64, dropped: Bool = false, rx: Bool = false)
        -> DcWedgeDetector.Transition? {
        return d.onSample(nowMs: t, bufferedAmountBytes: buffered, dropped: dropped, rxOnDcSeen: rx)
    }

    /// Wedge the detector by the queue rule at t=1000 (queue 1600 B since t=0).
    private func enterAt1000() throws {
        XCTAssertNil(sample(0, 1600))
        _ = try XCTUnwrap(sample(1000, 1600))
        XCTAssertTrue(d.wedged)
    }

    // MARK: - The contract's numbers

    func testConstantsMatchTheAndroidTwin() {
        XCTAssertEqual(DcWedgeDetector.enterBufferedBytes, 1500)
        XCTAssertEqual(DcWedgeDetector.enterOverMs, 1_000)
        XCTAssertEqual(DcWedgeDetector.enterConsecutiveDrops, 15)
        XCTAssertEqual(DcWedgeDetector.exitBufferedBytes, 500)
        XCTAssertEqual(DcWedgeDetector.exitLowMs, 3_000)
        XCTAssertEqual(DcWedgeDetector.exitRxWindowMs, 500)
        XCTAssertEqual(DcWedgeDetector.maxSampleGapMs, 1_000)
    }

    /// "Over" for the detector is exactly "the shed gate is closing": the two 1500 must
    /// stay equal (the gate's own 1500 is pinned by `AudioDcBackpressureGateTests`).
    func testTheEnterThresholdIsTheShedGateThreshold() {
        let threshold = UInt64(DcWedgeDetector.enterBufferedBytes)
        XCTAssertFalse(AudioDcBackpressureGate.shouldDrop(bufferedAmount: threshold, threshold: 1500))
        XCTAssertTrue(AudioDcBackpressureGate.shouldDrop(bufferedAmount: threshold + 1, threshold: 1500))
    }

    // MARK: - Entering

    func testAHealthyQueueNeverWedgesAndExactly1500BIsNotOver() {
        var t: Int64 = 0
        while t <= 20_000 {
            // 0...1500 in a sawtooth: the worst a healthy channel does, ending on the threshold itself.
            let reading: Int64 = ((t / 60) % 26) * 60
            XCTAssertNil(sample(t, reading, rx: true))
            t += 60
        }
        XCTAssertFalse(d.wedged)
        XCTAssertNil(sample(20_060, 1500))
        XCTAssertNil(sample(30_000, 1500))
        XCTAssertFalse(d.wedged)
    }

    func testOver1500BFor1000msEntersAnd999msDoesNot() throws {
        XCTAssertNil(sample(0, 1600))
        XCTAssertNil(sample(999, 1600))
        XCTAssertFalse(d.wedged)
        let tr = try XCTUnwrap(sample(1000, 1600))
        XCTAssertTrue(d.wedged)
        XCTAssertTrue(tr.wedged)
        XCTAssertEqual(tr.reason, .buffered)
        XCTAssertEqual(tr.holdMs, 1000)
        XCTAssertEqual(tr.bufferedBytes, 1600)
    }

    func testASingleReadingAtTheThresholdRestartsTheEnterClock() throws {
        XCTAssertNil(sample(0, 1600))
        XCTAssertNil(sample(900, 1600))
        XCTAssertNil(sample(960, 1500))      // not over: the 900 ms are forgotten
        XCTAssertNil(sample(1020, 1600))     // a new clock starts here
        XCTAssertNil(sample(2019, 1600))
        let tr = try XCTUnwrap(sample(2020, 1600))
        XCTAssertEqual(tr.holdMs, 1000)
    }

    func testAnUnknownReadingRestartsTheEnterClockEnteringNeedsPositiveEvidence() {
        XCTAssertNil(sample(0, 1600))
        XCTAssertNil(sample(900, 1600))
        XCTAssertNil(sample(960, -1))        // no OPEN channel to read
        XCTAssertNil(sample(1020, 1600))
        XCTAssertNil(sample(1919, 1600))
        XCTAssertNotNil(sample(2020, 1600))
    }

    func testFifteenConsecutiveShedFramesEnterEvenWhenTheReadingIsNotOverTheThreshold() throws {
        // The backstop for a reading that is stale or unavailable: 1200 B is under the queue rule.
        for i in 0..<14 {
            XCTAssertNil(sample(Int64(i) * 60, 1200, dropped: true), "drop \(i + 1)")
        }
        let tr = try XCTUnwrap(sample(14 * 60, 1200, dropped: true))
        XCTAssertTrue(d.wedged)
        XCTAssertEqual(tr.reason, .drops)
        XCTAssertEqual(tr.consecutiveDrops, 15)
    }

    func testAFrameThatGotThroughResetsTheDropCount() {
        var t: Int64 = 0
        for _ in 0..<14 { XCTAssertNil(sample(t, 1200, dropped: true)); t += 60 }
        XCTAssertNil(sample(t, 1200, dropped: false)); t += 60
        for _ in 0..<14 { XCTAssertNil(sample(t, 1200, dropped: true)); t += 60 }
        XCTAssertFalse(d.wedged)
    }

    // MARK: - Leaving: both halves, and the hysteresis

    func testExactly3000msBelow500BExitsAnd2999msDoesNot() throws {
        try enterAt1000()
        var t: Int64 = 1500                  // the low clock starts at the first low sample after the entry
        while t <= 4000 { XCTAssertNil(sample(t, 499, rx: true)); t += 500 }
        XCTAssertNil(sample(4499, 499, rx: true))                  // 2999 ms
        let tr = try XCTUnwrap(sample(4500, 499, rx: true))        // 3000 ms
        XCTAssertFalse(d.wedged)
        XCTAssertFalse(tr.wedged)
        XCTAssertEqual(tr.reason, .drained)
        XCTAssertEqual(tr.holdMs, 3000)
        XCTAssertEqual(tr.rxAgoMs, 0)
        XCTAssertEqual(tr.wedgedForMs, 3500, "wedged from 1000 to 4500")
    }

    func testExactly500BIsNotLowEnough() throws {
        try enterAt1000()
        var t: Int64 = 1500
        while t <= 10_000 { XCTAssertNil(sample(t, 500, rx: true)); t += 500 }
        XCTAssertTrue(d.wedged)
    }

    func testTheBandBetween500And1500KeepsTheChannelWedgedAndRestartsTheLowClock() throws {
        try enterAt1000()
        var t: Int64 = 1500
        while t <= 3500 { XCTAssertNil(sample(t, 300, rx: true)); t += 500 }   // 2000 ms low so far
        XCTAssertNil(sample(4000, 900, rx: true))    // back in the band: the low clock is forgotten
        XCTAssertNil(sample(4500, 300, rx: true))    // a new low clock starts here
        var u: Int64 = 5000
        while u <= 7000 { XCTAssertNil(sample(u, 300, rx: true)); u += 500 }   // 2500 ms low
        XCTAssertTrue(d.wedged)
        XCTAssertNotNil(sample(7500, 300, rx: true), "3000 ms after the restart")
        XCTAssertFalse(d.wedged)
    }

    func testAShedFrameRestartsTheLowClockEvenNextToALowReading() {
        XCTAssertNil(sample(0, 1600))
        XCTAssertNotNil(sample(1000, 1600))
        var t: Int64 = 1500
        while t <= 3500 { XCTAssertNil(sample(t, 300, rx: true)); t += 500 }
        XCTAssertNil(sample(4000, 300, dropped: true, rx: true))
        XCTAssertNil(sample(4500, 300, rx: true))    // new clock from here
        var u: Int64 = 5000
        while u <= 7000 { XCTAssertNil(sample(u, 300, rx: true)); u += 500 }
        XCTAssertNil(sample(7499, 300, rx: true))
        XCTAssertNotNil(sample(7500, 300, rx: true))
    }

    func testLowFor3000msIsNotEnoughWithoutAFrameReceivedOnTheDataChannel() throws {
        try enterAt1000()
        var t: Int64 = 1500
        while t <= 9000 { XCTAssertNil(sample(t, 200, rx: false)); t += 500 }
        XCTAssertTrue(d.wedged, "drained but the peer is not reaching us on the DataChannel")
        let tr = try XCTUnwrap(sample(9500, 200, rx: true))
        XCTAssertEqual(tr.rxAgoMs, 0, "the first arrival releases it")
        XCTAssertFalse(d.wedged)
    }

    func testAFrameReceived500msAgoIsRecentEnoughAnd501msAgoIsNot() throws {
        try enterAt1000()
        var t: Int64 = 1500
        while t <= 3500 { XCTAssertNil(sample(t, 200, rx: false)); t += 500 }
        XCTAssertNil(sample(4000, 200, rx: true))                  // lowMs 2500: not yet
        let tr500 = try XCTUnwrap(sample(4500, 200, rx: false))    // lowMs 3000, the last arrival was 500 ms ago
        XCTAssertEqual(tr500.rxAgoMs, 500)
        XCTAssertFalse(d.wedged)

        // The same again, 1 ms further away.
        var e = DcWedgeDetector()
        XCTAssertNil(e.onSample(nowMs: 0, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false))
        XCTAssertNotNil(e.onSample(nowMs: 1000, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false))
        var u: Int64 = 1500
        while u <= 3500 {
            XCTAssertNil(e.onSample(nowMs: u, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: false))
            u += 500
        }
        XCTAssertNil(e.onSample(nowMs: 4000, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: true))
        XCTAssertNil(e.onSample(nowMs: 4501, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: false),
                     "501 ms since the last arrival")
        XCTAssertTrue(e.wedged)
    }

    func testFramesStillArrivingNeverReleaseAQueueThatHasNotDrained() throws {
        // The shape of 7727f262: the peer trickles frames in while the send queue sits over the
        // threshold. Neither the arrivals nor a healthy ICE state may release it -- ICE is not
        // even an input.
        try enterAt1000()
        var t: Int64 = 1060
        while t <= 25_000 { XCTAssertNil(sample(t, 1600, rx: true)); t += 60 }
        XCTAssertTrue(d.wedged)
    }

    func testAfterLeavingANewStallEntersAgainWithAFreshClock() throws {
        try enterAt1000()
        var t: Int64 = 1500
        while t <= 4000 { XCTAssertNil(sample(t, 300, rx: true)); t += 500 }
        XCTAssertNotNil(sample(4500, 300, rx: true))
        XCTAssertFalse(d.wedged)
        XCTAssertNil(sample(5000, 1700))
        XCTAssertNil(sample(5999, 1700))
        let again = try XCTUnwrap(sample(6000, 1700))
        XCTAssertTrue(again.wedged)
        XCTAssertEqual(again.holdMs, 1000, "the old clock does not leak into the new stall")
    }

    // MARK: - Continuity, clock, reset

    func testASilenceLongerThan1000msBetweenSamplesRestartsTheEnterClock() throws {
        XCTAssertNil(sample(0, 1600))
        XCTAssertNil(sample(1500, 1600))     // 1500 ms apart: not evidence of 1500 ms of anything
        XCTAssertNil(sample(2400, 1600))
        let tr = try XCTUnwrap(sample(2500, 1600))
        XCTAssertEqual(tr.holdMs, 1000)
    }

    func testExactly1000msBetweenSamplesIsStillContinuous() {
        XCTAssertNil(sample(0, 1600))
        XCTAssertNotNil(sample(1000, 1600))
    }

    func testASilenceRestartsTheDropCountAndTheExitClockAsWell() {
        for i in 0..<14 { XCTAssertNil(sample(Int64(i) * 60, 1200, dropped: true)) }
        XCTAssertNil(sample(5000, 1200, dropped: true), "the 15th drop comes after a long silence: count restarts at 1")
        XCTAssertFalse(d.wedged)

        var e = DcWedgeDetector()
        _ = e.onSample(nowMs: 0, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false)
        XCTAssertNotNil(e.onSample(nowMs: 1000, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false))
        var t: Int64 = 1500
        while t <= 3500 {
            XCTAssertNil(e.onSample(nowMs: t, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: true))
            t += 500
        }
        // Muted (or ICE gate closed) for 10 s, then low readings again: the 2000 ms of low before it do not count.
        XCTAssertNil(e.onSample(nowMs: 13_500, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: true))
        var u: Int64 = 14_000
        while u <= 16_000 {
            XCTAssertNil(e.onSample(nowMs: u, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: true))
            u += 500
        }
        XCTAssertNil(e.onSample(nowMs: 16_499, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: true))
        XCTAssertNotNil(e.onSample(nowMs: 16_500, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: true))
    }

    func testTimeNeverRunsBackwards() throws {
        XCTAssertNil(sample(1000, 1600))
        XCTAssertNil(sample(500, 1600))      // treated as 1000
        XCTAssertNil(sample(1999, 1600))
        let tr = try XCTUnwrap(sample(2000, 1600))
        XCTAssertEqual(tr.holdMs, 1000)
    }

    func testResetForgetsAWedgeAndEveryClock() throws {
        try enterAt1000()
        d.reset()
        XCTAssertFalse(d.wedged)
        XCTAssertNil(sample(5000, 1600))     // a fresh clock, not 4000 ms of the old one
        XCTAssertNil(sample(5999, 1600))
        XCTAssertNotNil(sample(6000, 1600))
    }

    // MARK: - The probe (iOS only)

    func testNoProbeWhileHealthy() {
        XCTAssertNil(sample(0, 100))
        XCTAssertFalse(d.shouldProbe(nowMs: 0))
        XCTAssertNil(sample(60, 100))
        XCTAssertFalse(d.shouldProbe(nowMs: 60))
    }

    func testTheProbeNeedsADrainedQueueAndIsRateLimited() throws {
        try enterAt1000()
        XCTAssertFalse(d.shouldProbe(nowMs: 1000), "the queue is still over the threshold")
        XCTAssertNil(sample(1060, 900))
        XCTAssertFalse(d.shouldProbe(nowMs: 1060), "900 B is not drained: SCTP is not emptying it yet")
        XCTAssertNil(sample(1120, 300))
        XCTAssertTrue(d.shouldProbe(nowMs: 1120), "drained: one frame goes on the channel")
        XCTAssertNil(sample(1180, 300))
        XCTAssertFalse(d.shouldProbe(nowMs: 1180))
        XCTAssertNil(sample(1519, 300))
        XCTAssertFalse(d.shouldProbe(nowMs: 1519), "399 ms after the last probe")
        XCTAssertNil(sample(1520, 300))
        XCTAssertTrue(d.shouldProbe(nowMs: 1520), "400 ms after the last probe")
    }

    func testAnUnknownReadingIsNeverAProbe() throws {
        try enterAt1000()
        XCTAssertNil(sample(1060, -1))
        XCTAssertFalse(d.shouldProbe(nowMs: 1060))
    }

    func testTheProbeStopsWhenTheChannelIsReleased() throws {
        try enterAt1000()
        var t: Int64 = 1500
        while t <= 4000 { XCTAssertNil(sample(t, 300, rx: true)); t += 500 }
        XCTAssertNotNil(sample(4500, 300, rx: true))
        XCTAssertFalse(d.wedged)
        XCTAssertFalse(d.shouldProbe(nowMs: 4500))
        XCTAssertFalse(d.shouldProbe(nowMs: 9000))
    }

    /// Why the probe exists. A physical hole hits both directions, so both phones wedge and both
    /// divert to the relay; after the path is back nobody writes on the DataChannel, so nobody
    /// can see the received frame the exit rule needs. Two detectors, one frame per interval
    /// through the channel in each direction: both come back. Without it, neither ever does.
    func testTheProbeBreaksTheSymmetricDeadlockWhereTwoWedgedPhonesNeverRecover() {
        var a = DcWedgeDetector()
        var b = DcWedgeDetector()
        XCTAssertNil(a.onSample(nowMs: 0, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false))
        XCTAssertNil(b.onSample(nowMs: 0, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false))
        XCTAssertNotNil(a.onSample(nowMs: 1000, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false))
        XCTAssertNotNil(b.onSample(nowMs: 1000, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false))
        var aRxPending = false
        var bRxPending = false
        var aFreeAt: Int64 = -1
        var bFreeAt: Int64 = -1
        var t: Int64 = 1060
        while t <= 20_000 {
            // The path is back and both queues are drained.
            let aTr = a.onSample(nowMs: t, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: aRxPending)
            aRxPending = false
            if aTr != nil && aFreeAt < 0 { aFreeAt = t }
            if a.shouldProbe(nowMs: t) { bRxPending = true }
            let bTr = b.onSample(nowMs: t, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: bRxPending)
            bRxPending = false
            if bTr != nil && bFreeAt < 0 { bFreeAt = t }
            if b.shouldProbe(nowMs: t) { aRxPending = true }
            t += 60
        }
        XCTAssertFalse(a.wedged)
        XCTAssertFalse(b.wedged)
        XCTAssertGreaterThan(aFreeAt, 0)
        XCTAssertGreaterThan(bFreeAt, 0)
        XCTAssertLessThan(aFreeAt, 6_000, "about 3 s after the queue drained, not at the end of the call")
        XCTAssertLessThan(bFreeAt, 6_000)

        // The same two phones with nobody writing on the channel: stuck to the end of the call.
        var c = DcWedgeDetector()
        var e = DcWedgeDetector()
        _ = c.onSample(nowMs: 0, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false)
        _ = e.onSample(nowMs: 0, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false)
        _ = c.onSample(nowMs: 1000, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false)
        _ = e.onSample(nowMs: 1000, bufferedAmountBytes: 1600, dropped: false, rxOnDcSeen: false)
        var u: Int64 = 1060
        while u <= 600_000 {
            _ = c.onSample(nowMs: u, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: false)
            _ = e.onSample(nowMs: u, bufferedAmountBytes: 200, dropped: false, rxOnDcSeen: false)
            u += 60
        }
        XCTAssertTrue(c.wedged)
        XCTAssertTrue(e.wedged)
    }

    // MARK: - The two real stalls (iPhone side)
    //
    // Measured (`phones\\ios-iPhone-*.log`, times UTC): the first and the last back-pressure line,
    // the ICE transitions, the buffered readings (1543-1818 B, fixed at 1802 B in 277cff7c). Modelled:
    // the 60 ms frame cadence (83-88 frames per 5 s heartbeat window), the readings inside the
    // observed range, the trickle of frames arriving on the channel and the moment the peer's
    // queue drains. `drive` feeds the detector the way `QAudionPeerConnection.sendAudioFrameData`
    // does: one sample per outbound frame, `dropped` = the reading is over the shed threshold,
    // then the probe question; frames the ICE gate diverts never reach the peer connection.

    private struct Change {
        let atMs: Int64
        let transition: DcWedgeDetector.Transition
    }

    private struct Run {
        var changes: [Change] = []
        /// Frames that would have been shed by the back-pressure gate (not wedged, queue over 1500 B).
        var shed = 0
        /// Frames the wedge diverted to the relay.
        var diverted = 0
        /// Probe frames that still went on the channel.
        var probes = 0
    }

    private func drive(from: Int64,
                       to: Int64,
                       iceGateClosed: (Int64) -> Bool,
                       buffered: (Int64) -> Int64,
                       rx: (Int64) -> Bool) -> Run {
        var run = Run()
        var t = from
        while t <= to {
            if !iceGateClosed(t) {
                let reading = buffered(t)
                let shedNow = reading > 1500
                if let tr = d.onSample(nowMs: t, bufferedAmountBytes: reading, dropped: shedNow, rxOnDcSeen: rx(t)) {
                    run.changes.append(Change(atMs: t, transition: tr))
                }
                let probe = d.shouldProbe(nowMs: t)
                if d.wedged {
                    if probe { run.probes += 1 } else { run.diverted += 1 }
                } else if shedNow {
                    run.shed += 1
                }
            }
            t += 60
        }
        return run
    }

    func testCall7727f262TheWedgeIsDeclaredAtTheDropCountNotAt21sAndICENeverReleasesIt() throws {
        // Times are ms after 17:10:00.000 UTC on 2026-09-23.
        let firstBackpressure: Int64 = 6_052
        let lastBackpressure: Int64 = 27_493
        let iceDown: Int64 = 11_239        // `dcmux txfall why=icegate`, 16 frames on the WS relay
        let iceUp: Int64 = 12_153          // ICE `connected` again: the ICE gate reopened the channel
        let run = drive(
            from: firstBackpressure - 600,
            to: 40_000,
            iceGateClosed: { t in t >= iceDown && t < iceUp },
            buffered: { t in
                if t < firstBackpressure { return 120 }
                if t <= lastBackpressure {
                    let step: Int64 = (t / 1_000) % 4
                    return 1543 + step * 90                                        // 1543...1813 B, never under 1500
                }
                if t < 27_600 { return 900 }                                       // draining
                return 200
            },
            rx: { t in t < 5_800 || t >= 26_800 })     // the hole, then the peer's queue drains

        XCTAssertEqual(run.changes.count, 2, "exactly one entry and one exit")
        let enter = run.changes[0]
        let exit = run.changes[1]

        XCTAssertTrue(enter.transition.wedged)
        XCTAssertEqual(enter.transition.reason, .drops)
        XCTAssertEqual(enter.transition.consecutiveDrops, 15)
        XCTAssertEqual(enter.atMs, 6_892, "15 shed frames at 60 ms after the queue stuck")
        XCTAssertEqual(enter.atMs - firstBackpressure, 840)
        XCTAssertLessThan(enter.atMs, iceDown, "4.3 s before ICE said anything: ICE is not an input")
        XCTAssertEqual(run.shed, 14, "14 frames shed instead of ~358 (6 052 to 27 493 ms at 60 ms)")

        XCTAssertFalse(exit.transition.wedged)
        XCTAssertEqual(exit.transition.reason, .drained)
        XCTAssertEqual(exit.atMs, 30_652, "27 652 is the first sample under 500 B, +3000 ms")
        XCTAssertEqual(exit.transition.wedgedForMs, 23_760)
        XCTAssertEqual(exit.transition.holdMs, 3_000)
        XCTAssertEqual(exit.transition.rxAgoMs, 0)

        // ICE went down and came straight back INSIDE the wedge; neither edge changed anything, and
        // the channel was not reopened at `iceUp` (the old "no mode, no debounce" reopening).
        XCTAssertTrue(iceDown > enter.atMs && iceDown < exit.atMs)
        XCTAssertTrue(iceUp > enter.atMs && iceUp < exit.atMs)
        XCTAssertFalse(d.wedged)

        // While drained and wedged, one frame per 400 ms still goes on the channel: 27 652 ... 30 592.
        XCTAssertEqual(run.probes, 8)
        XCTAssertGreaterThan(run.diverted, 350, "the frames of the hole and of the recovery went on the relay")
    }

    func testCall277cff7cTheWedgeIsDeclaredWhileICENeverChangedState() throws {
        // Times are ms after 18:05:00.000 UTC on 2026-09-24. The iPhone saw no ICE state change in the
        // whole call, so on v1.0.1181 nothing could ever have moved the audio to the relay (`ws=0`).
        let firstBackpressure: Int64 = 53_952
        let lastBackpressure: Int64 = 61_378
        let run = drive(
            from: firstBackpressure - 600,
            to: 75_000,
            iceGateClosed: { _ in false },
            buffered: { t in
                if t < firstBackpressure { return 100 }
                if t <= lastBackpressure { return 1802 }     // fixed at 1802 B for 6.3 s
                if t < 61_500 { return 900 }
                return 200                                    // "DC free about 01.5-02.0"
            },
            rx: { t in t < 53_500 || t >= 62_000 })

        XCTAssertEqual(run.changes.count, 2)
        let enter = run.changes[0]
        let exit = run.changes[1]
        XCTAssertEqual(enter.transition.reason, .drops)
        XCTAssertEqual(enter.atMs, 54_792)
        XCTAssertEqual(enter.atMs - firstBackpressure, 840)
        XCTAssertEqual(run.shed, 14, "14 frames shed instead of ~124 (53 952 to 61 378 ms at 60 ms)")

        XCTAssertEqual(exit.transition.reason, .drained)
        XCTAssertEqual(exit.atMs, 64_512, "the first low sample is 61 512, +3000 ms, and the peer's frames are back")
        XCTAssertEqual(exit.transition.wedgedForMs, 9_720)
        XCTAssertGreaterThan(run.diverted, 140)
        XCTAssertFalse(d.wedged)
    }

    // MARK: - The log line (what the shipper's redactor sees)

    func testTheLogLinesAreTerseAndNumericOnly() throws {
        XCTAssertNil(sample(0, 1600))
        let enter = try XCTUnwrap(sample(1000, 1600))
        XCTAssertEqual(enter.logLine, "dcmux wedge=1 why=buf buf=1600 over=1000 drops=0")

        var t: Int64 = 1500
        while t <= 4000 { XCTAssertNil(sample(t, 300, rx: true)); t += 500 }
        let exit = try XCTUnwrap(sample(4500, 300, rx: true))
        XCTAssertEqual(exit.logLine, "dcmux wedge=0 why=drained buf=300 low=3000 rxago=0 wsec=3")
    }

    /// The live-log shipper's fail-closed redactor deletes a line that holds a run of 12 or more
    /// `[A-Za-z0-9+/=_-]` characters. `key=value` is one run, so EVERY token stays under 12
    /// characters -- also for a huge reading and a wedge of eleven days.
    func testNoTokenOfEitherLogLineReachesTheRedactorsTwelveCharacterLimit() {
        let enter = DcWedgeDetector.Transition(wedged: true, reason: .buffered, bufferedBytes: 123_456,
                                               holdMs: 999_999, consecutiveDrops: 15,
                                               rxAgoMs: -1, wedgedForMs: 0)
        let exit = DcWedgeDetector.Transition(wedged: false, reason: .drained, bufferedBytes: 123_456,
                                              holdMs: 999_999, consecutiveDrops: 0,
                                              rxAgoMs: 499, wedgedForMs: 999_999_000)
        for line in [enter.logLine, exit.logLine] {
            for token in line.split(separator: " ") {
                XCTAssertLessThan(token.count, 12, "token \(token) of \(line)")
            }
        }
        XCTAssertTrue(exit.logLine.hasSuffix("wsec=999999"))
    }

    /// The limit holds for ANY input, not only for what a real call produces: every value is
    /// clamped to the digits its key leaves.
    func testTheLogLinesStayUnderTheLimitForAbsurdValuesToo() {
        let enter = DcWedgeDetector.Transition(wedged: true, reason: .drops, bufferedBytes: Int64.max,
                                               holdMs: Int64.max, consecutiveDrops: Int.max,
                                               rxAgoMs: -1, wedgedForMs: 0)
        let exit = DcWedgeDetector.Transition(wedged: false, reason: .drained, bufferedBytes: Int64.max,
                                              holdMs: Int64.max, consecutiveDrops: 0,
                                              rxAgoMs: Int64.max, wedgedForMs: Int64.max)
        for line in [enter.logLine, exit.logLine] {
            for token in line.split(separator: " ") {
                XCTAssertLessThan(token.count, 12, "token \(token) of \(line)")
            }
        }
        XCTAssertEqual(enter.logLine, "dcmux wedge=1 why=drops buf=9999999 over=999999 drops=99999")
        XCTAssertEqual(exit.logLine, "dcmux wedge=0 why=drained buf=9999999 low=9999999 rxago=99999 wsec=999999")
    }

    /// ...and for absurdly NEGATIVE ones: the minus sign takes one of the characters the digits have, so
    /// the floor is a tenth of the cap. The real "unknown" marker (-1) is untouched.
    func testTheLogLinesStayUnderTheLimitForAbsurdlyNegativeValuesToo() {
        let enter = DcWedgeDetector.Transition(wedged: true, reason: .drops, bufferedBytes: Int64.min,
                                               holdMs: Int64.min, consecutiveDrops: Int.min,
                                               rxAgoMs: -1, wedgedForMs: 0)
        let exit = DcWedgeDetector.Transition(wedged: false, reason: .drained, bufferedBytes: Int64.min,
                                              holdMs: Int64.min, consecutiveDrops: 0,
                                              rxAgoMs: Int64.min, wedgedForMs: Int64.min)
        for line in [enter.logLine, exit.logLine] {
            for token in line.split(separator: " ") {
                XCTAssertLessThan(token.count, 12, "token \(token) of \(line)")
            }
        }
        XCTAssertEqual(enter.logLine, "dcmux wedge=1 why=drops buf=-999999 over=-99999 drops=-9999")
        XCTAssertEqual(exit.logLine, "dcmux wedge=0 why=drained buf=-999999 low=-999999 rxago=-9999 wsec=-99999")

        let unknown = DcWedgeDetector.Transition(wedged: true, reason: .drops, bufferedBytes: -1,
                                                 holdMs: 0, consecutiveDrops: 15,
                                                 rxAgoMs: -1, wedgedForMs: 0)
        XCTAssertEqual(unknown.logLine, "dcmux wedge=1 why=drops buf=-1 over=0 drops=15")
    }

    // MARK: - The routing rule

    func testAHealthyFrameIsSentAndAFrameOverTheThresholdIsShed() {
        XCTAssertNil(AudioDcSendOutcome.preSend(shedByBackpressure: false, wedged: false, probe: false, divertEnabled: true))
        XCTAssertEqual(AudioDcSendOutcome.preSend(shedByBackpressure: true, wedged: false, probe: false, divertEnabled: true), .shed)
    }

    func testAWedgedChannelDivertsEveryFrameExceptTheProbe() {
        XCTAssertEqual(AudioDcSendOutcome.preSend(shedByBackpressure: true, wedged: true, probe: false, divertEnabled: true), .useRelay)
        XCTAssertEqual(AudioDcSendOutcome.preSend(shedByBackpressure: false, wedged: true, probe: false, divertEnabled: true), .useRelay)
        XCTAssertNil(AudioDcSendOutcome.preSend(shedByBackpressure: false, wedged: true, probe: true, divertEnabled: true),
                     "the probe goes on the channel")
    }

    /// The kill switch restores the pre-W-DCWEDGE routing exactly: over the threshold = shed, anything
    /// else = sent, whatever the detector thinks.
    func testTheKillSwitchRestoresThePreWedgeRouting() {
        XCTAssertEqual(AudioDcSendOutcome.preSend(shedByBackpressure: true, wedged: true, probe: false, divertEnabled: false), .shed)
        XCTAssertNil(AudioDcSendOutcome.preSend(shedByBackpressure: false, wedged: true, probe: false, divertEnabled: false))
        XCTAssertNil(AudioDcSendOutcome.preSend(shedByBackpressure: false, wedged: true, probe: true, divertEnabled: false))
    }

    func testOnlyUseRelayNeedsTheRelay() {
        XCTAssertTrue(AudioDcSendOutcome.useRelay.needsRelay)
        XCTAssertFalse(AudioDcSendOutcome.queued.needsRelay)
        XCTAssertFalse(AudioDcSendOutcome.shed.needsRelay, "a shed frame goes nowhere: NOT to the relay")
    }

    /// Hangup and NACK frames are not audio: a shed one used to be lost (and counted as sent), so with
    /// the switch on it goes on the relay; with the switch off it is dropped exactly as before.
    func testAShedControlFrameGoesOnTheRelayOnlyWhileTheSwitchIsOn() {
        XCTAssertFalse(AudioDcSendOutcome.queued.controlFrameNeedsRelay(divertEnabled: true))
        XCTAssertFalse(AudioDcSendOutcome.queued.controlFrameNeedsRelay(divertEnabled: false))
        XCTAssertTrue(AudioDcSendOutcome.useRelay.controlFrameNeedsRelay(divertEnabled: true))
        XCTAssertTrue(AudioDcSendOutcome.useRelay.controlFrameNeedsRelay(divertEnabled: false))
        XCTAssertTrue(AudioDcSendOutcome.shed.controlFrameNeedsRelay(divertEnabled: true))
        XCTAssertFalse(AudioDcSendOutcome.shed.controlFrameNeedsRelay(divertEnabled: false))
    }

    func testTheKillSwitchIsOnByDefaultAndFlips() {
        let sw = DcWedgeKillSwitch()
        XCTAssertTrue(sw.divertEnabled)
        sw.divertEnabled = false
        XCTAssertFalse(sw.divertEnabled)
        sw.divertEnabled = true
        XCTAssertTrue(sw.divertEnabled)
    }
}
