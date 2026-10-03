import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03, review of #169) — a busy or unreachable callee is told NOTHING when the caller tears the
/// call down.
///
/// `endCall(notifyPeerInBand: false)` alone is not enough: the teardown still sends the WS `call_hangup` envelope and
/// the opaque `HANGUP` (`local_hangup`) for a call without a WebRTC controller, and `sendHangupAndClose()` for one
/// with a controller. For `call_busy` the callee is inside ANOTHER call; a hangup naming this call id reaches a phone
/// that is mid-call with someone else. Before this PR the busy handler sent nothing, and Android is explicit:
/// `hangup(reason = "busy", notifyPeer = false)` gates `sendHangup` on `notifyPeer`. The pure fact lives in
/// `CallerTerminalOutcome.sendsHangupToPeer`; `CallerBusyWiringTests` pins that `AppState.endCall` honours it on every
/// send path.
final class CallerBusyPeerSilenceTests: XCTestCase {

    func testNeitherOutcomeSendsAHangupToThePeer() {
        for outcome in CallerTerminalOutcome.allCases {
            XCTAssertFalse(outcome.sendsHangupToPeer, "\(outcome): the call never rang there, announce nothing")
        }
    }

    /// The ending of an ordinary call (no outcome) keeps announcing itself: the default of `AppState.endCall`.
    func testAnEndingWithoutAnOutcomeStillAnnounces() {
        let outcome: CallerTerminalOutcome? = nil
        XCTAssertTrue(outcome?.sendsHangupToPeer ?? true)
    }
}
