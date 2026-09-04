import XCTest
@testable import QAudionEngine

/// Re-key media-deafness (skew) fix — unit coverage for `RekeySwitchGate`,
/// ported from Android's already-shipped and hardened `RekeySwitchGateTest`
/// (`feature/feature-call/domain/RekeySwitchGateTest.kt`). Same 10 cases,
/// same assertions, same intent: idempotent switch, exact-epoch match, no
/// skipped epoch, and a rejected stale/premature call must never mutate
/// state (so it can't block the actually-pending epoch from switching
/// later). See `docs/superpowers/specs/2026-09-04-rekey-media-deafness-skew.md`.
final class RekeySwitchGateTests: XCTestCase {

    func testFirstAttemptForThePendingEpochSwitches() {
        let gate = RekeySwitchGate()
        gate.arm(1)
        XCTAssertTrue(gate.attemptSwitch(1))
    }

    func testSecondAttemptForTheSameEpochIsANoOp() {
        let gate = RekeySwitchGate()
        gate.arm(1)
        XCTAssertTrue(gate.attemptSwitch(1))
        XCTAssertFalse(gate.attemptSwitch(1))
    }

    func testReadyArrivingBeforeTimeoutWinsTimeoutBecomesANoOp() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        XCTAssertTrue(gate.attemptSwitch(2))   // simulated "ready arrived"
        XCTAssertFalse(gate.attemptSwitch(2))  // simulated "timeout fired after"
    }

    func testTimeoutFiringBeforeReadyWinsReadyBecomesANoOp() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        XCTAssertTrue(gate.attemptSwitch(2))   // simulated "timeout fired"
        XCTAssertFalse(gate.attemptSwitch(2))  // simulated "ready arrived after"
    }

    func testStaleEpochIsRejectedWithoutSwitching() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        _ = gate.attemptSwitch(2)
        gate.arm(3)
        XCTAssertFalse(gate.attemptSwitch(2))  // a replayed/late ready for the OLD epoch
    }

    func testPrematureFutureEpochIsRejectedWithoutSwitching() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        XCTAssertFalse(gate.attemptSwitch(3))  // a ready for an epoch we haven't armed yet
    }

    func testNoEpochIsSkippedAcrossAFullSequence() {
        let gate = RekeySwitchGate()
        gate.arm(1)
        XCTAssertTrue(gate.attemptSwitch(1))
        gate.arm(2)
        XCTAssertTrue(gate.attemptSwitch(2))
        gate.arm(3)
        XCTAssertTrue(gate.attemptSwitch(3))
    }

    func testCurrentPendingEpochReflectsTheMostRecentArm() {
        let gate = RekeySwitchGate()
        gate.arm(5)
        XCTAssertEqual(gate.currentPendingEpoch(), 5)
    }

    func testARejectedStaleEpochCallDoesNotBlockTheActuallyPendingEpochFromSwitching() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        _ = gate.attemptSwitch(2)
        gate.arm(3)
        XCTAssertFalse(gate.attemptSwitch(2))  // rejected, must not mutate state
        XCTAssertTrue(gate.attemptSwitch(3))   // the real pending epoch still switches cleanly
    }

    func testARejectedPrematureEpochCallDoesNotBlockTheActuallyPendingEpochFromSwitching() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        XCTAssertFalse(gate.attemptSwitch(3))  // rejected, must not mutate state
        XCTAssertTrue(gate.attemptSwitch(2))   // the real pending epoch still switches cleanly
    }
}
