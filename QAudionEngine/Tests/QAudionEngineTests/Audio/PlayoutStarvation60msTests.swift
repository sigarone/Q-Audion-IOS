import XCTest
@testable import QAudionEngine

/// C6 (2026-08-25 parity playbook) — the residual `aprof-60x256` coverage:
/// live playout at the 60 ms profile, and the invariant "the audio consumer
/// never starves" AT THAT PROFILE specifically.
///
/// Negotiation itself is NOT what this file tests — that is already
/// complete and unconditional (`AudioProfile.defaultProfile == long60x256`,
/// `AudioConstants.swift`'s W-ALL60 note; `CallCapabilities.swift`'s
/// `aprof60x256*` tags). What was missing is coverage of the RUNTIME
/// behaviour of `PlayoutJitterBuffer` once it is actually driven at 60 ms:
/// every existing test in `PlayoutJitterBufferTests.swift` constructs the
/// buffer with its DEFAULT 20 ms geometry, and `LongAudioReceiveTests`/
/// `FrameQuantisationInvariantsTests` only assert the derived TIER GEOMETRY
/// (watermark ordering, ms→frame conversion) at 60 ms — never actual
/// push/pop behaviour under that geometry.
///
/// Why 60 ms specifically matters, restated from the C6 spec: the
/// concealment budget is in TIME, not frames. A loss concealed at 20 ms
/// costs 20 ms of missing audio; the same SINGLE lost frame at 60 ms costs
/// 60 ms — three times as much per event, over a buffer whose absolute
/// integer geometry is also three times smaller (nominal=1, trim=2,
/// emergency=5 at 60 ms vs 4/7/15 at 20 ms — see `PlayoutJitterBuffer`'s own
/// `setInboundFrameDurationMs`). Small integers are exactly where an
/// off-by-one in a tier boundary stops being "one extra frame of latency"
/// and starts being "an entire tier with no band to fire in" — precisely
/// the class of regression this file's own history names (W-TRIMFLOOR:
/// "ZERO at 20 ms and 40 ms, where drainTarget is 1").
final class PlayoutStarvation60msTests: XCTestCase {

    /// 60 ms of PCM: 2880 samples, 5760 bytes — `AudioProfile.long60x256`'s
    /// frame size, matching `AudioConstants.maxBytesPerFrame`.
    private func frame60(amplitude: Int16) -> Data {
        let samples = 2880
        var d = Data(count: samples * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { p[i] = (i % 2 == 0) ? amplitude : -amplitude }
        }
        return d
    }
    private func loud60() -> Data { frame60(amplitude: 8000) }
    private func silent60() -> Data { frame60(amplitude: 10) }

    private func buffer60() -> PlayoutJitterBuffer {
        let jb = PlayoutJitterBuffer()
        jb.setInboundFrameDurationMs(60)
        return jb
    }

    // MARK: - THE invariant: every pop is either delivered or counted

    /// The literal statement of "the consumer never starves [silently]": a
    /// `nil` result from `popWithDriftCatchup` must ALWAYS be reflected in
    /// `underruns` — there is no third outcome where the consumer gets
    /// nothing and nothing records it. That silent-starvation shape is
    /// exactly what this class's own header doc says iOS shipped before
    /// W-IOSJITTER: "iOS reported nothing on the same call, not because it
    /// was healthy but because nothing was counting."
    ///
    /// Exercised across 200 ticks of randomised arrivals (0, 1, or 2 frames
    /// pushed before each pop) — a mix of empty ticks, steady ticks and
    /// small bursts, all at the 60 ms geometry specifically.
    func test60ms_everyStarvedPopIsCountedAsAnUnderrun() {
        let jb = buffer60()
        let loud = loud60()
        var rng = SystemRandomNumberGenerator()
        var observedAtLeastOneUnderrun = false
        for _ in 0..<200 {
            let arrivals = Int.random(in: 0...2, using: &rng)
            for _ in 0..<arrivals { jb.push(loud) }
            let before = jb.underruns
            let result = jb.popWithDriftCatchup()
            if result == nil {
                observedAtLeastOneUnderrun = true
                XCTAssertEqual(
                    jb.underruns, before + 1,
                    "a nil pop at the 60 ms profile must always increment `underruns` — " +
                    "a starved tick that goes uncounted is indistinguishable from a healthy one")
            }
        }
        XCTAssertTrue(observedAtLeastOneUnderrun,
                      "the arrival distribution (0...2 per tick, average 1) must produce at least " +
                      "one empty tick across 200 iterations, or this test is not exercising starvation")
    }

    // MARK: - Steady state at 60 ms

    /// Direct 60 ms analog of `testANominalQueueIsNeverDrained` — at nominal
    /// depth the buffer must simply deliver, no tier ever arms.
    func test60ms_nominalQueueNeverUnderrunsOrDrops() {
        let jb = buffer60()
        let nominal = jb.tierGeometryForTesting.nominal
        for _ in 0..<nominal { jb.push(loud60()) }
        for _ in 0..<nominal {
            XCTAssertNotNil(jb.popWithDriftCatchup(), "a nominal-depth 60 ms queue must never underrun")
        }
        XCTAssertEqual(0, jb.hardDrops)
        XCTAssertEqual(0, jb.silenceDrops)
        XCTAssertEqual(0, jb.underruns)
    }

    /// Direct 60 ms analog of `testASlowProducerUnderrunsAndDoesNotDrop`: a
    /// producer slightly slower than the consumer must show up ONLY as
    /// underruns, never as a drop — dropping audio that never had a
    /// surplus to reclaim would be strictly worse than the underrun it
    /// pretends to fix.
    func test60ms_slowProducerUnderrunsCleanlyNeverDrops() {
        let jb = buffer60()
        var delivered = 0
        // 100 consumer ticks, producer supplying 95 frames (5% arrival gap,
        // same shape as the 20 ms sibling test — this is the profile-
        // independent property, being re-asserted at the profile whose
        // integer geometry is smallest and therefore least forgiving).
        for tick in 0..<100 {
            if tick % 20 != 0 { jb.push(loud60()) }
            if jb.popWithDriftCatchup() != nil { delivered += 1 }
        }
        XCTAssertEqual(0, jb.hardDrops, "a slow producer must never trigger the drain at 60 ms either")
        XCTAssertGreaterThan(jb.underruns, 0, "and the shortfall must be visible as underruns")
        XCTAssertEqual(95, Int(jb.pushed))
        XCTAssertLessThanOrEqual(delivered, 95)
    }

    // MARK: - The treadmill, specifically at the profile it was worst on

    /// W-TRIMFLOOR re-run at 60 ms with REAL push/pop traffic (not just the
    /// derived-geometry assertions `FrameQuantisationInvariantsTests`
    /// already makes). At 60 ms: nominal=1, trim=2, high=3 — a queue of 4
    /// silent frames sits strictly between trim and emergency(5), so tier
    /// 1/2 fires with `highDropBudget=1`; the floor the tier must not
    /// breach is `nominal=1`. This is the exact shape of the historical bug
    /// (entering just above nominal, discarding down to AT or below it) at
    /// the profile whose small integers made `drainTarget`/`nominal`
    /// collapse to 1 and turned "one frame of margin" into "zero".
    func test60ms_trimNeverBreachesTheFloorItDefends() {
        let jb = buffer60()
        let g = jb.tierGeometryForTesting
        XCTAssertEqual(g.nominal, 1)
        XCTAssertEqual(g.trim, 2)
        XCTAssertEqual(g.high, 3)
        for _ in 0..<4 { jb.push(silent60()) }
        XCTAssertNotNil(jb.popWithDriftCatchup(), "pop must still deliver")
        XCTAssertGreaterThanOrEqual(
            jb.depth, g.nominal,
            "at the 60 ms profile a tier-2 firing left the queue at \(jb.depth), " +
            "below the floor of \(g.nominal) it must never breach")
    }

    /// The floor must not be satisfied by refusing to trim at all — a
    /// genuinely deep 60 ms backlog (all silence) still has to be worked
    /// down, or over-buffering becomes a permanent latency tax instead of a
    /// one-time correction.
    func test60ms_aGenuinelyDeepSilentBacklogIsStillTrimmed() {
        let jb = buffer60()
        let g = jb.tierGeometryForTesting
        // One below capacity, well past `high`, all silence.
        for _ in 0..<(g.capacity - 1) { jb.push(silent60()) }
        XCTAssertNotNil(jb.popWithDriftCatchup())
        XCTAssertGreaterThan(jb.silenceDrops + jb.hardDrops, 0,
                             "a deep 60 ms backlog of pure silence must still be reclaimed")
    }

    // MARK: - Burst recovery at 60 ms

    /// Direct 60 ms analog of `testTheDrainLatchActuallyReachesTheTarget`:
    /// the emergency drain must actually REACH `drainTarget` (1 frame at 60
    /// ms — see the class doc) and stay latched until it does, rather than
    /// gating on `depth >= watermark` and switching off the instant a
    /// single pop drops depth back under it.
    func test60ms_emergencyDrainReachesItsTargetAndStops() {
        let jb = buffer60()
        let g = jb.tierGeometryForTesting
        for _ in 0..<g.capacity { jb.push(loud60()) }   // fill to capacity: 10 frames
        var ticks = 0
        while jb.depth > g.drainTarget, ticks < 60 {
            _ = jb.popWithDriftCatchup()
            ticks += 1
        }
        XCTAssertLessThanOrEqual(jb.depth, g.drainTarget,
                                 "60 ms drain stalled at depth \(jb.depth) — the latch is not working")
        XCTAssertLessThan(ticks, 60, "took \(ticks) ticks to drain a 60 ms burst")
        // The bound that makes tier 3 acceptable: at 60 ms `maxDropsPerPop`
        // is 1 (one 60 ms frame — 60 ms of contiguous audio, the same
        // absolute-time ceiling the class doc states regardless of profile).
        XCTAssertEqual(g.maxDropsPerPop, 1)
    }
}
