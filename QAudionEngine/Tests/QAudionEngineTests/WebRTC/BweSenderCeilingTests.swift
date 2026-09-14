import XCTest
@testable import QAudionEngine

/// W-BWECOMPOSE (2026-08-27, best-practices audit item 1) — pins the
/// asymmetric-hysteresis GoogCC BWE ceiling composed into
/// `applyComposedVideoSenderClamp` alongside route-tier/backpressure/VBWCAP:
/// decrease immediately on a lower reading, require `recoverPolls`
/// consecutive higher readings before raising the ceiling back up. Same
/// style as `RouteTierDwellTests` for its `RouteTierDwell` sibling.
final class BweSenderCeilingTests: XCTestCase {

    // MARK: - Constants

    func test_constants() {
        XCTAssertEqual(BweSenderCeiling.marginFactor, 0.85)
        XCTAssertEqual(BweSenderCeiling.recoverPolls, 3)
    }

    // MARK: - Default state: no constraint until a real sample arrives

    func test_initialState_noConstraint() {
        let ceiling = BweSenderCeiling()
        XCTAssertEqual(ceiling.ceilingBps, .max)
    }

    // MARK: - First-ever sample commits immediately (mirrors RouteTierDwell's
    // "first resolution from .unknown" rule, applied here to the .max sentinel)

    func test_firstSample_commitsImmediately() {
        var ceiling = BweSenderCeiling()
        XCTAssertTrue(ceiling.observe(rawAvailableOutgoingBps: 1_000_000))
        XCTAssertEqual(ceiling.ceilingBps, Int(1_000_000 * 0.85))
    }

    // MARK: - Decrease: applied immediately, single sample, no dwell

    func test_lowerReading_appliesImmediately() {
        var ceiling = BweSenderCeiling()
        ceiling.observe(rawAvailableOutgoingBps: 2_000_000)
        let firstCeiling = ceiling.ceilingBps
        XCTAssertTrue(ceiling.observe(rawAvailableOutgoingBps: 500_000))
        XCTAssertLessThan(ceiling.ceilingBps, firstCeiling)
        XCTAssertEqual(ceiling.ceilingBps, Int(500_000 * 0.85))
    }

    // MARK: - Increase: requires `recoverPolls` (3) consecutive higher readings

    func test_higherReading_singlePoll_doesNotRaise() {
        var ceiling = BweSenderCeiling()
        ceiling.observe(rawAvailableOutgoingBps: 500_000)
        let lowCeiling = ceiling.ceilingBps
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertEqual(ceiling.ceilingBps, lowCeiling, "a single higher reading must not raise the ceiling")
    }

    func test_higherReading_commitsOnThirdConsecutivePoll() {
        var ceiling = BweSenderCeiling()
        ceiling.observe(rawAvailableOutgoingBps: 500_000)
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertTrue(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertEqual(ceiling.ceilingBps, Int(2_000_000 * 0.85))
    }

    func test_higherReading_interruptedStreak_resetsCount() {
        var ceiling = BweSenderCeiling()
        ceiling.observe(rawAvailableOutgoingBps: 500_000)
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        // A lower reading mid-streak both applies immediately AND must
        // reset the healthy-streak counter — the next two higher readings
        // alone must not be enough to raise back to 2_000_000.
        XCTAssertTrue(ceiling.observe(rawAvailableOutgoingBps: 100_000))
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertTrue(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
    }

    // MARK: - Equal reading is a no-op, resets the healthy-streak counter

    func test_equalReading_isNoOp_andResetsStreak() {
        var ceiling = BweSenderCeiling()
        ceiling.observe(rawAvailableOutgoingBps: 1_000_000)
        let committed = ceiling.ceilingBps
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000)) // streak = 1
        // Exactly the current ceiling (after margin) — no raw value maps to
        // this directly except re-feeding the same raw sample.
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 1_000_000))
        XCTAssertEqual(ceiling.ceilingBps, committed)
        // Streak was reset by the equal reading — two more higher readings
        // (not three) must still be insufficient to raise.
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 2_000_000))
        XCTAssertEqual(ceiling.ceilingBps, committed)
    }

    // MARK: - Absent/invalid samples (<= 0, matching the read site's -1.0
    // sentinel) leave the held ceiling untouched — no reset to .max.

    func test_absentSample_leavesCeilingUntouched() {
        var ceiling = BweSenderCeiling()
        ceiling.observe(rawAvailableOutgoingBps: 1_000_000)
        let committed = ceiling.ceilingBps
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: -1.0))
        XCTAssertEqual(ceiling.ceilingBps, committed, "a missed poll must not remove a real constraint")
    }

    func test_zeroSample_isTreatedAsAbsent() {
        var ceiling = BweSenderCeiling()
        XCTAssertFalse(ceiling.observe(rawAvailableOutgoingBps: 0))
        XCTAssertEqual(ceiling.ceilingBps, .max)
    }

    // MARK: - reset()

    func test_reset_clearsCeilingAndStreak() {
        var ceiling = BweSenderCeiling()
        ceiling.observe(rawAvailableOutgoingBps: 500_000)
        ceiling.reset()
        XCTAssertEqual(ceiling.ceilingBps, .max)
        // Post-reset, the next observation is treated as a first-ever
        // sample again (commits immediately).
        XCTAssertTrue(ceiling.observe(rawAvailableOutgoingBps: 500_000))
    }

    // MARK: - Never raises the ceiling above what a single sample implies —
    // only ever narrows toward it, in line with the "additional narrowing
    // clamp" contract `applyComposedVideoSenderClamp` relies on.

    func test_neverExceedsMostRecentlyImpliedCeiling() {
        var ceiling = BweSenderCeiling()
        ceiling.observe(rawAvailableOutgoingBps: 1_000_000)
        for _ in 0..<10 {
            ceiling.observe(rawAvailableOutgoingBps: 3_000_000)
        }
        XCTAssertEqual(ceiling.ceilingBps, Int(3_000_000 * 0.85))
    }
}
