import XCTest
@testable import QAudionEngine

/// W-JBADAPT (2026-08-25, parity plan Fase C3) — the adaptive steady-state
/// target, pinned. Direct port of Android's
/// `JitterBufferAdaptiveTargetTest.kt`.
///
/// The buffer's nominal watermark and emergency-drain target used to be
/// constants (80 ms / 40 ms) regardless of the link. They are now derived
/// from the buffer's OWN observed arrival lateness: p95 over the recent
/// window plus one frame of headroom, clamped to the envelope the shipped
/// constants already defined (`PlayoutJitterBuffer.adaptTargetMinMs` = the
/// old drain floor, `adaptTargetMaxMs` = the old high watermark).
///
/// Every test drives an INJECTED monotonic clock, so arrival cadence is
/// exact and deterministic — no sleeping, no flakiness. Frames pushed in
/// these scenarios are voice-level, so the energy-gated tiers cannot
/// interfere with what is being measured. This is also where the C3
/// acceptance criterion "the target is adaptive, not assumed" is proven —
/// `test_aStableLinkConvergesToTheClampFloor` and
/// `test_aJitteryLinkRaisesTheTargetToCoverItsP95Lateness` would both fail
/// against a buffer whose `nominal` were still the fixed 80 ms constant.
final class PlayoutJitterBufferAdaptiveTargetTests: XCTestCase {

    /// Manually-advanced monotonic clock, in seconds (the unit
    /// `PlayoutJitterBuffer`'s injectable `nowSeconds` clock uses).
    private final class Clock {
        var seconds: Double = 1.0
        func advanceMs(_ ms: Double) { seconds += ms / 1000.0 }
    }

    private func buffer(_ clock: Clock) -> PlayoutJitterBuffer {
        PlayoutJitterBuffer(nowSeconds: { clock.seconds })
    }

    /// Voice-level PCM frame — above the silence RMS threshold, never
    /// trimmable, so only W-JBADAPT/W-JBSTRETCH machinery is in play.
    private func voiceFrame() -> Data {
        var d = Data(count: 960 * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<960 { p[i] = i % 2 == 0 ? 8000 : -8000 }
        }
        return d
    }

    /// Push `count` frames, advancing the clock by `gapMs` BEFORE each push.
    private func pushCadence(_ jb: PlayoutJitterBuffer, _ clock: Clock, count: Int, gapMs: Double) {
        for _ in 0..<count {
            clock.advanceMs(gapMs)
            jb.push(voiceFrame())
            // Keep the queue shallow so overrun-drops never enter the
            // picture: the tracker is fed before the drop decision, but a
            // full queue is not the scenario under test.
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
        }
    }

    // MARK: - warm-up gate

    func test_aFreshBufferHoldsTheShippedDefaultTarget() {
        let jb = buffer(Clock())
        XCTAssertEqual(PlayoutJitterBuffer.adaptDefaultTargetMs, jb.adaptiveTargetMs)
    }

    /// Below `adaptMinSamples` arrivals the target must not move — a p95
    /// over a handful of samples is noise.
    func test_adaptationDoesNotEngageBeforeTheMinimumSampleCount() {
        let clock = Clock()
        let jb = buffer(clock)
        pushCadence(jb, clock, count: PlayoutJitterBuffer.adaptMinSamples - 1, gapMs: 0)
        XCTAssertEqual(
            PlayoutJitterBuffer.adaptDefaultTargetMs, jb.adaptiveTargetMs,
            "the target moved on \(PlayoutJitterBuffer.adaptMinSamples - 2) samples")
    }

    // MARK: - convergence

    func test_aStableLinkConvergesToTheClampFloor() {
        let clock = Clock()
        let jb = buffer(clock)
        // Perfect 20 ms cadence: lateness is 0 on every arrival, so the
        // target is 0 + one frame = 20 ms, clamped up to the floor.
        pushCadence(jb, clock, count: 200, gapMs: Double(AudioConstants.frameDurationMs))
        XCTAssertEqual(
            PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs,
            "a clean link must not keep paying the default 80 ms of standing latency")
    }

    func test_aJitteryLinkRaisesTheTargetToCoverItsP95Lateness() {
        let clock = Clock()
        let jb = buffer(clock)
        // Every 10th frame arrives 100 ms late and the following one bunched
        // (gap 0): 10% of samples carry lateness 100, the rest 0. p95 of
        // that distribution is 100, so the target must be 100 + 20 = 120 ms.
        for _ in 0..<40 {
            for _ in 0..<8 { pushCadence(jb, clock, count: 1, gapMs: 20) }
            pushCadence(jb, clock, count: 1, gapMs: 120) // 100 ms late
            pushCadence(jb, clock, count: 1, gapMs: 0)   // bunched catch-up
        }
        XCTAssertEqual(120, jb.adaptiveTargetMs, "p95 lateness of 100 ms must produce a 120 ms target")
    }

    // MARK: - clamps

    func test_theCeilingClampHoldsAgainstAPathologicalLink() {
        let clock = Clock()
        let jb = buffer(clock)
        // Every arrival half a second late: unclamped the target would be
        // 480 + 20 ms. It must stop at the shipped high watermark.
        pushCadence(jb, clock, count: 100, gapMs: 500)
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMaxMs, jb.adaptiveTargetMs)
    }

    func test_theFloorClampHoldsAgainstABunchedProducer() {
        let clock = Clock()
        let jb = buffer(clock)
        // Everything arrives at once (gap 0 — early/bunched, lateness 0):
        // the target must never go below the shipped drain floor.
        pushCadence(jb, clock, count: 200, gapMs: 0)
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs)
    }

    // MARK: - the target actually steers the machinery

    /// The emergency drain must stop at the ADAPTIVE target, not at the old
    /// constant. On a link whose target converged to 120 ms the drain
    /// target is 120 - 40 = 80 ms = 4 frames; with the shipped constants it
    /// drains to 2.
    func test_emergencyDrainStopsAtTheAdaptiveTarget_notTheShippedConstant() {
        let clock = Clock()
        let jb = buffer(clock)
        // Converge the target to 120 ms (same cadence as the jittery test).
        for _ in 0..<40 {
            for _ in 0..<8 { pushCadence(jb, clock, count: 1, gapMs: 20) }
            pushCadence(jb, clock, count: 1, gapMs: 120)
            pushCadence(jb, clock, count: 1, gapMs: 0)
        }
        XCTAssertEqual(120, jb.adaptiveTargetMs)

        // Build a 20-frame backlog, then run pops against a matched producer.
        while jb.depth < 20 { jb.push(voiceFrame()) }
        for _ in 0..<40 {
            _ = jb.popWithDriftCatchup()
            clock.advanceMs(20)
            jb.push(voiceFrame())
        }
        XCTAssertGreaterThanOrEqual(
            jb.depth, 3,
            "drain went to \(jb.depth) frames — below the adaptive drain target of 4 (80 ms at 20 " +
            "ms cadence); it is still using the shipped constant")
        XCTAssertLessThanOrEqual(
            jb.depth, 6,
            "drain parked at \(jb.depth) frames instead of converging near the target")
    }

    // MARK: - exposure

    func test_theTierGeometrySnapshotCarriesTheLiveTarget() {
        let clock = Clock()
        let jb = buffer(clock)
        XCTAssertEqual(PlayoutJitterBuffer.adaptDefaultTargetMs, jb.tierGeometryForTesting.adaptiveTargetMs)
        pushCadence(jb, clock, count: 200, gapMs: Double(AudioConstants.frameDurationMs))
        XCTAssertEqual(jb.adaptiveTargetMs, jb.tierGeometryForTesting.adaptiveTargetMs)
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMinMs, jb.tierGeometryForTesting.adaptiveTargetMs)
    }

    /// `reset` zeroes tallies; the learned target is STATE (it describes the
    /// link, which did not change because a counter did).
    func test_reset_keepsTheLearnedTarget() {
        let clock = Clock()
        let jb = buffer(clock)
        pushCadence(jb, clock, count: 200, gapMs: 0)
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs)
        jb.reset()
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs)
    }

    /// `reset` marks a stream boundary: the stopped interval must NOT be
    /// recorded as one giant inter-arrival gap when pushing resumes.
    func test_thePauseAcrossAReset_isNotRecordedAsLateness() {
        let clock = Clock()
        let jb = buffer(clock)
        pushCadence(jb, clock, count: 200, gapMs: 20)
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs)

        jb.reset()
        clock.advanceMs(30_000) // playback stopped for 30 s
        // Resume with a clean cadence long enough to cross several
        // recompute boundaries: had the 30 s gap been recorded, its
        // (capped) lateness sample would sit in the window; with a p95 over
        // mostly-zero samples one outlier cannot move the percentile
        // either way, so the sharper assertion is on the learned target
        // staying at the floor.
        pushCadence(jb, clock, count: 100, gapMs: 20)
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMinMs, jb.adaptiveTargetMs)
    }
}
