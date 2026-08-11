import XCTest
@testable import QAudionEngine

final class MeshRadioScheduleTests: XCTestCase {

    func testForegroundPluggedTakesTopPriority() {
        let inputs = MeshRadioSchedule.Inputs(
            batteryPercent: 5, isCharging: true, isAppForeground: true, hasConnectedPeer: false
        )
        XCTAssertEqual(MeshRadioSchedule.resolve(inputs), MeshRadioSchedule.activeForegroundPlugged)
    }

    func testForegroundOnBatteryIsStillResponsive() {
        let inputs = MeshRadioSchedule.Inputs(
            batteryPercent: 50, isCharging: false, isAppForeground: true, hasConnectedPeer: false
        )
        XCTAssertEqual(MeshRadioSchedule.resolve(inputs), MeshRadioSchedule.activeForegroundBattery)
    }

    func testBackgroundWithConnectedPeerBeatsBackgroundPlugged() {
        // hasConnectedPeer must win over isCharging when backgrounded —
        // keeping a live link responsive matters more than free power.
        let inputs = MeshRadioSchedule.Inputs(
            batteryPercent: 50, isCharging: true, isAppForeground: false, hasConnectedPeer: true
        )
        XCTAssertEqual(MeshRadioSchedule.resolve(inputs), MeshRadioSchedule.backgroundWithPeer)
    }

    func testBackgroundPluggedNoPeer() {
        let inputs = MeshRadioSchedule.Inputs(
            batteryPercent: 50, isCharging: true, isAppForeground: false, hasConnectedPeer: false
        )
        XCTAssertEqual(MeshRadioSchedule.resolve(inputs), MeshRadioSchedule.backgroundPlugged)
    }

    func testBackgroundLowBatteryUnplugged() {
        let inputs = MeshRadioSchedule.Inputs(
            batteryPercent: MeshRadioSchedule.lowBatteryThreshold, isCharging: false,
            isAppForeground: false, hasConnectedPeer: false
        )
        XCTAssertEqual(MeshRadioSchedule.resolve(inputs), MeshRadioSchedule.backgroundLowBattery)
    }

    func testBackgroundIdleOtherwise() {
        let inputs = MeshRadioSchedule.Inputs(
            batteryPercent: 80, isCharging: false, isAppForeground: false, hasConnectedPeer: false
        )
        XCTAssertEqual(MeshRadioSchedule.resolve(inputs), MeshRadioSchedule.backgroundIdle)
    }

    func testEveryProfileIsProgressivelyCheaperTowardIdle() {
        // Sanity fence: the "active" profile should never be cheaper
        // (larger interval) than the idle one.
        XCTAssertLessThan(
            MeshRadioSchedule.activeForegroundPlugged.scanIntervalMs,
            MeshRadioSchedule.backgroundIdle.scanIntervalMs
        )
    }
}
