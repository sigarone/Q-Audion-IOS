import XCTest
@testable import QAudionEngine

final class CallAcceptResendTests: XCTestCase {

    func test_ladder_isBoundedAndIncreasing() {
        XCTAssertEqual(CallAcceptResend.ladderMs, [2_500, 5_000, 10_000])
        XCTAssertGreaterThan(CallAcceptResend.authWaitAttempts, 0)
    }

    // MARK: - Ladder stop condition

    func test_continues_whileBoundAndNotProven() {
        XCTAssertTrue(CallAcceptResend.shouldContinue(isBound: true, proven: false))
    }

    func test_stops_onUnbind() {
        XCTAssertFalse(CallAcceptResend.shouldContinue(isBound: false, proven: false))
    }

    func test_stops_onceCallerProven() {
        XCTAssertFalse(CallAcceptResend.shouldContinue(isBound: true, proven: true))
    }

    // MARK: - Resend-on-auth decision

    func test_signalBeforeAuthenticatedSend_doesNotProve() {
        XCTAssertFalse(CallAcceptResend.provesCallerFinalized(authenticatedSendDone: false, signalReceived: true))
    }

    func test_signalAfterAuthenticatedSend_proves() {
        XCTAssertTrue(CallAcceptResend.provesCallerFinalized(authenticatedSendDone: true, signalReceived: true))
    }

    func test_noSignal_neverProves() {
        XCTAssertFalse(CallAcceptResend.provesCallerFinalized(authenticatedSendDone: true, signalReceived: false))
    }

    // MARK: - Pending accept

    func test_pending_releasedForTheActiveCall_onlyOnce() {
        var p = PendingCallAccept()
        p.hold(callId: "ABCD-1234")
        XCTAssertEqual(p.take(activeCallId: "abcd-1234"), "abcd-1234")
        XCTAssertNil(p.take(activeCallId: "abcd-1234"))
    }

    func test_pending_keptUntilACallIsActive() {
        var p = PendingCallAccept()
        p.hold(callId: "abcd")
        XCTAssertNil(p.take(activeCallId: nil))
        XCTAssertNil(p.take(activeCallId: ""))
        XCTAssertEqual(p.callId, "abcd")
        XCTAssertEqual(p.take(activeCallId: "abcd"), "abcd")
    }

    func test_pending_droppedWhenAnotherCallIsActive() {
        var p = PendingCallAccept()
        p.hold(callId: "abcd")
        XCTAssertNil(p.take(activeCallId: "other"))
        XCTAssertNil(p.callId)
    }

    func test_pending_clear() {
        var p = PendingCallAccept()
        p.hold(callId: "abcd")
        p.clear()
        XCTAssertNil(p.take(activeCallId: "abcd"))
    }
}
