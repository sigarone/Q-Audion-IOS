import XCTest
@testable import QAudionEngine

/// W-NATIVESRTPDIAG — pure rate-limiter for native FrameCryptor state-change
/// logging. No WebRTC dependency, so this runs on every platform/target.
final class FrameCryptorStateChangeLogGateTests: XCTestCase {

    func test_firstTransitionEver_alwaysLogs() {
        var gate = FrameCryptorStateChangeLogGate()
        XCTAssertTrue(gate.shouldLog(role: "tx", stateRawValue: 1, nowMs: 0))
    }

    func test_differentRole_sameState_logsImmediately_evenWithNoTimeElapsed() {
        var gate = FrameCryptorStateChangeLogGate()
        XCTAssertTrue(gate.shouldLog(role: "tx", stateRawValue: 1, nowMs: 0))
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 1, nowMs: 0))
    }

    func test_sameRole_differentState_logsImmediately_evenWithNoTimeElapsed() {
        var gate = FrameCryptorStateChangeLogGate()
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 1, nowMs: 0))
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 3, nowMs: 0))
    }

    func test_identicalRepeat_withinWindow_isSuppressed() {
        var gate = FrameCryptorStateChangeLogGate(minRepeatIntervalMs: 2_000)
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 3, nowMs: 0))
        XCTAssertFalse(gate.shouldLog(role: "rx", stateRawValue: 3, nowMs: 500))
        XCTAssertFalse(gate.shouldLog(role: "rx", stateRawValue: 3, nowMs: 1_999))
    }

    func test_identicalRepeat_afterWindowElapses_logsAgain() {
        var gate = FrameCryptorStateChangeLogGate(minRepeatIntervalMs: 2_000)
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 3, nowMs: 0))
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 3, nowMs: 2_000))
    }

    func test_flappingBetweenTwoStates_eachDistinctTransitionLogs() {
        var gate = FrameCryptorStateChangeLogGate(minRepeatIntervalMs: 2_000)
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 1, nowMs: 0))
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 3, nowMs: 10))
        XCTAssertTrue(gate.shouldLog(role: "rx", stateRawValue: 1, nowMs: 20))
    }
}
