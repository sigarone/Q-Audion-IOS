import XCTest
@testable import QAudionEngine

/// W-GRPSFUMIDFALLBACK (2026-08-27, best-practices audit item 2) — pins
/// `SfuDisconnectFallbackDecision.shouldFallBack` against
/// `GroupCallController.handleSfuDisconnectedMidCall`'s real guard: fall
/// back to the WS-relay mesh only for the STILL-active call, and only when
/// an SFU room genuinely exists to fall back FROM (never for a stale/
/// redelivered event after a rejoin or a normal teardown already cleared
/// state). Same "no live GroupCallController/LiveKit Room needed" pinning
/// discipline as `RouteTierDwellTests` for the 1:1 path.
final class SfuDisconnectFallbackDecisionTests: XCTestCase {

    func test_activeCallWithSfuRoom_fallsBack() {
        XCTAssertTrue(SfuDisconnectFallbackDecision.shouldFallBack(
            eventCallId: "call-1", activeCallId: "call-1", hasSfuRoom: true
        ))
    }

    func test_noSfuRoom_neverFallsBack() {
        // Already torn down (this same fallback, or a normal `teardown()`,
        // already ran and cleared `sfuRoom`) — a redelivered/late event
        // must be a no-op, not a second fallback attempt.
        XCTAssertFalse(SfuDisconnectFallbackDecision.shouldFallBack(
            eventCallId: "call-1", activeCallId: "call-1", hasSfuRoom: false
        ))
    }

    func test_staleCallId_neverFallsBack() {
        // The event's call already ended and a DIFFERENT call is now
        // active — must not touch the new call's state.
        XCTAssertFalse(SfuDisconnectFallbackDecision.shouldFallBack(
            eventCallId: "call-1", activeCallId: "call-2", hasSfuRoom: true
        ))
    }

    func test_noActiveCall_neverFallsBack() {
        XCTAssertFalse(SfuDisconnectFallbackDecision.shouldFallBack(
            eventCallId: "call-1", activeCallId: nil, hasSfuRoom: true
        ))
    }

    func test_staleCallIdAndNoSfuRoom_neverFallsBack() {
        XCTAssertFalse(SfuDisconnectFallbackDecision.shouldFallBack(
            eventCallId: "call-1", activeCallId: "call-2", hasSfuRoom: false
        ))
    }
}
