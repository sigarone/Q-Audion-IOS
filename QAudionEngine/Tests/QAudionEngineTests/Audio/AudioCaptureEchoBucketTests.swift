import XCTest
import Foundation
@testable import QAudionEngine

/// W-IOSECHO (2026-07-22) — regression tests for the echo-cancellation
/// EFFECTIVENESS proxy: the iOS port of Android's W-SPKAEC/W-SPKECHO
/// `echo_active_*`/`echo_idle_*` telemetry (Android commits
/// fb6b9b7/caf6fcd/45d3618, `CallAudioBridge.gradeAndSuppressEcho` +
/// `bucketRmsPct`).
///
/// THE GAP THIS FILLS. Before this, iOS's `call.audio.diag` could only say
/// VP-IO was ever nominally on/bypassed (`vpio_ever_active`/
/// `vpio_bypassed_ever`) — never whether it actually cancelled anything.
/// Apple's VP-IO exposes no per-frame ERLE via public API, so the proxy here
/// classifies near-end mic RMS against whether the far end was RECENTLY
/// AUDIBLE (a level-based "AEC is under load" signal, not a hardware
/// echo-return-loss readout — see `AudioCapture.EchoBucketTotals` kdoc for
/// the full, honest limitations).
///
/// Pure arithmetic only — no AVFoundation, no AVAudioSession, no
/// AVAudioEngine — so this runs on the macOS CI runner via `swift test` (it
/// also runs under the iOS Simulator job; unlike `AudioProcessingPipeline`'s
/// route-observing code this needs no live audio session either way).
final class AudioCaptureEchoBucketTests: XCTestCase {

    // MARK: - isFarEndActive (the "AEC under load" proxy)

    func testFarEndNeverAudible_isNotActive() {
        // lastLoudPlayoutAtMs == 0 means "never" — must never read as active
        // even if `nowMs` is 0 too (0 - 0 <= holdMs would otherwise pass).
        XCTAssertFalse(AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: 0, nowMs: 0))
        XCTAssertFalse(AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: 0, nowMs: 100))
    }

    func testFarEndActive_withinHoldWindow() {
        // A loud RX frame 50 ms ago, 200 ms hold — still active.
        XCTAssertTrue(AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: 1_000, nowMs: 1_050))
    }

    func testFarEndActive_exactlyAtHoldBoundary_isStillActive() {
        // Boundary is inclusive (<=), matching Android's `sinceLoud <= DEFAULT_HOLD_MS`.
        XCTAssertTrue(AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: 1_000,
                                                   nowMs: 1_000 + AudioCapture.echoRefHoldMs))
    }

    func testFarEndIdle_justPastHoldWindow() {
        XCTAssertFalse(AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: 1_000,
                                                    nowMs: 1_000 + AudioCapture.echoRefHoldMs + 1))
    }

    func testFarEndActive_customHoldMs() {
        XCTAssertTrue(AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: 0 + 1, nowMs: 500, holdMs: 500))
        XCTAssertFalse(AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: 1, nowMs: 502, holdMs: 500))
    }

    // MARK: - isLoudPlayout (the RX-frame loudness gate)

    func testLoudPlayout_atOrAboveThreshold() {
        XCTAssertTrue(AudioCapture.isLoudPlayout(rms: AudioCapture.echoRefLoudRms))
        XCTAssertTrue(AudioCapture.isLoudPlayout(rms: 0.5))
    }

    func testLoudPlayout_belowThreshold() {
        XCTAssertFalse(AudioCapture.isLoudPlayout(rms: 0.001))
        XCTAssertFalse(AudioCapture.isLoudPlayout(rms: 0))
    }

    // MARK: - accumulatingEchoBucket (the split)

    func testAccumulatingEchoBucket_activeFrameGoesToActiveBucket() {
        let totals = AudioCapture.accumulatingEchoBucket(AudioCapture.EchoBucketTotals(),
                                                          frameRms: 0.1,
                                                          farEndActive: true)
        XCTAssertEqual(totals.activeFrames, 1)
        XCTAssertEqual(totals.idleFrames, 0)
        XCTAssertEqual(totals.activeSumSq, 0.01, accuracy: 1e-9)
        XCTAssertEqual(totals.idleSumSq, 0, accuracy: 1e-9)
    }

    func testAccumulatingEchoBucket_idleFrameGoesToIdleBucket() {
        let totals = AudioCapture.accumulatingEchoBucket(AudioCapture.EchoBucketTotals(),
                                                          frameRms: 0.02,
                                                          farEndActive: false)
        XCTAssertEqual(totals.activeFrames, 0)
        XCTAssertEqual(totals.idleFrames, 1)
        XCTAssertEqual(totals.idleSumSq, 0.0004, accuracy: 1e-9)
    }

    func testAccumulatingEchoBucket_foldsAcrossManyFrames() {
        var totals = AudioCapture.EchoBucketTotals()
        // Three "active" frames at 10% RMS, two "idle" frames at 1% RMS —
        // mirrors a speakerphone call where the far end talks most of the
        // time and the near end is otherwise quiet.
        for _ in 0..<3 {
            totals = AudioCapture.accumulatingEchoBucket(totals, frameRms: 0.10, farEndActive: true)
        }
        for _ in 0..<2 {
            totals = AudioCapture.accumulatingEchoBucket(totals, frameRms: 0.01, farEndActive: false)
        }
        XCTAssertEqual(totals.activeFrames, 3)
        XCTAssertEqual(totals.idleFrames, 2)
        XCTAssertEqual(totals.activeSumSq, 3 * 0.01, accuracy: 1e-9)
        XCTAssertEqual(totals.idleSumSq, 2 * 0.0001, accuracy: 1e-9)
    }

    // MARK: - bucketRmsPct (RMS-of-the-bucket, not mean-of-per-frame-RMS)

    func testBucketRmsPct_emptyBucketIsZero() {
        XCTAssertEqual(AudioCapture.bucketRmsPct(sumSq: 0, frames: 0), 0)
    }

    func testBucketRmsPct_singleFrame_matchesItsOwnRms() {
        // One 10%-RMS frame: sqrt(0.01 / 1) * 100 = 10.0
        XCTAssertEqual(AudioCapture.bucketRmsPct(sumSq: 0.01, frames: 1), 10.0, accuracy: 1e-9)
    }

    func testBucketRmsPct_isQuadraticMean_notArithmeticMeanOfRms() {
        // Two frames: RMS 0.0 and RMS 0.10. Arithmetic mean of the two RMS
        // values would be 5.0 %; the quadratic mean (what bucketRmsPct
        // actually computes, matching Android's formula) is
        // sqrt((0^2 + 0.10^2) / 2) * 100 = 7.07..%, strictly ABOVE the
        // arithmetic mean. This is the whole point of the RMS-over-the-
        // bucket formula (see kdoc): a single loud frame must not be
        // diluted away by quiet neighbours the way an arithmetic mean would.
        let sumSq = 0.0 * 0.0 + 0.10 * 0.10
        let pct = AudioCapture.bucketRmsPct(sumSq: sumSq, frames: 2)
        XCTAssertEqual(pct, 7.0710678, accuracy: 1e-5)
        XCTAssertGreaterThan(pct, 5.0)  // strictly above the arithmetic mean
    }

    // MARK: - End-to-end: an "echo leaking on speaker" call reads as expected

    func testEndToEnd_leakyEchoCallShowsActiveBucketLouderThanIdle() {
        var totals = AudioCapture.EchoBucketTotals()
        var lastLoudPlayoutAtMs: Int64 = 0
        let holdMs = AudioCapture.echoRefHoldMs

        // Simulate 10 mic frames, 20 ms apart, with the far end talking
        // loudly the whole time (a new loud RX frame arrives just before
        // every mic frame) and echo leaking into the mic at 8% RMS — vs a
        // control run where the far end never talks and the mic reads a
        // clean 1% room-noise floor.
        var nowMs: Int64 = 0
        for _ in 0..<10 {
            nowMs += 20
            lastLoudPlayoutAtMs = nowMs  // far end just produced a loud frame
            let farEndActive = AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: lastLoudPlayoutAtMs,
                                                            nowMs: nowMs, holdMs: holdMs)
            totals = AudioCapture.accumulatingEchoBucket(totals, frameRms: 0.08, farEndActive: farEndActive)
        }
        for _ in 0..<10 {
            nowMs += 20
            let farEndActive = AudioCapture.isFarEndActive(lastLoudPlayoutAtMs: lastLoudPlayoutAtMs,
                                                            nowMs: nowMs, holdMs: holdMs)
            totals = AudioCapture.accumulatingEchoBucket(totals, frameRms: 0.01, farEndActive: farEndActive)
        }

        XCTAssertEqual(totals.activeFrames, 10)
        XCTAssertEqual(totals.idleFrames, 10)
        let activePct = AudioCapture.bucketRmsPct(sumSq: totals.activeSumSq, frames: totals.activeFrames)
        let idlePct = AudioCapture.bucketRmsPct(sumSq: totals.idleSumSq, frames: totals.idleFrames)
        XCTAssertEqual(activePct, 8.0, accuracy: 1e-6)
        XCTAssertEqual(idlePct, 1.0, accuracy: 1e-6)
        // The signature of leaking echo: active bucket several times louder
        // than idle (here 8x) — this is exactly the ratio tune-report.py's
        // `echo_ratio` helper computes from these two fields.
        XCTAssertEqual(activePct / idlePct, 8.0, accuracy: 1e-6)
    }
}
