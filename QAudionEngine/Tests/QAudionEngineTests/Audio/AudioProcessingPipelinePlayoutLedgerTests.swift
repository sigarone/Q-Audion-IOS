import XCTest
@testable import QAudionEngine

#if canImport(AVFoundation)

/// W-IOSPLAYOUT (2026-07-25) — the player-node queue ledger, pinned.
///
/// `AVAudioPlayerNode` keeps its own queue of scheduled buffers, a second elastic store
/// downstream of everything the jitter buffer can see, and no counter observed it. A queue
/// that grows is standing latency the user hears as delay; a queue that empties is the gap
/// they hear as a dropout. Both were indistinguishable from each other and from a network
/// problem.
///
/// Three properties are worth a test rather than a comment. The depth must be a MAX, not a
/// last-value, or a backlog that recovered before teardown reports as healthy. An anomalous
/// completion must be COUNTED rather than clamped away, because the count is what tells a
/// reader whether to trust the max. And every counter must reset per call — the reset block
/// in `consumeAudioDiagStats` is long enough that a new field is easy to miss, and a missed
/// one silently attributes call N's numbers to call N+1.
///
/// Runs on the macOS CI runner: these are all plain `Int` accumulators behind the pipeline's
/// public API, with no `AVAudioEngine` and no live session involved.
final class AudioProcessingPipelinePlayoutLedgerTests: XCTestCase {

    func testPlayoutWritesCountEveryScheduledBuffer() {
        let p = AudioProcessingPipeline()
        for depth in 1...5 { p.notePlayoutScheduled(inFlightAfter: depth) }
        XCTAssertEqual(p.consumeAudioDiagStats().playoutWrites, 5)
    }

    func testInFlightIsAMaximumAndNotTheLastValue() {
        let p = AudioProcessingPipeline()
        // A backlog that builds to 12 and then drains. Reporting the final depth would
        // call this call healthy; the excursion IS the finding — 12 buffers is 240 ms of
        // standing delay.
        for depth in [1, 4, 9, 12, 7, 2, 1] { p.notePlayoutScheduled(inFlightAfter: depth) }
        let s = p.consumeAudioDiagStats()
        XCTAssertEqual(s.playoutInFlightMax, 12)
        XCTAssertEqual(s.playoutWrites, 7)
    }

    func testASteadyQueueReportsOne() {
        let p = AudioProcessingPipeline()
        // Healthy: each buffer is consumed before the next is scheduled.
        for _ in 0..<200 { p.notePlayoutScheduled(inFlightAfter: 1) }
        XCTAssertEqual(p.consumeAudioDiagStats().playoutInFlightMax, 1)
    }

    func testSchedFailIsSeparateFromPlayoutDropped() {
        let p = AudioProcessingPipeline()
        // Two different faults that look identical to the user: the engine was dead
        // (dropped), versus the engine was alive and our own scheduling code binned the
        // frame (sched_fail). Folding them together would lose which one to go fix.
        p.notePlayoutDropped()
        p.notePlayoutSchedFail()
        p.notePlayoutSchedFail()
        let s = p.consumeAudioDiagStats()
        XCTAssertEqual(s.playoutDropped, 1)
        XCTAssertEqual(s.playoutSchedFail, 2)
    }

    func testAnomaliesAreCountedSoTheMaxCanBeTrusted() {
        let p = AudioProcessingPipeline()
        p.notePlayoutScheduled(inFlightAfter: 3)
        p.notePlayoutLedgerAnomaly()
        p.notePlayoutLedgerAnomaly()
        let s = p.consumeAudioDiagStats()
        XCTAssertEqual(s.playoutLedgerAnomalies, 2)
        // The max still reports what it saw. It is a lower bound in this state, which is
        // precisely what a non-zero anomaly count is there to say.
        XCTAssertEqual(s.playoutInFlightMax, 3)
    }

    func testEveryLedgerCounterResetsForTheNextCall() {
        let p = AudioProcessingPipeline()
        p.notePlayoutScheduled(inFlightAfter: 9)
        p.notePlayoutSchedFail()
        p.notePlayoutLedgerAnomaly()
        _ = p.consumeAudioDiagStats()

        let next = p.consumeAudioDiagStats()
        XCTAssertEqual(next.playoutWrites, 0)
        XCTAssertEqual(next.playoutInFlightMax, 0)
        XCTAssertEqual(next.playoutSchedFail, 0)
        XCTAssertEqual(next.playoutLedgerAnomalies, 0)
    }

    func testAQuietCallReportsZerosRatherThanNothing() {
        // A call where playout never ran at all must still produce readable zeros: the
        // server renders absent as "X", and "X" on a leg that DID exist reads as a
        // telemetry gap rather than as silence.
        let s = AudioProcessingPipeline().consumeAudioDiagStats()
        XCTAssertEqual(s.playoutWrites, 0)
        XCTAssertEqual(s.playoutInFlightMax, 0)
        XCTAssertEqual(s.playoutSchedFail, 0)
        XCTAssertEqual(s.playoutLedgerAnomalies, 0)
    }
}

#endif
