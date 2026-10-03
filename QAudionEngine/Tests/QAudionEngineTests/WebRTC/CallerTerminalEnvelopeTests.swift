import XCTest
@testable import QAudionEngine

/// W-STALEENVELOPE (2026-10-03) — the caller-side terminal envelopes (`call_peer_offline`, `call_busy`,
/// `call_cancel`) end the current outgoing call only when they name it, and every teardown through them resets the
/// accept latch exactly once.
///
/// `Caller` is the glue `AppState` runs around `CallerAcceptLatch`: `startCall` calls `beginOutgoing(callId:)`, the
/// three WS handlers feed `terminalEnvelopeArrived` the envelope id and the caller's phase and tear the call down
/// only on `.endOutgoingCall`, the other teardown paths (`AppState.endCall`, the CallKit reset, the OFFER failure
/// branches) call `reset()`, and the phase moves through `setPhase` the way `callState` does (which replays a held
/// early `call_answer` through `phaseChanged`).
final class CallerTerminalEnvelopeTests: XCTestCase {

    private typealias Phase = CallerAcceptLatch.Phase
    private let callA = "11111111-1111-4111-8111-111111111111"
    private let callB = "22222222-2222-4222-8222-222222222222"

    private struct Caller {
        var latch = CallerAcceptLatch()
        var phase: Phase = .idle
        var activeCallId: String?
        /// `callService.endCall()` runs, i.e. the handler tore the call down.
        var teardowns = 0
        /// `finalizeCallActive()` runs.
        var finalizeCount = 0
        var drops: [CallerAcceptLatch.DropReason] = []
        var ignored: [CallerAcceptLatch.TerminalIgnoreReason] = []

        /// `startCall`: the call begins in `.connecting`.
        mutating func startCall(_ id: String) {
            latch.beginOutgoing(callId: id)
            activeCallId = id
            phase = .connecting
        }

        /// A caller-side terminal envelope. Returns true when the handler tore the call down.
        @discardableResult
        mutating func terminal(_ kind: CallerAcceptLatch.TerminalKind, _ id: String?) -> Bool {
            switch latch.terminalEnvelopeArrived(envelopeCallId: id, phase: phase) {
            case .endOutgoingCall:
                teardowns += 1
                phase = .ended
                activeCallId = nil
                return true
            case .ignore(let reason):
                ignored.append(reason)
                return false
            }
        }

        /// `AppState.endCall()`: the user's hangup (and every remote hangup).
        mutating func hangup() {
            teardowns += 1
            phase = .ended
            activeCallId = nil
            latch.reset()
        }

        mutating func setPhase(_ new: Phase) {
            guard new != phase else { return }
            phase = new
            if let replay = latch.phaseChanged(to: new, activeCallId: activeCallId) {
                switch replay.step {
                case .finalizeNow: finalizeCount += 1; latch.markFinalized(callId: replay.callId)
                case .waitForAccept, .held: break
                case .dropped(let reason): drops.append(reason)
                }
            }
        }

        mutating func callAnswer(_ id: String, sdp: Bool = false) -> CallerAcceptLatch.AnswerStep {
            latch.answerArrived(envelopeCallId: id, activeCallId: activeCallId, carriedSdp: sdp, phase: phase)
        }
    }

    // MARK: - a matching envelope ends the call

    func testMatchingEnvelopeEndsTheCallInEveryLivePhase() {
        for kind in [CallerAcceptLatch.TerminalKind.peerOffline, .busy, .cancel] {
            for phase in [Phase.connecting, .ringing, .active, .encrypted] {
                var c = Caller()
                c.startCall(callA)
                c.phase = phase
                XCTAssertTrue(c.terminal(kind, callA), "\(kind) in \(phase)")
                XCTAssertEqual(c.teardowns, 1)
                XCTAssertEqual(c.phase, .ended)
                XCTAssertEqual(c.latch, CallerAcceptLatch(), "the latch is fully reset by the teardown: \(kind) in \(phase)")
            }
        }
    }

    func testMatchingEnvelopeIsCaseInsensitive() {
        var c = Caller()
        c.startCall(callA.uppercased())
        XCTAssertTrue(c.terminal(.busy, callA))
        c.startCall(callB)
        XCTAssertTrue(c.terminal(.peerOffline, callB.uppercased()))
        XCTAssertEqual(c.teardowns, 2)
    }

    func testStepIsEndOutgoingCallForTheCurrentCall() {
        var latch = CallerAcceptLatch()
        latch.beginOutgoing(callId: callA)
        XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA, phase: .ringing), .endOutgoingCall)
    }

    // MARK: - a stale envelope for an old call leaves the new call untouched

    func testStaleEnvelopeAfterHangupAndRedialLeavesTheNewCallUntouched() {
        for kind in [CallerAcceptLatch.TerminalKind.peerOffline, .busy, .cancel] {
            var c = Caller()
            c.startCall(callA)
            c.setPhase(.ringing)
            c.hangup()
            c.startCall(callB)
            XCTAssertFalse(c.terminal(kind, callA), "a late \(kind) for call A must not end call B")
            XCTAssertEqual(c.ignored, [.otherCall])
            XCTAssertEqual(c.teardowns, 1, "only the hangup of call A tore anything down")
            XCTAssertEqual(c.phase, .connecting)
            XCTAssertEqual(c.latch.outgoingCallId, callB)
        }
    }

    func testStaleEnvelopeAfterAHandlerTeardownAndRedialLeavesTheNewCallUntouched() {
        var c = Caller()
        c.startCall(callA)
        XCTAssertTrue(c.terminal(.busy, callA))
        c.startCall(callB)
        c.setPhase(.ringing)
        // the server redelivers call A's call_busy after a WS reconnect
        XCTAssertFalse(c.terminal(.busy, callA))
        XCTAssertFalse(c.terminal(.peerOffline, callA))
        XCTAssertFalse(c.terminal(.cancel, callA))
        XCTAssertEqual(c.teardowns, 1)
        XCTAssertEqual(c.phase, .ringing)
        XCTAssertEqual(c.latch.outgoingCallId, callB)
        XCTAssertEqual(c.ignored, [.otherCall, .otherCall, .otherCall])
    }

    func testStaleEnvelopeKeepsTheNewCallsLatchState() {
        var c = Caller()
        c.startCall(callA)
        c.hangup()
        c.startCall(callB)
        // call B's early answer is held while its OFFER is built; a stale envelope of call A must not discard it
        XCTAssertEqual(c.callAnswer(callB), .held)
        XCTAssertFalse(c.terminal(.peerOffline, callA))
        XCTAssertEqual(c.latch.held?.callId, callB)
        c.setPhase(.ringing)
        XCTAssertEqual(c.latch.localHandshakeReadyCallId, callB, "the held answer of call B is applied once it rings")
    }

    func testStaleEnvelopeDoesNotDisturbAConnectedCall() {
        var c = Caller()
        c.startCall(callA)
        c.hangup()
        c.startCall(callB)
        c.setPhase(.active)
        _ = c.latch.acceptedArrived(envelopeCallId: callB, activeCallId: callB, phase: .active)
        _ = c.callAnswer(callB, sdp: true)
        c.latch.markFinalized(callId: callB)
        XCTAssertFalse(c.terminal(.cancel, callA))
        XCTAssertEqual(c.latch.finalizedCallId, callB)
        XCTAssertEqual(c.latch.acceptedCallId, callB)
        XCTAssertEqual(c.phase, .active)
    }

    // MARK: - envelopes that cannot be attributed

    func testEnvelopeWithoutACallIdIsDroppedAndTouchesNothing() {
        for kind in [CallerAcceptLatch.TerminalKind.peerOffline, .busy, .cancel] {
            let missingIds: [String?] = [nil, ""]
            for id in missingIds {
                var c = Caller()
                c.startCall(callA)
                XCTAssertEqual(c.callAnswer(callA), .held)
                XCTAssertFalse(c.terminal(kind, id))
                XCTAssertEqual(c.ignored, [.noCallId])
                XCTAssertEqual(c.teardowns, 0)
                XCTAssertEqual(c.latch.outgoingCallId, callA)
                XCTAssertNotNil(c.latch.held, "an id-less envelope must not reset the latch")
            }
        }
    }

    func testNoOutgoingCallIsCurrent() {
        var c = Caller()
        XCTAssertFalse(c.terminal(.busy, callA))
        XCTAssertEqual(c.ignored, [.noOutgoingCall])
    }

    func testDuplicateOfAHandledEnvelopeCannotEndTheCallTwice() {
        var c = Caller()
        c.startCall(callA)
        XCTAssertTrue(c.terminal(.peerOffline, callA))
        XCTAssertFalse(c.terminal(.peerOffline, callA))
        XCTAssertFalse(c.terminal(.busy, callA))
        XCTAssertEqual(c.teardowns, 1)
        XCTAssertEqual(c.ignored, [.noOutgoingCall, .noOutgoingCall])
    }

    func testMatchingEnvelopeOnAFinishedCallIsIgnoredAndKeepsTheLatch() {
        for phase in [Phase.idle, .ended] {
            var latch = CallerAcceptLatch()
            latch.beginOutgoing(callId: callA)
            let before = latch
            XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA, phase: phase), .ignore(.notInCall))
            XCTAssertEqual(latch, before)
        }
    }

    // MARK: - the latch is reset by every teardown path: a held answer of call A never reaches call B

    func testHeldAnswerOfCallAIsNeverAppliedToCallB_afterPeerOfflineBusyOrCancel() {
        for kind in [CallerAcceptLatch.TerminalKind.peerOffline, .busy, .cancel] {
            var c = Caller()
            c.startCall(callA)
            XCTAssertEqual(c.callAnswer(callA, sdp: true), .held, "call A's answer arrives during its OFFER")
            XCTAssertTrue(c.terminal(kind, callA))
            XCTAssertNil(c.latch.held, "\(kind) teardown reset the latch")
            c.startCall(callB)
            c.activeCallId = nil  // the id the app can name is not bound yet: the worst case for a replay
            c.setPhase(.ringing)
            XCTAssertEqual(c.finalizeCount, 0)
            XCTAssertNil(c.latch.localHandshakeReadyCallId, "\(kind): call A's answer was applied to call B")
            XCTAssertTrue(c.drops.isEmpty)
        }
    }

    func testHeldAnswerOfCallAIsNeverAppliedToCallB_afterHangup() {
        var c = Caller()
        c.startCall(callA)
        XCTAssertEqual(c.callAnswer(callA), .held)
        c.hangup()
        c.startCall(callB)
        c.activeCallId = nil
        c.setPhase(.ringing)
        XCTAssertNil(c.latch.localHandshakeReadyCallId)
        XCTAssertEqual(c.finalizeCount, 0)
    }

    func testHeldAnswerOfCallAIsNeverAppliedToCallB_afterATeardownThatDoesNotReset() {
        // a teardown path nobody wired to reset the latch: starting call B is the backstop
        var c = Caller()
        c.startCall(callA)
        XCTAssertEqual(c.callAnswer(callA), .held)
        _ = c.latch.acceptedArrived(envelopeCallId: callA, activeCallId: callA, phase: .connecting)
        c.phase = .ended  // torn down without a latch reset
        c.startCall(callB)
        XCTAssertNil(c.latch.held)
        XCTAssertNil(c.latch.acceptedCallId)
        c.activeCallId = nil
        c.setPhase(.ringing)
        XCTAssertNil(c.latch.localHandshakeReadyCallId)
        XCTAssertEqual(c.finalizeCount, 0)
    }

    func testControl_withoutAResetTheHeldAnswerOfCallAWouldBeAppliedToCallB() {
        // documents the defect: the latch alone replays a held answer whenever no active id can contradict it
        var latch = CallerAcceptLatch()
        XCTAssertEqual(
            latch.answerArrived(envelopeCallId: callA, activeCallId: nil, carriedSdp: true, phase: .connecting), .held)
        let replay = latch.phaseChanged(to: .ringing, activeCallId: nil)
        XCTAssertEqual(replay?.callId, callA)
        XCTAssertNotNil(replay, "this is why a teardown must reset the latch")
    }

    func testTheTerminalTeardownResetsExactlyOnce() {
        var latch = CallerAcceptLatch()
        latch.beginOutgoing(callId: callA)
        _ = latch.answerArrived(envelopeCallId: callA, activeCallId: callA, carriedSdp: false, phase: .ringing)
        latch.markFinalized(callId: callA)
        XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA, phase: .encrypted), .endOutgoingCall)
        XCTAssertEqual(latch, CallerAcceptLatch())
        // a second delivery finds nothing to end and nothing to reset
        XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA, phase: .ended), .ignore(.noOutgoingCall))
        XCTAssertEqual(latch, CallerAcceptLatch())
    }

    // MARK: - the normal paths are unchanged

    func testNormalCallStillConnectsAndAMatchingBusyAfterwardsStillEndsIt() {
        var c = Caller()
        c.startCall(callA)
        c.setPhase(.active)
        _ = c.latch.acceptedArrived(envelopeCallId: callA, activeCallId: callA, phase: .active)
        XCTAssertEqual(c.callAnswer(callA, sdp: true), .finalizeNow)
        XCTAssertTrue(c.terminal(.busy, callA))
        XCTAssertEqual(c.latch, CallerAcceptLatch())
    }

    func testBeginOutgoingRecordsTheLowercasedId() {
        var latch = CallerAcceptLatch()
        latch.beginOutgoing(callId: callA.uppercased())
        XCTAssertEqual(latch.outgoingCallId, callA)
        latch.beginOutgoing(callId: callB)
        XCTAssertEqual(latch.outgoingCallId, callB)
        latch.reset()
        XCTAssertNil(latch.outgoingCallId)
    }

    // MARK: - call_ready of an old call

    func testIsCurrentOutgoingCall() {
        var latch = CallerAcceptLatch()
        XCTAssertFalse(latch.isCurrentOutgoingCall(envelopeCallId: callA), "no outgoing call yet")
        latch.beginOutgoing(callId: callA)
        XCTAssertTrue(latch.isCurrentOutgoingCall(envelopeCallId: callA))
        XCTAssertTrue(latch.isCurrentOutgoingCall(envelopeCallId: callA.uppercased()))
        XCTAssertFalse(latch.isCurrentOutgoingCall(envelopeCallId: callB))
        XCTAssertFalse(latch.isCurrentOutgoingCall(envelopeCallId: ""))
        XCTAssertFalse(latch.isCurrentOutgoingCall(envelopeCallId: nil))
        latch.beginOutgoing(callId: callB)
        XCTAssertFalse(latch.isCurrentOutgoingCall(envelopeCallId: callA), "a late call_ready of call A after a redial")
        latch.reset()
        XCTAssertFalse(latch.isCurrentOutgoingCall(envelopeCallId: callB), "after the call ended")
    }

    // MARK: - an incoming call's cancel once no outgoing call is current

    func testEnvelopeMayEndActiveCall() {
        XCTAssertTrue(CallerAcceptLatch.envelopeMayEndActiveCall(envelopeCallId: callA, activeCallId: callA))
        XCTAssertTrue(CallerAcceptLatch.envelopeMayEndActiveCall(envelopeCallId: callA.uppercased(), activeCallId: callA))
        XCTAssertFalse(CallerAcceptLatch.envelopeMayEndActiveCall(envelopeCallId: callA, activeCallId: callB),
                       "a cancel of an old call must not end the live one")
        XCTAssertTrue(CallerAcceptLatch.envelopeMayEndActiveCall(envelopeCallId: callA, activeCallId: nil))
        XCTAssertTrue(CallerAcceptLatch.envelopeMayEndActiveCall(envelopeCallId: callA, activeCallId: ""))
        XCTAssertTrue(CallerAcceptLatch.envelopeMayEndActiveCall(envelopeCallId: "", activeCallId: callB))
        XCTAssertTrue(CallerAcceptLatch.envelopeMayEndActiveCall(envelopeCallId: nil, activeCallId: callB))
    }
}
