import XCTest
@testable import QAudionEngine

/// C3 acceptance criterion (parity plan Fase C3, 2026-08-25): "the 600 ms
/// cap is never breached under induced jitter."
///
/// `PlayoutJitterBuffer.push` enforces the cap by dropping the OLDEST frame
/// the instant the queue would exceed it (see `capFrames` / `overruns`),
/// independent of everything W-JBADAPT/W-JBSTRETCH add: the adaptive target
/// only ever moves the STEADY-STATE point the correction tiers aim for — it
/// can never raise the hard ceiling itself, which stays pinned to
/// `capacityMs` (600 ms) regardless of what the link has taught the
/// buffer. These tests exercise that under adversarial, unbounded-burst
/// jitter — the scenario the cap exists for — including the specific case
/// the W-JBADAPT design note flags as the one where depth is most "needed"
/// (the adaptive target pinned at its ceiling, where the correction tiers
/// stop firing by design).
final class PlayoutJitterBufferCapInvariantTests: XCTestCase {

    private func frame(samples: Int, amplitude: Int16 = 8000, seed: Int = 0) -> Data {
        var d = Data(count: samples * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { p[i] = (i + seed) % 2 == 0 ? amplitude : -amplitude }
        }
        return d
    }

    /// Unbounded push bursts (no pops at all — the worst case for the cap)
    /// at every frame duration `FrameQuantisationInvariantsTests` already
    /// establishes as reachable. `depth` must never exceed `capacity` at
    /// that cadence, and every push past the cap must be visible as an
    /// overrun — not a silently-grown queue.
    func test_capIsNeverBreached_underAnUnboundedPushBurst_atEveryReachableCadence() {
        for ms in [5, 10, 20, 40, 60] {
            let jb = PlayoutJitterBuffer()
            jb.setInboundFrameDurationMs(ms)
            let samples = AudioConstants.sampleRate / 1000 * ms
            let capacity = jb.tierGeometryForTesting.capacity
            for i in 0..<500 {
                jb.push(frame(samples: samples, seed: i))
                XCTAssertLessThanOrEqual(
                    jb.depth, capacity,
                    "depth \(jb.depth) exceeded capacity \(capacity) at \(ms) ms after \(i + 1) pushes")
            }
            XCTAssertEqual(capacity, jb.depth, "a sustained burst must settle AT capacity, not above it")
            XCTAssertGreaterThan(jb.overruns, 0, "500 pushes into a small capacity must overrun")
        }
    }

    /// Randomised jitter: bursts of 0-5 pushes before each pop, across 2000
    /// ticks. `depth` is asserted after EVERY push, not just at the end, so
    /// a transient breach mid-burst cannot hide behind a healthy final
    /// snapshot.
    func test_capIsNeverBreached_underRandomisedBurstyJitterWithPops() {
        let jb = PlayoutJitterBuffer()
        let capacity = jb.tierGeometryForTesting.capacity
        var rng = SystemRandomNumberGenerator()
        for tick in 0..<2000 {
            let arrivals = Int.random(in: 0...5, using: &rng)
            for i in 0..<arrivals {
                jb.push(frame(samples: 960, seed: tick * 10 + i))
                XCTAssertLessThanOrEqual(
                    jb.depth, capacity, "tick \(tick): depth \(jb.depth) exceeded capacity \(capacity)")
            }
            _ = jb.popWithDriftCatchup()
        }
    }

    /// The cap must hold even while the adaptive target sits pinned at its
    /// clamp ceiling (160 ms) — the scenario W-JBADAPT's own design note
    /// calls out as the one where the energy-gated correction tiers simply
    /// stop firing because the link genuinely needs the depth, i.e. the
    /// case most likely to press against the cap.
    func test_capIsNeverBreached_whileTheAdaptiveTargetIsPinnedAtItsCeiling() {
        var clockSeconds = 1.0
        let jb = PlayoutJitterBuffer(nowSeconds: { clockSeconds })
        let capacity = jb.tierGeometryForTesting.capacity
        // Every arrival pathologically late: pins the adaptive target at
        // adaptTargetMaxMs (mirrors
        // PlayoutJitterBufferAdaptiveTargetTests' matching convergence
        // test, `test_theCeilingClampHoldsAgainstAPathologicalLink`).
        for i in 0..<100 {
            clockSeconds += 0.5 // 500 ms gap
            jb.push(frame(samples: 960, seed: i))
            XCTAssertLessThanOrEqual(jb.depth, capacity)
        }
        XCTAssertEqual(PlayoutJitterBuffer.adaptTargetMaxMs, jb.adaptiveTargetMs)
        // Now burst well past capacity with the target pinned at the
        // ceiling — the cap is a property of `push`, not of the target.
        for i in 100..<200 {
            jb.push(frame(samples: 960, seed: i))
            XCTAssertLessThanOrEqual(jb.depth, capacity)
        }
        XCTAssertEqual(capacity, jb.depth)
    }

    /// Direct statement of the acceptance criterion at the default cadence:
    /// `capacity` resolves to exactly 600 ms of audio, not more, and `push`
    /// never lets the queue hold more frames than that regardless of how
    /// long the burst runs.
    func test_capacityAtTheDefaultCadence_isExactly600msOfAudio() {
        let jb = PlayoutJitterBuffer()
        let g = jb.tierGeometryForTesting
        XCTAssertEqual(g.capacity * g.frameMs, 600, "capacity must resolve to exactly the stated 600 ms")
        for i in 0..<(g.capacity * 3) {
            jb.push(frame(samples: 960, seed: i))
        }
        XCTAssertEqual(g.capacity, jb.depth)
    }
}
