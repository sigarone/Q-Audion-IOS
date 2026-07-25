import XCTest
@testable import QAudionEngine

/// W-IOSJITTER — the properties that make the catch-up tiers safe.
///
/// Each case corresponds to an artefact Android earned the hard way, so the port
/// inherits the fixes rather than the regressions. The names mirror
/// `JitterBufferDrainBudgetTest.kt` where they overlap.
final class PlayoutJitterBufferTests: XCTestCase {

    private func frame(amplitude: Int16, samples: Int = 960) -> Data {
        var d = Data(count: samples * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { p[i] = (i % 2 == 0) ? amplitude : -amplitude }
        }
        return d
    }
    private func loud() -> Data { frame(amplitude: 8000) }
    private func silent() -> Data { frame(amplitude: 10) }

    // MARK: - The bound that makes tier 3 acceptable

    func testEmergencyDrainNeverExceedsTheBudget() {
        for depth in [15, 20, 30, 100] {
            let b = PlayoutJitterBuffer.emergencyDrainBudget(
                depth: depth, emergencyWatermark: 15, drainTarget: 2, maxDropsPerPop: 3, draining: false)
            XCTAssertLessThanOrEqual(b, 3, "depth \(depth) asked to drop \(b) frames at once")
            XCTAssertGreaterThanOrEqual(b, 0)
        }
    }

    func testTierDoesNotFireBelowItsWatermark() {
        XCTAssertEqual(0, PlayoutJitterBuffer.emergencyDrainBudget(
            depth: 14, emergencyWatermark: 15, drainTarget: 2, maxDropsPerPop: 3, draining: false))
    }

    func testTierNeverDrainsBelowTheTarget() {
        // depth 3, target 2: exactly one frame of excess, so at most one drop.
        XCTAssertEqual(1, PlayoutJitterBuffer.emergencyDrainBudget(
            depth: 3, emergencyWatermark: 15, drainTarget: 2, maxDropsPerPop: 3, draining: true))
        XCTAssertEqual(0, PlayoutJitterBuffer.emergencyDrainBudget(
            depth: 2, emergencyWatermark: 15, drainTarget: 2, maxDropsPerPop: 3, draining: true))
    }

    /// THE latch. Without it the tier gates on `depth >= watermark`, switches off
    /// the moment depth falls under it, never reaches the target, and leaves the
    /// spike behind as permanent standing latency — measured on Android as a
    /// settle at 14 frames, 280 ms, for the rest of the call.
    func testTheDrainLatchActuallyReachesTheTarget() {
        let jb = PlayoutJitterBuffer()
        for _ in 0..<20 { jb.push(loud()) }        // a burst: depth 20
        var ticks = 0
        while jb.depth > PlayoutJitterBuffer.emergencyDrainTarget && ticks < 60 {
            _ = jb.popWithDriftCatchup()
            ticks += 1
        }
        XCTAssertLessThanOrEqual(jb.depth, PlayoutJitterBuffer.emergencyDrainTarget,
                                 "drain stalled at depth \(jb.depth) — the latch is not working")
        XCTAssertLessThan(ticks, 60, "took \(ticks) ticks to drain")
    }

    // MARK: - Steady state

    func testANominalQueueIsNeverDrained() {
        let jb = PlayoutJitterBuffer()
        for _ in 0..<PlayoutJitterBuffer.nominalWatermark { jb.push(loud()) }
        for _ in 0..<PlayoutJitterBuffer.nominalWatermark {
            XCTAssertNotNil(jb.popWithDriftCatchup())
        }
        XCTAssertEqual(0, jb.hardDrops)
        XCTAssertEqual(0, jb.silenceDrops)
    }

    func testAnEmptyQueueUnderrunsAndSaysSo() {
        let jb = PlayoutJitterBuffer()
        XCTAssertNil(jb.popWithDriftCatchup())
        XCTAssertEqual(1, jb.underruns)
    }

    /// The queue must never become an unbounded latency sink.
    func testCapacityIsEnforcedAndCounted() {
        let jb = PlayoutJitterBuffer()
        for _ in 0..<(PlayoutJitterBuffer.capacityFrames + 10) { jb.push(loud()) }
        XCTAssertEqual(PlayoutJitterBuffer.capacityFrames, jb.depth)
        XCTAssertEqual(10, jb.overruns)
    }

    // MARK: - Tiers 1/2 discard only what is inaudible

    func testSilentFramesAreThePreferredThingToDrop() {
        let jb = PlayoutJitterBuffer()
        // Depth above the tier-2 watermark, alternating silence and speech.
        for i in 0..<12 { jb.push(i % 2 == 0 ? silent() : loud()) }
        _ = jb.popWithDriftCatchup()
        XCTAssertGreaterThan(jb.silenceDrops, 0, "tier 2 should have skipped silence")
        XCTAssertEqual(0, jb.hardDrops, "and must not have hard-dropped anything yet")
    }

    /// A backlog of pure SPEECH cannot be walked down by skipping silence, so
    /// tier 2 must give up rather than delete audible audio.
    func testATierTwoBacklogOfSpeechIsNotSilentlyDeleted() {
        let jb = PlayoutJitterBuffer()
        for _ in 0..<10 { jb.push(loud()) }   // between high and emergency
        let got = jb.popWithDriftCatchup()
        XCTAssertNotNil(got)
        XCTAssertEqual(0, jb.silenceDrops)
        XCTAssertEqual(0, jb.hardDrops)
    }

    func testSilenceDetectionMatchesTheThreshold() {
        XCTAssertTrue(PlayoutJitterBuffer.isSilent(silent()))
        XCTAssertFalse(PlayoutJitterBuffer.isSilent(loud()))
        XCTAssertTrue(PlayoutJitterBuffer.isSilent(Data()), "an empty frame is not audible")
    }

    // MARK: - The property the whole thing exists for

    /// A producer running slightly slow must not make the buffer thrash: the
    /// consumer underruns at the difference and nothing else happens. This is the
    /// 47.6 Hz-against-50 Hz case measured on call 807ae1d5.
    func testASlowProducerUnderrunsAndDoesNotDrop() {
        let jb = PlayoutJitterBuffer()
        var delivered = 0
        // 100 consumer ticks, producer supplying 95 frames.
        for tick in 0..<100 {
            if tick % 20 != 0 { jb.push(loud()) }
            if jb.popWithDriftCatchup() != nil { delivered += 1 }
        }
        XCTAssertEqual(0, jb.hardDrops, "a slow producer must never trigger the drain")
        XCTAssertGreaterThan(jb.underruns, 0, "and the shortfall must be visible as underruns")
        XCTAssertEqual(95, Int(jb.pushed))
        XCTAssertLessThanOrEqual(delivered, 95)
    }
}
