import XCTest
@testable import QAudionEngine

final class VpioRetryPolicyTests: XCTestCase {
    func testDelaysRampThenSteady() {
        XCTAssertEqual((0...5).map(VpioRetryPolicy.delayMs(attempt:)),
                       [2_000, 5_000, 15_000, 30_000, 30_000, 30_000])
        XCTAssertEqual(VpioRetryPolicy.delayMs(attempt: -3), 2_000)
        XCTAssertEqual(VpioRetryPolicy.delayMs(attempt: 10_000), 30_000)
    }

    func testArmOnlyWhenDegradedInactiveAndWithinBudget() {
        XCTAssertTrue(VpioRetryPolicy.shouldArm(vpioActive: false, degradedByError: true, attemptsMade: 0))
        XCTAssertTrue(VpioRetryPolicy.shouldArm(vpioActive: false, degradedByError: true, attemptsMade: 4))
        XCTAssertFalse(VpioRetryPolicy.shouldArm(vpioActive: true, degradedByError: true, attemptsMade: 0))
        XCTAssertFalse(VpioRetryPolicy.shouldArm(vpioActive: false, degradedByError: false, attemptsMade: 0))
        XCTAssertFalse(VpioRetryPolicy.shouldArm(vpioActive: false, degradedByError: true, attemptsMade: 5))
    }

    func testCapIsFiveAttemptsWithExpectedDelays() {
        XCTAssertEqual(VpioRetryPolicy.maxTimedAttempts, 5)
        XCTAssertEqual((0..<5).map(VpioRetryPolicy.delayMs(attempt:)), [2_000, 5_000, 15_000, 30_000, 30_000])
        XCTAssertTrue(VpioRetryPolicy.hasBudget(attemptsMade: 4))
        XCTAssertFalse(VpioRetryPolicy.hasBudget(attemptsMade: 5))
        XCTAssertFalse(VpioRetryPolicy.hasBudget(attemptsMade: 50))
    }

    func testRouteDrivenRestartResetsBudgetOthersKeepIt() {
        XCTAssertEqual(VpioRetryPolicy.attemptsAfterRestart(current: 5, routeDriven: true), 0)
        XCTAssertEqual(VpioRetryPolicy.attemptsAfterRestart(current: 3, routeDriven: false), 3)
    }

    func testStopLine() {
        XCTAssertEqual(VpioRetryPolicy.fireLine(gen: 2, attempt: 5, result: .stop),
                       "audioVp ev=fire gen=2 retry=1 n=5 res=stop")
    }

    func testBluetoothHandsFree24kUsesHardwareRate() {
        let hw = VpioRetryPolicy.HardwareFormat(sessionRate: 24_000, inputRate: 24_000, inputChannels: 1)
        let sel = VpioRetryPolicy.selectFormat(hw, preferredRate: 48_000)
        XCTAssertTrue(sel.ready)
        XCTAssertEqual(sel.sampleRate, 24_000)
        XCTAssertEqual(sel.channels, 1)
        XCTAssertTrue(sel.alignSessionPreference)
    }

    func testBuiltInMic48kNeedsNoAlignment() {
        let hw = VpioRetryPolicy.HardwareFormat(sessionRate: 48_000, inputRate: 48_000, inputChannels: 1)
        let sel = VpioRetryPolicy.selectFormat(hw, preferredRate: 48_000)
        XCTAssertTrue(sel.ready)
        XCTAssertFalse(sel.alignSessionPreference)
    }

    func testSixteenKiloHertzHandsFree() {
        let hw = VpioRetryPolicy.HardwareFormat(sessionRate: 16_000, inputRate: 16_000, inputChannels: 1)
        let sel = VpioRetryPolicy.selectFormat(hw, preferredRate: 48_000)
        XCTAssertEqual(sel.sampleRate, 16_000)
        XCTAssertTrue(sel.alignSessionPreference)
    }

    func testInvalidInputFormatIsNotReady() {
        let cases = [
            VpioRetryPolicy.HardwareFormat(sessionRate: 24_000, inputRate: 0, inputChannels: 0),
            VpioRetryPolicy.HardwareFormat(sessionRate: 24_000, inputRate: 24_000, inputChannels: 0),
            VpioRetryPolicy.HardwareFormat(sessionRate: 24_000, inputRate: 0, inputChannels: 1)
        ]
        for hw in cases {
            let sel = VpioRetryPolicy.selectFormat(hw, preferredRate: 48_000)
            XCTAssertFalse(sel.ready)
            XCTAssertEqual(sel.sampleRate, 0)
            XCTAssertFalse(sel.alignSessionPreference)
        }
    }

    func testSessionAndInputRateDisagreeDoesNotAlign() {
        let hw = VpioRetryPolicy.HardwareFormat(sessionRate: 24_000, inputRate: 16_000, inputChannels: 1)
        let sel = VpioRetryPolicy.selectFormat(hw, preferredRate: 48_000)
        XCTAssertTrue(sel.ready)
        XCTAssertEqual(sel.sampleRate, 16_000)
        XCTAssertFalse(sel.alignSessionPreference)
    }

    func testLogLinesAreNumericKeyValue() {
        let hw = VpioRetryPolicy.HardwareFormat(sessionRate: 24_000, inputRate: 24_000, inputChannels: 1)
        XCTAssertEqual(VpioRetryPolicy.formatLine(gen: 4, hw: hw, ready: true),
                       "audioVp ev=cfg gen=4 sess_hz=24000 in_hz=24000 ch=1 ok=1")
        XCTAssertEqual(VpioRetryPolicy.armLine(gen: 4, attempt: 1, delayMs: 5_000),
                       "audioVp ev=arm gen=4 retry=1 n=1 delay_ms=5000")
        XCTAssertEqual(VpioRetryPolicy.fireLine(gen: 4, attempt: 2, result: .skip),
                       "audioVp ev=fire gen=4 retry=1 n=2 res=skip")
    }
}
