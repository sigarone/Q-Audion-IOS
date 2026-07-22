import XCTest
import Foundation
@testable import QAudionEngine

#if canImport(AVFoundation)
/// W-IOSECHO (2026-07-22) — regression tests for the `route_changes`/
/// `speaker_ms` telemetry fields (iOS port of Android's fields of the same
/// name — see `AudioCaptureEchoBucketTests` for the sibling
/// `echo_active_*`/`echo_idle_*` port).
///
/// The interval arithmetic (`AudioProcessingPipeline.nextSpeakerResidency`)
/// is pure and int-only — no `Date()`, no `AVAudioSession` — so it is tested
/// directly and deterministically here, same pattern as `AudioCapture`'s
/// `nextNoiseFloor`/`nextMakeUpAgcGain`. `noteRouteChange()`/
/// `consumeAudioDiagStats()`'s reset bookkeeping is exercised through the
/// public API since it involves no wall-clock timing.
///
/// NOTE ON WHERE THIS ACTUALLY RUNS: `AudioProcessingPipeline` (like
/// `AudioCapture`) sits behind `#if canImport(AVFoundation)`, and this whole
/// SPM package fails to COMPILE on the sibling macOS `swift test` CI job
/// (WebRTC ships no macOS slice — see `engine-tests.yml`'s own comment, that
/// job's exit code is masked intentionally). This file's tests therefore
/// only actually execute on the `ios-simulator-tests` CI job, which is real
/// AVFoundation on a real iOS Simulator — not a stub.
final class AudioProcessingPipelineRouteChangeTests: XCTestCase {

    // MARK: - nextSpeakerResidency (pure interval arithmetic)

    func testNoOpenInterval_noAccumulation() {
        let (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
            accumulatedMs: 0, sinceMs: 0, nowSpeaker: false, nowMs: 5_000)
        XCTAssertEqual(acc, 0)
        XCTAssertEqual(since, 0)
    }

    func testOpeningAnInterval_startsTheClockWithoutAccumulating() {
        // Route just flipped TO speaker: nothing to accumulate yet, but the
        // clock should start.
        let (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
            accumulatedMs: 0, sinceMs: 0, nowSpeaker: true, nowMs: 1_000)
        XCTAssertEqual(acc, 0)
        XCTAssertEqual(since, 1_000)
    }

    func testClosingAnInterval_accumulatesTheElapsedSpan() {
        // Speaker was engaged at t=1000; observed again (still speaker or
        // about to flip away) at t=1500 -> 500 ms of speaker residency.
        let (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
            accumulatedMs: 0, sinceMs: 1_000, nowSpeaker: false, nowMs: 1_500)
        XCTAssertEqual(acc, 500)
        XCTAssertEqual(since, 0)   // no longer accruing
    }

    func testStayingOnSpeakerAcrossMultipleRestarts_reopensImmediately() {
        // Engine restarts 3 times while the route STAYS on speaker the whole
        // time (e.g. VP-IO starve-watchdog restarts, or multiple unrelated
        // route notifications that all resolve to "still speaker"). Each
        // call closes the previous span and reopens a fresh one at the same
        // instant, so residency across the restarts is continuous — no gap,
        // no double count.
        var acc: Int64 = 0
        var since: Int64 = 0
        let ticks: [Int64] = [0, 300, 900, 2_000]  // call start + 3 restarts
        for t in ticks {
            (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
                accumulatedMs: acc, sinceMs: since, nowSpeaker: true, nowMs: t)
        }
        // Interval is still open (last observation was "speaker"); close it
        // at t=2500 to read the total, mirroring consumeAudioDiagStats().
        (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
            accumulatedMs: acc, sinceMs: since, nowSpeaker: false, nowMs: 2_500)
        XCTAssertEqual(acc, 2_500)  // continuous from t=0 to t=2500, no gaps
        XCTAssertEqual(since, 0)
    }

    func testSpeakerToggleThenBackToEarpiece_accumulatesOnlyTheSpeakerSpan() {
        var acc: Int64 = 0
        var since: Int64 = 0
        // t=0: call starts on earpiece (not speaker) — no interval opens.
        (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
            accumulatedMs: acc, sinceMs: since, nowSpeaker: false, nowMs: 0)
        XCTAssertEqual(since, 0)
        // t=1000: user taps speaker.
        (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
            accumulatedMs: acc, sinceMs: since, nowSpeaker: true, nowMs: 1_000)
        XCTAssertEqual(acc, 0)
        // t=4000: user taps back to earpiece — 3000 ms of speaker residency.
        (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
            accumulatedMs: acc, sinceMs: since, nowSpeaker: false, nowMs: 4_000)
        XCTAssertEqual(acc, 3_000)
        XCTAssertEqual(since, 0)
        // t=9000: teardown, still earpiece — no further accumulation.
        (acc, since) = AudioProcessingPipeline.nextSpeakerResidency(
            accumulatedMs: acc, sinceMs: since, nowSpeaker: false, nowMs: 9_000)
        XCTAssertEqual(acc, 3_000)
    }

    // MARK: - noteRouteChange / consumeAudioDiagStats (counter bookkeeping)

    func testNoteRouteChange_incrementsAndReportsInConsumeAudioDiagStats() {
        let pipeline = AudioProcessingPipeline()
        pipeline.noteRouteChange()
        pipeline.noteRouteChange()
        pipeline.noteRouteChange()
        let stats = pipeline.consumeAudioDiagStats()
        XCTAssertEqual(stats.routeChanges, 3)
    }

    func testConsumeAudioDiagStats_resetsRouteChangesForNextCall() {
        let pipeline = AudioProcessingPipeline()
        pipeline.noteRouteChange()
        _ = pipeline.consumeAudioDiagStats()
        let secondCall = pipeline.consumeAudioDiagStats()
        XCTAssertEqual(secondCall.routeChanges, 0)
    }

    func testEngineRestartAlone_doesNotCountAsRouteChange() {
        // W-VPIORETRY/W-AEC-FIX starve-watchdog restarts call
        // `noteEngineRestart()` but NOT `noteRouteChange()` — they rebuild
        // the engine on the SAME route, not a new one.
        let pipeline = AudioProcessingPipeline()
        pipeline.noteEngineRestart()
        pipeline.noteEngineRestart()
        let stats = pipeline.consumeAudioDiagStats()
        XCTAssertEqual(stats.engineRestarts, 2)
        XCTAssertEqual(stats.routeChanges, 0)
    }
}
#endif
