import XCTest
@testable import QAudionEngine

/// W-M150ADAPTIVECOMPLEXITY (2026-09-29) — pins the encoder/decoder
/// complexity tables (webrtc-plan.md v2 §3.1, updated the same day for the
/// native decoder's OSCE-aware default) and the hysteresis rule shared by
/// both. Same style as `PlpFeedbackTests`/`IceTerminationPolicyTests` — pure
/// logic, no WebRTC/UIKit types, an injected clock wherever time matters.
final class AdaptiveOpusComplexityPolicyTests: XCTestCase {

    // MARK: - Encoder table

    func testCapableDeviceReachesTheCeilingAtNominalOrFairThermal() {
        XCTAssertEqual(
            AdaptiveOpusComplexityPolicy.target(thermalTier: .nominalOrFair, device: .capable),
            AdaptiveOpusComplexityPolicy.maxComplexity)
    }

    func testThermalTierAloneStepsDownRegardlessOfDevice() {
        XCTAssertEqual(
            AdaptiveOpusComplexityPolicy.target(thermalTier: .serious, device: .capable),
            AdaptiveOpusComplexityPolicy.seriousThermalComplexity)
        XCTAssertEqual(
            AdaptiveOpusComplexityPolicy.target(thermalTier: .critical, device: .capable),
            AdaptiveOpusComplexityPolicy.criticalThermalComplexity)
        XCTAssertEqual(
            AdaptiveOpusComplexityPolicy.target(thermalTier: .emergencyOrWorse, device: .capable),
            AdaptiveOpusComplexityPolicy.emergencyThermalComplexity)
    }

    /// Owner instruction (2026-09-29): "non farci limitare da telefoni
    /// obsoleti" — an old/low-power device still reaches a CEILING (8), it
    /// is never floored to the thermal-critical value just for being old.
    func testOldOrLowPowerDeviceIsCappedNotFlooredAtNominalThermal() {
        let old = DeviceCapabilityHint(isOldDevice: true, isLowPowerModeEnabled: false)
        let lowPower = DeviceCapabilityHint(isOldDevice: false, isLowPowerModeEnabled: true)
        XCTAssertEqual(
            AdaptiveOpusComplexityPolicy.target(thermalTier: .nominalOrFair, device: old),
            AdaptiveOpusComplexityPolicy.oldDeviceOrPowerSaveCeiling)
        XCTAssertEqual(
            AdaptiveOpusComplexityPolicy.target(thermalTier: .nominalOrFair, device: lowPower),
            AdaptiveOpusComplexityPolicy.oldDeviceOrPowerSaveCeiling)
    }

    /// A bad thermal state still wins over the device-class ceiling — an
    /// old device at `.critical` is NOT capped at 8, it follows the worse
    /// thermal value like any other device.
    func testBadThermalOverridesTheDeviceCeilingDownward() {
        let old = DeviceCapabilityHint(isOldDevice: true, isLowPowerModeEnabled: false)
        XCTAssertEqual(
            AdaptiveOpusComplexityPolicy.target(thermalTier: .critical, device: old),
            AdaptiveOpusComplexityPolicy.criticalThermalComplexity)
    }

    func testLadderForCapableDeviceHasFourRungsIncludingTheCeiling() {
        XCTAssertEqual(AdaptiveOpusComplexityPolicy.ladder(for: .capable), [5, 6, 8, 10])
    }

    func testLadderForOldOrLowPowerDeviceStopsAtTheCappedCeiling() {
        let old = DeviceCapabilityHint(isOldDevice: true, isLowPowerModeEnabled: false)
        XCTAssertEqual(AdaptiveOpusComplexityPolicy.ladder(for: old), [5, 6, 8])
    }

    // MARK: - Decoder table (native path only — NoLACE/LACE/deep-PLC)

    func testDecoderDefaultsToNoLaceOnACapableDeviceAtHealthyThermal() {
        XCTAssertEqual(
            AdaptiveOpusDecoderComplexityPolicy.target(thermalTier: .nominalOrFair, device: .capable),
            AdaptiveOpusDecoderComplexityPolicy.capableNominalOrFair)
        XCTAssertEqual(AdaptiveOpusDecoderComplexityPolicy.capableNominalOrFair, 7, "kQaudionDefaultDecoderComplexity")
    }

    func testDecoderStepsDownThroughLaceToDeepPlcOnlyAsThermalWorsens() {
        XCTAssertEqual(
            AdaptiveOpusDecoderComplexityPolicy.target(thermalTier: .serious, device: .capable),
            AdaptiveOpusDecoderComplexityPolicy.serious)
        XCTAssertEqual(
            AdaptiveOpusDecoderComplexityPolicy.target(thermalTier: .critical, device: .capable),
            AdaptiveOpusDecoderComplexityPolicy.criticalOrWorseOrOldDevice)
        XCTAssertEqual(
            AdaptiveOpusDecoderComplexityPolicy.target(thermalTier: .emergencyOrWorse, device: .capable),
            AdaptiveOpusDecoderComplexityPolicy.criticalOrWorseOrOldDevice)
    }

    /// Unlike the ENCODER table, an old device is pinned to the floor
    /// outright — never the 7/6 OSCE rungs — regardless of thermal state.
    /// This is the one deliberate asymmetry between the two tables; see
    /// `AdaptiveOpusDecoderComplexityPolicy`'s own doc for why.
    func testOldDeviceIsFlooredOnTheDecoderRegardlessOfThermal() {
        let old = DeviceCapabilityHint(isOldDevice: true, isLowPowerModeEnabled: false)
        for tier: ThermalTier in [.nominalOrFair, .serious, .critical, .emergencyOrWorse] {
            XCTAssertEqual(
                AdaptiveOpusDecoderComplexityPolicy.target(thermalTier: tier, device: old),
                AdaptiveOpusDecoderComplexityPolicy.criticalOrWorseOrOldDevice,
                "old device must floor at \(tier), never reach an OSCE rung")
        }
    }

    /// Low-power mode alone (NOT old) still reaches NoLACE at healthy
    /// thermal — the plan's decoder update names only "dispositivo vecchio",
    /// not low-power mode, as a decoder-floor trigger.
    func testLowPowerModeAloneDoesNotFloorTheDecoder() {
        let lowPower = DeviceCapabilityHint(isOldDevice: false, isLowPowerModeEnabled: true)
        XCTAssertEqual(
            AdaptiveOpusDecoderComplexityPolicy.target(thermalTier: .nominalOrFair, device: lowPower),
            AdaptiveOpusDecoderComplexityPolicy.capableNominalOrFair)
    }

    func testDecoderLadderForOldDeviceIsASingleRung() {
        let old = DeviceCapabilityHint(isOldDevice: true, isLowPowerModeEnabled: false)
        XCTAssertEqual(AdaptiveOpusDecoderComplexityPolicy.ladder(for: old), [5])
    }

    func testDecoderLadderForCapableDeviceHasAllThreeRungs() {
        XCTAssertEqual(AdaptiveOpusDecoderComplexityPolicy.ladder(for: .capable), [5, 6, 7])
    }

    // MARK: - ThermalTier(from:) — the one ProcessInfo.ThermalState mapping

    func testThermalStateMapsToTheMatchingTier() {
        XCTAssertEqual(ThermalTier(from: .nominal), .nominalOrFair)
        XCTAssertEqual(ThermalTier(from: .fair), .nominalOrFair)
        XCTAssertEqual(ThermalTier(from: .serious), .serious)
        XCTAssertEqual(ThermalTier(from: .critical), .critical)
    }

    // MARK: - Hysteresis (shared rule)

    func testDropsImmediatelyToAWorseTargetRegardlessOfElapsedTime() {
        let next = AdaptiveComplexityHysteresis.step(
            current: 10, target: 5, ladder: [5, 6, 8, 10], msSinceTargetImproved: 0)
        XCTAssertEqual(next, 5)
    }

    func testHoldsBelowTheStepIntervalEvenWhenTargetImproved() {
        let next = AdaptiveComplexityHysteresis.step(
            current: 5, target: 10, ladder: [5, 6, 8, 10],
            msSinceTargetImproved: AdaptiveComplexityHysteresis.stepIntervalMs - 1)
        XCTAssertEqual(next, 5, "must not climb before a full interval has elapsed")
    }

    func testClimbsExactlyOneRungAfterTheStepInterval() {
        let next = AdaptiveComplexityHysteresis.step(
            current: 5, target: 10, ladder: [5, 6, 8, 10],
            msSinceTargetImproved: AdaptiveComplexityHysteresis.stepIntervalMs)
        XCTAssertEqual(next, 6, "one rung (5 -> 6), not straight to the target")
    }

    func testNeverClimbsPastTheTargetEvenIfTheLadderHasMoreRoom() {
        // Target is 6 (one rung above current, 5) even though the ladder
        // goes up to 10 — must not overshoot to 8 just because it is next
        // on the ladder above 6.
        let next = AdaptiveComplexityHysteresis.step(
            current: 5, target: 6, ladder: [5, 6, 8, 10],
            msSinceTargetImproved: AdaptiveComplexityHysteresis.stepIntervalMs)
        XCTAssertEqual(next, 6)
    }

    func testUnsortedLadderIsHandledTheSameAsSorted() {
        let next = AdaptiveComplexityHysteresis.step(
            current: 5, target: 10, ladder: [10, 5, 8, 6],
            msSinceTargetImproved: AdaptiveComplexityHysteresis.stepIntervalMs)
        XCTAssertEqual(next, 6)
    }

    func testCurrentValueNotOnTheLadderJumpsStraightToAnImprovingTarget() {
        // current=7 is not a value either table ever produces on this
        // ladder — nothing to climb FROM — so an improving, held-long-enough
        // target is applied directly rather than guessing a step.
        let next = AdaptiveComplexityHysteresis.step(
            current: 7, target: 10, ladder: [5, 6, 8, 10],
            msSinceTargetImproved: AdaptiveComplexityHysteresis.stepIntervalMs)
        XCTAssertEqual(next, 10)
    }

    func testCurrentValueNotOnTheLadderStillDropsImmediatelyToAWorseTarget() {
        // Worse targets always drop at once regardless of ladder membership
        // — the "not on ladder" branch only matters for an IMPROVING target.
        let next = AdaptiveComplexityHysteresis.step(
            current: 7, target: 5, ladder: [5, 6, 8, 10], msSinceTargetImproved: 0)
        XCTAssertEqual(next, 5)
    }

    func testHoldingAtTheTargetIsAlwaysANoOp() {
        XCTAssertEqual(
            AdaptiveComplexityHysteresis.step(current: 8, target: 8, ladder: [5, 6, 8, 10], msSinceTargetImproved: 0),
            8)
    }

    // MARK: - ComplexityHysteresisDriver (stateful wrapper, injected clock)

    func testDriverClimbsOneRungPerFullIntervalAcrossRepeatedUpdates() {
        var nowMs: Int64 = 0
        let driver = ComplexityHysteresisDriver(initial: 5, ladder: [5, 6, 8, 10], nowMs: { nowMs })
        XCTAssertEqual(driver.update(target: 10), 5, "target just improved — nothing to climb yet")
        nowMs += AdaptiveComplexityHysteresis.stepIntervalMs
        XCTAssertEqual(driver.update(target: 10), 6)
        nowMs += AdaptiveComplexityHysteresis.stepIntervalMs
        XCTAssertEqual(driver.update(target: 10), 8)
        nowMs += AdaptiveComplexityHysteresis.stepIntervalMs
        XCTAssertEqual(driver.update(target: 10), 10)
        XCTAssertEqual(driver.currentComplexity, 10)
    }

    func testDriverDropsImmediatelyEvenMidClimb() {
        var nowMs: Int64 = 0
        let driver = ComplexityHysteresisDriver(initial: 5, ladder: [5, 6, 8, 10], nowMs: { nowMs })
        nowMs += AdaptiveComplexityHysteresis.stepIntervalMs
        XCTAssertEqual(driver.update(target: 10), 6)
        // Thermal got worse again before the next climb — must drop at once.
        XCTAssertEqual(driver.update(target: 5), 5)
    }

    /// A target that IMPROVES AGAIN before the interval elapses restarts the
    /// hold clock at the new value — it does not inherit however long the
    /// PREVIOUS (different) target had already been held.
    func testATargetChangeMidIntervalRestartsTheHoldClock() {
        var nowMs: Int64 = 0
        let driver = ComplexityHysteresisDriver(initial: 5, ladder: [5, 6, 8, 10], nowMs: { nowMs })
        nowMs += AdaptiveComplexityHysteresis.stepIntervalMs - 1
        XCTAssertEqual(driver.update(target: 6), 5, "not held long enough yet")
        // Target improves again (6 -> 10) one ms before 6 would have been
        // eligible to apply — the clock restarts for the NEW target.
        nowMs += 1
        XCTAssertEqual(driver.update(target: 10), 5, "the new target just changed again — held for 0ms")
        nowMs += AdaptiveComplexityHysteresis.stepIntervalMs
        XCTAssertEqual(driver.update(target: 10), 6, "now eligible, climbs one rung toward the latest target")
    }

    // MARK: - QaudionDeviceClass (pure identifier lookup)

    func testKnownA11OrEarlierIdentifiersAreRecognized() {
        for id in ["iPhone8,1", "iPhone9,1", "iPhone10,3", "iPhone10,6"] {
            XCTAssertTrue(QaudionDeviceClass.isA11OrEarlier(machineIdentifier: id), id)
        }
    }

    func testNewerOrUnknownIdentifiersAreNotFlaggedOld() {
        // iPhone11,x is the first A12 device (XS/XR) — must NOT be flagged.
        for id in ["iPhone11,2", "iPhone15,2", "x86_64", "arm64", "totally-unknown-id"] {
            XCTAssertFalse(QaudionDeviceClass.isA11OrEarlier(machineIdentifier: id), id)
        }
    }
}
