import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03) — the caller's teardown after `call_busy` / `call_peer_offline`.
///
/// Live trace, 2026-10-03 10:43:10 / :31 / :34: an iPhone dialled an Android phone that was in another call, the
/// server answered `call_busy` each time, and the app closed silently and left the CallKit outgoing call, the call
/// record and the ring-back timer open: the redials failed with `maximumCallGroupsReached` for ~41 s. The handlers
/// now tear down through `AppState.endCall(notifyPeerInBand: false, outcome:)`; what is pure about that decision
/// lives in `CallerTerminalOutcome` and is pinned here, together with the two facts about the accept latch the
/// change must not disturb (it is reset exactly once by the teardown, and an immediate redial is admitted).
final class CallerBusyTeardownTests: XCTestCase {

    private typealias Phase = CallerAcceptLatch.Phase
    private let callA = "11111111-1111-4111-8111-111111111111"
    private let callB = "22222222-2222-4222-8222-222222222222"
    private let callC = "33333333-3333-4333-8333-333333333333"

    // MARK: - the outcome of each envelope

    func testOnlyBusyAndPeerOfflineHaveAnOutcome() {
        XCTAssertEqual(CallerTerminalOutcome(kind: .busy), .busy)
        XCTAssertEqual(CallerTerminalOutcome(kind: .peerOffline), .peerOffline)
        XCTAssertNil(CallerTerminalOutcome(kind: .cancel), "call_cancel keeps its own routing")
    }

    /// CallKit hears `.unanswered` for busy and `.remoteEnded` for an unreachable callee, never `.failed`.
    func testCallKitEndReasonMapping() {
        guard case .unanswered = CallerTerminalOutcome.busy.callKitEndReason else {
            return XCTFail("busy must be reported to CallKit as .unanswered")
        }
        guard case .remoteEnded = CallerTerminalOutcome.peerOffline.callKitEndReason else {
            return XCTFail("peer offline must be reported to CallKit as .remoteEnded")
        }
        for outcome in CallerTerminalOutcome.allCases {
            if case .failed = outcome.callKitEndReason { XCTFail("\(outcome) must never be reported as .failed") }
            if case .userEnded = outcome.callKitEndReason { XCTFail("\(outcome) is not a local hangup") }
        }
    }

    /// The record closes as `busy` / `peer_offline`, the strings the handlers always reported to the telemetry.
    func testCloseTokensAreTheHistoricalTelemetryReasons() {
        XCTAssertEqual(CallerTerminalOutcome.busy.closeToken, "busy")
        XCTAssertEqual(CallerTerminalOutcome.peerOffline.closeToken, "peer_offline")
        XCTAssertEqual(CallerTerminalOutcome.accepted("busy"), .busy)
        XCTAssertEqual(CallerTerminalOutcome.accepted("peer_offline"), .peerOffline)
        XCTAssertNil(CallerTerminalOutcome.accepted(nil))
        XCTAssertNil(CallerTerminalOutcome.accepted(""))
        XCTAssertNil(CallerTerminalOutcome.accepted("Busy"), "exact, case-sensitive tokens")
        XCTAssertNil(CallerTerminalOutcome.accepted("user_hangup"))
        XCTAssertNil(CallerTerminalOutcome.accepted("identity_key_mismatch"), "a handshake reason is not an outcome")
    }

    func testTheOutcomeTokensAreNotHandshakeCloseReasons() {
        for outcome in CallerTerminalOutcome.allCases {
            XCTAssertNil(CallCloseReason.accepted(outcome.closeToken),
                         "the seven handshake / identity reasons stay exactly those seven")
        }
    }

    /// The busy tone is requested for `call_busy` only.
    func testOnlyBusyRequestsTheBusyTone() {
        XCTAssertTrue(CallerTerminalOutcome.busy.playsBusyTone)
        XCTAssertFalse(CallerTerminalOutcome.peerOffline.playsBusyTone)
    }

    /// The outcome stays long enough to read and to hear the whole 3 s tone, and short enough not to feel stuck.
    func testHoldCoversTheToneAndStaysShort() {
        XCTAssertGreaterThanOrEqual(CallerTerminalOutcome.busy.holdSeconds, QAudionSynth.busyToneSeconds)
        for outcome in CallerTerminalOutcome.allCases {
            XCTAssertGreaterThanOrEqual(outcome.holdSeconds, 2.0, "\(outcome)")
            XCTAssertLessThanOrEqual(outcome.holdSeconds, 3.5, "\(outcome)")
        }
    }

    func testLocalizationKeys() {
        XCTAssertEqual(CallerTerminalOutcome.busy.messageKey, "call.outgoing.busy")
        XCTAssertEqual(CallerTerminalOutcome.peerOffline.messageKey, "call.outgoing.peer_offline")
        XCTAssertEqual(CallerTerminalOutcome.busy.historyLabelKey, "call_history.close.busy")
        XCTAssertEqual(CallerTerminalOutcome.peerOffline.historyLabelKey, "call_history.close.peer_offline")
    }

    // MARK: - the latch: reset exactly once, and the gate is the only thing that decides

    /// What `AppState` runs for a busy / peer-offline envelope: the id gate (`terminalEnvelopeArrived`, which resets
    /// the latch), then `AppState.endCall(outcome:)` (which resets it again, as it does for every ending), then, for
    /// a redial, `startCall` (`beginOutgoing`).
    private struct Caller {
        var latch = CallerAcceptLatch()
        var phase: Phase = .idle
        var endCallBodies = 0
        /// Resets that actually cleared something. `endCall`'s own reset must find the latch already clear.
        var effectiveResets = 0
        var ignored: [CallerAcceptLatch.TerminalIgnoreReason] = []

        mutating func startCall(_ id: String) {
            latch.beginOutgoing(callId: id)
            phase = .connecting
        }

        mutating func terminal(_ kind: CallerAcceptLatch.TerminalKind, _ id: String) {
            let before = latch
            switch latch.terminalEnvelopeArrived(envelopeCallId: id, phase: phase) {
            case .ignore(let reason):
                ignored.append(reason)
            case .endOutgoingCall:
                if before != CallerAcceptLatch() && latch == CallerAcceptLatch() { effectiveResets += 1 }
                endCall()
            }
        }

        /// `AppState.endCall`: its `acceptLatch.reset()` and the phase it leaves.
        mutating func endCall() {
            endCallBodies += 1
            let before = latch
            latch.reset()
            if before != latch { effectiveResets += 1 }
            phase = .idle
        }
    }

    func testTheBusyTeardownResetsTheLatchExactlyOnce() {
        for kind in [CallerAcceptLatch.TerminalKind.busy, .peerOffline] {
            var c = Caller()
            c.startCall(callA)
            c.phase = .ringing
            // A stashed answer is the state a reset must clear.
            _ = c.latch.answerArrived(envelopeCallId: callA, activeCallId: callA, carriedSdp: false, phase: .ringing)
            c.terminal(kind, callA)
            XCTAssertEqual(c.endCallBodies, 1, "\(kind): the teardown runs once")
            XCTAssertEqual(c.effectiveResets, 1, "\(kind): the latch is cleared by one path; endCall's reset finds it clear")
            XCTAssertEqual(c.latch, CallerAcceptLatch())
        }
    }

    /// The pre-existing pin, restated against the new teardown: a second delivery finds nothing to end.
    func testASecondDeliveryOfTheSameEnvelopeFindsNothingToEnd() {
        var c = Caller()
        c.startCall(callA)
        c.phase = .ringing
        c.terminal(.busy, callA)
        c.terminal(.busy, callA)
        XCTAssertEqual(c.endCallBodies, 1)
        XCTAssertEqual(c.ignored, [.noOutgoingCall])
    }

    /// `testTheTerminalTeardownResetsExactlyOnce` (CallerTerminalEnvelopeTests) pins the gate: it resets the latch and
    /// a second delivery finds nothing. This is its counterpart for the whole teardown: after the gate, the extra
    /// `reset()` of `AppState.endCall` changes nothing.
    func testTheTerminalTeardownThroughEndCallLeavesTheLatchClear() {
        var latch = CallerAcceptLatch()
        latch.beginOutgoing(callId: callA)
        _ = latch.answerArrived(envelopeCallId: callA, activeCallId: callA, carriedSdp: false, phase: .ringing)
        latch.markFinalized(callId: callA)
        XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA, phase: .encrypted), .endOutgoingCall)
        XCTAssertEqual(latch, CallerAcceptLatch())
        latch.reset()   // AppState.endCall
        XCTAssertEqual(latch, CallerAcceptLatch())
        XCTAssertNil(latch.outgoingCallId)
    }

    // MARK: - an immediate redial is admitted

    /// Incident timeline: busy, redial, busy, redial, busy. Every envelope ends exactly its own call, and a late
    /// redelivery of an earlier busy never touches the call that is live.
    func testRedialRightAfterBusyIsAdmittedAndLateEnvelopesAreIgnored() {
        var c = Caller()
        c.startCall(callA)
        c.phase = .ringing
        c.terminal(.busy, callA)
        XCTAssertEqual(c.phase, .idle)

        c.startCall(callB)                       // the redial, straight after the busy
        XCTAssertEqual(c.latch.outgoingCallId, callB)
        XCTAssertEqual(c.phase, .connecting)

        c.terminal(.busy, callA)                 // a redelivery of call A's busy lands during call B
        XCTAssertEqual(c.ignored, [.otherCall])
        XCTAssertEqual(c.phase, .connecting, "call B is untouched")
        XCTAssertEqual(c.endCallBodies, 1)

        c.terminal(.busy, callB)
        XCTAssertEqual(c.endCallBodies, 2)
        c.startCall(callC)
        c.terminal(.peerOffline, callC)
        XCTAssertEqual(c.endCallBodies, 3)
        XCTAssertEqual(c.latch, CallerAcceptLatch())
    }

    /// The #160 deferred settle must not clobber a redial that moved the state on inside the second.
    func testTheDeferredSettleNeverTouchesARedial() {
        XCTAssertFalse(CallerOutgoingStatePolicy.shouldSettleToIdle(.connecting))
        XCTAssertFalse(CallerOutgoingStatePolicy.shouldSettleToIdle(.ringing))
        XCTAssertFalse(CallerOutgoingStatePolicy.shouldSettleToIdle(.idle), "endCall already left idle")
        XCTAssertTrue(CallerOutgoingStatePolicy.shouldSettleToIdle(.ended))
    }
}
