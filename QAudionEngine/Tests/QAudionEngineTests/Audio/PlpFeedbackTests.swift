import XCTest
@testable import QAudionEngine

/// W-PLPFEEDBACK (2026-08-25) — the pure logic behind the PLP: closed loop:
/// `FrameLossMeter` (RX loss measurement) and `PlpPolicy` (the encoder knob
/// it drives). Both are direct ports of the shipped Android implementation,
/// so these tests pin the same three hazards `FrameLossMeter`'s own doc
/// names — reordering, duplicates, counter resets — plus `PlpPolicy`'s
/// fast-up/slow-decay asymmetry.
final class FrameLossMeterTests: XCTestCase {

    func testNoLossWhenEveryFrameArrives() {
        let m = FrameLossMeter()
        for seq in Int64(0)..<10 { m.onFrame(seq: seq) }
        XCTAssertEqual(m.expected, 10)
        XCTAssertEqual(m.received, 10)
        XCTAssertEqual(m.lost, 0)
    }

    func testASimpleGapIsCountedAsLoss() {
        let m = FrameLossMeter()
        m.onFrame(seq: 0)
        m.onFrame(seq: 1)
        // 2, 3, 4 never arrive.
        m.onFrame(seq: 5)
        XCTAssertEqual(m.expected, 6)   // 0...5
        XCTAssertEqual(m.received, 3)
        XCTAssertEqual(m.lost, 3)
        XCTAssertEqual(m.lossPct, 50.0, accuracy: 0.01)
    }

    /// REORDERING — a late frame must not count as lost and then un-count.
    func testReorderingDoesNotCorruptTheSpan() {
        let m = FrameLossMeter()
        m.onFrame(seq: 0)
        m.onFrame(seq: 2)
        m.onFrame(seq: 1)  // arrives late, after 2
        XCTAssertEqual(m.expected, 3)   // 0, 1, 2
        XCTAssertEqual(m.received, 3)
        XCTAssertEqual(m.lost, 0)
    }

    /// DUPLICATES — a replay must not push loss negative.
    func testDuplicatesAreCountedSeparatelyAndNeverGoNegative() {
        let m = FrameLossMeter()
        m.onFrame(seq: 0)
        m.onFrame(seq: 1)
        m.onFrame(seq: 1)  // replay
        XCTAssertEqual(m.expected, 2)
        XCTAssertEqual(m.lost, 0, "a duplicate must never make loss negative")
        XCTAssertEqual(m.duplicates, 1)
    }

    /// RESETS — a re-key restarts the sender's counter at (near) zero. A
    /// naive meter would read a huge backward jump as catastrophic loss; the
    /// real one folds the old span and re-anchors. `resetGap` is 50, so the
    /// span has to be wider than that for a return to 0 to register as a
    /// restart rather than an ordinary late/duplicate arrival.
    func testALargeBackwardJumpIsReadAsACounterResetNotAsLoss() {
        let m = FrameLossMeter()
        for seq in Int64(0)..<60 { m.onFrame(seq: seq) }
        XCTAssertEqual(m.lost, 0)
        m.onFrame(seq: 0)  // counter restarted
        XCTAssertEqual(m.resets, 1)
        // The closed span (0...59, all received) still counts, plus the new
        // span's first frame — nothing here should read as "lost".
        XCTAssertEqual(m.expected, 61)
        XCTAssertEqual(m.received, 61)
        XCTAssertEqual(m.lost, 0)
    }

    func testResetRestoresAFreshMeter() {
        let m = FrameLossMeter()
        m.onFrame(seq: 5)
        m.onFrame(seq: 9)
        m.reset()
        XCTAssertEqual(m.expected, 0)
        XCTAssertEqual(m.received, 0)
        XCTAssertEqual(m.lost, 0)
        XCTAssertEqual(m.duplicates, 0)
        XCTAssertEqual(m.resets, 0)
    }

    func testNegativeSequenceIsIgnored() {
        let m = FrameLossMeter()
        m.onFrame(seq: -1)
        XCTAssertEqual(m.expected, 0, "a negative seq must not anchor the span")
    }
}

final class PlpPolicyTests: XCTestCase {

    /// `obs > cur` is false when they are EQUAL, so this takes the decay
    /// branch — but the floor (`maxOf(cur - step, obs, minPct)`) holds it at
    /// the observed rate rather than stepping under it. This is the
    /// stability property `PlpPolicy`'s own doc names: a decay that
    /// undershot a persistent rate would trip fast-up on the very next call.
    func testHoldsSteadyWhenObservedEqualsCurrent() {
        XCTAssertEqual(PlpPolicy.next(currentPct: 20, observedLossPct: 20), 20)
    }

    /// FAST UP — loss above the current setting jumps straight to
    /// observed + headroom, not a gradual climb.
    func testFastUpJumpsAboveTheObservedRate() {
        let next = PlpPolicy.next(currentPct: 10, observedLossPct: 25)
        XCTAssertEqual(next, 25 + PlpPolicy.upHeadroomPct)
    }

    func testFastUpNeverExceedsTheCeiling() {
        let next = PlpPolicy.next(currentPct: 10, observedLossPct: 95)
        XCTAssertEqual(next, PlpPolicy.maxPct)
    }

    /// SLOW DECAY — loss below current steps down gradually, never below
    /// the observed rate itself.
    func testSlowDecayStepsDownButNotBelowObserved() {
        let next = PlpPolicy.next(currentPct: 30, observedLossPct: 1)
        XCTAssertEqual(next, 28, "decays by exactly decayStepPct when far above observed")
    }

    func testDecayNeverUndershootsTheObservedRate() {
        // current=12, observed=11: decaying by the full step (2) would land
        // at 10, UNDER the observed rate — the floor must hold at ceil(11)=11.
        let next = PlpPolicy.next(currentPct: 12, observedLossPct: 11)
        XCTAssertEqual(next, 11)
    }

    func testNeverDecaysBelowTheFloor() {
        let next = PlpPolicy.next(currentPct: PlpPolicy.minPct, observedLossPct: 0)
        XCTAssertEqual(next, PlpPolicy.minPct)
    }

    /// STABILITY — the property that makes the pair not oscillate: a steady
    /// loss rate converges and then HOLDS, it does not bounce between the
    /// fast-up and slow-decay branches forever.
    func testAConvergedSteadyLossRateHoldsExactly() {
        var cur = PlpPolicy.minPct
        let steady = 15.0
        for _ in 0..<20 { cur = PlpPolicy.next(currentPct: cur, observedLossPct: steady) }
        let settled = cur
        let again = PlpPolicy.next(currentPct: settled, observedLossPct: steady)
        XCTAssertEqual(again, settled, "a converged steady rate must not keep moving")
    }

    func testOutOfContractCurrentValueIsCoercedIntoRange() {
        XCTAssertEqual(PlpPolicy.next(currentPct: 0, observedLossPct: .nan), PlpPolicy.minPct)
        XCTAssertEqual(PlpPolicy.next(currentPct: 999, observedLossPct: .nan), PlpPolicy.maxPct)
    }

    func testNonFiniteObservedHoldsTheCurrentValue() {
        XCTAssertEqual(PlpPolicy.next(currentPct: 17, observedLossPct: .nan), 17)
    }

    // MARK: - W-PLPBWTIER (2026-08-26) — route-tier-aware floor

    func testMinPctForRouteTier_relayRaisesTheFloor_directAndUnknownDoNot() {
        XCTAssertEqual(PlpPolicy.minPct(for: .relay), 10)
        XCTAssertEqual(PlpPolicy.minPct(for: .direct), PlpPolicy.minPct)
        XCTAssertEqual(PlpPolicy.minPct(for: .unknown), PlpPolicy.minPct)
    }

    /// The route-tier overload with `.direct`/`.unknown` must behave
    /// BYTE-IDENTICALLY to the base overload — no behavior change for the
    /// common (non-relay) case.
    func testRouteTierOverload_matchesBaseOverload_onDirectAndUnknown() {
        for tier: RouteTier in [.direct, .unknown] {
            XCTAssertEqual(
                PlpPolicy.next(currentPct: 10, observedLossPct: 25, routeTier: tier),
                PlpPolicy.next(currentPct: 10, observedLossPct: 25))
            XCTAssertEqual(
                PlpPolicy.next(currentPct: 30, observedLossPct: 1, routeTier: tier),
                PlpPolicy.next(currentPct: 30, observedLossPct: 1))
        }
    }

    /// The whole point: on a relay call, a clean report (0% loss) must not
    /// decay below the RAISED floor (10), even though the base policy would
    /// happily decay all the way to its own floor (5) on the same input.
    func testRelayTier_neverDecaysBelowTheRaisedFloor() {
        let next = PlpPolicy.next(currentPct: 20, observedLossPct: 0, routeTier: .relay)
        XCTAssertEqual(next, 10)
        XCTAssertLessThan(PlpPolicy.next(currentPct: 20, observedLossPct: 0), 10, "sanity: base policy WOULD have gone lower")
    }

    /// A caller arriving with a value below the relay floor (e.g. the
    /// compile-time default, or a value the base policy produced before the
    /// route resolved) is coerced UP to the relay floor on entry, same
    /// coercion discipline as the base overload's own `currentPct` clamp.
    func testRelayTier_coercesASubFloorCurrentValueUpOnEntry() {
        let next = PlpPolicy.next(currentPct: 0, observedLossPct: 0, routeTier: .relay)
        XCTAssertEqual(next, 10)
    }

    /// Fast-up and the ceiling are UNCHANGED by route tier — only the floor
    /// moves.
    func testRelayTier_doesNotChangeFastUpOrTheCeiling() {
        XCTAssertEqual(
            PlpPolicy.next(currentPct: 10, observedLossPct: 25, routeTier: .relay),
            25 + PlpPolicy.upHeadroomPct)
        XCTAssertEqual(
            PlpPolicy.next(currentPct: 10, observedLossPct: 95, routeTier: .relay),
            PlpPolicy.maxPct)
    }
}
