import XCTest
@testable import QAudionEngine

/// W-SIGSWALLOW (2026-09-01) — pins the failure-path contract for
/// call-signaling sends (audit memory reference_ios_stability_audit_2026_09_01,
/// P1 item 7). Same style as `RestartIceDecisionsTests`: the numbers and
/// branches the live path relies on, without a socket or a CallKit provider.
final class CallSignalingFailurePolicyTests: XCTestCase {

    // MARK: - Kill switches ship ON (the new behavior is the default)

    func test_killSwitches_shipOn() {
        XCTAssertTrue(CallSignalingFailurePolicy.acceptedRetransmitWhenSocketNotReady)
        XCTAssertTrue(CallSignalingFailurePolicy.directAcceptOnCallKitAnswerFailure)
    }

    // MARK: - call_accepted: recoverable, so the existing ladder is armed

    /// The defect: `sendCallAccepted` threw BEFORE sending when the socket
    /// was not ready, so the ladder protecting the success path never ran on
    /// the failure path. With the switch on, the failure path sends once and
    /// arms the same ladder.
    func test_accepted_armsRetransmit_whenSwitchOn() {
        XCTAssertEqual(
            CallSignalingFailurePolicy.socketNotReadyAction(for: .callAccepted, acceptedRetransmitEnabled: true),
            .bestEffortSendAndArmRetransmit)
    }

    /// Flipping the switch restores the old throw-and-lose behavior exactly.
    func test_accepted_dropsAndThrows_whenSwitchOff() {
        XCTAssertEqual(
            CallSignalingFailurePolicy.socketNotReadyAction(for: .callAccepted, acceptedRetransmitEnabled: false),
            .dropAndThrow)
    }

    /// The default argument must track the shipped kill switch, not a copy.
    func test_accepted_defaultArgumentTracksKillSwitch() {
        XCTAssertEqual(
            CallSignalingFailurePolicy.socketNotReadyAction(for: .callAccepted),
            CallSignalingFailurePolicy.socketNotReadyAction(
                for: .callAccepted,
                acceptedRetransmitEnabled: CallSignalingFailurePolicy.acceptedRetransmitWhenSocketNotReady))
    }

    // MARK: - call_ready / call_processing: never retransmitted

    /// `ws.onCallReady` on the caller sets `callState = .ringing` without
    /// checking the current state — a late resend would knock an active call
    /// back to "ringing". This must hold regardless of the accepted switch,
    /// so a future "make it symmetric" edit fails here first.
    func test_ready_neverArmsRetransmit_regardlessOfSwitch() {
        XCTAssertEqual(
            CallSignalingFailurePolicy.socketNotReadyAction(for: .callReady, acceptedRetransmitEnabled: true),
            .dropAndThrow)
        XCTAssertEqual(
            CallSignalingFailurePolicy.socketNotReadyAction(for: .callReady, acceptedRetransmitEnabled: false),
            .dropAndThrow)
    }

    /// Informational ack; the ACCEPT bundle drives the caller's integration
    /// to `.active` on its own, so a resend buys nothing.
    func test_processing_neverArmsRetransmit_regardlessOfSwitch() {
        XCTAssertEqual(
            CallSignalingFailurePolicy.socketNotReadyAction(for: .callProcessing, acceptedRetransmitEnabled: true),
            .dropAndThrow)
        XCTAssertEqual(
            CallSignalingFailurePolicy.socketNotReadyAction(for: .callProcessing, acceptedRetransmitEnabled: false),
            .dropAndThrow)
    }

    /// Exactly one of the three envelopes is ever retransmitted on a
    /// socket-not-ready fast path — the asymmetry is the contract.
    func test_onlyAcceptedIsEverRetransmitted() {
        let all: [CallSignalingFailurePolicy.SetupEnvelope] = [.callAccepted, .callProcessing, .callReady]
        let armed = all.filter {
            CallSignalingFailurePolicy.socketNotReadyAction(for: $0, acceptedRetransmitEnabled: true)
                == .bestEffortSendAndArmRetransmit
        }
        XCTAssertEqual(armed, [.callAccepted])
    }
}
