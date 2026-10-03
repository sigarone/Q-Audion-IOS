import XCTest
@testable import QAudionEngine

/// W-ACCEPTLATCH (2026-10-03) — every arrival order of the caller's accept messages, per callee platform.
///
/// `CallerSim` is the same glue `AppState` runs around `CallerAcceptLatch`: the WS handlers feed the latch the
/// message and the caller's phase, `finalizeCallActive()` is a counted side effect (it is the ONLY thing that
/// opens the caller's microphone, via `CallService.handleCallAnswered()` -> `peerAnswered = true`), the
/// session-key observer advances the phase with `CallerAcceptLatch.phaseOnSessionKeyReady`, and `call_ready`
/// moves a not-yet-finalized caller to `.ringing`.
///
/// What the three callee platforms put on the wire once the user answered (R-ANSWER-FIRST, read from their code):
///   - iOS:     call_accepted, call_answer, ACCEPT
///   - Android: call_accepted, call_answer, ACCEPT   (after its 5 s reserve timer: call_accepted, ACCEPT, call_answer)
///   - desktop: call_accepted, ACCEPT, call_answer
/// `call_ready` is sent by the callee when the call rings and relayed separately; a caller that has not applied it
/// yet is still in the pre-ring `.active`.
final class CallerAcceptLatchTests: XCTestCase {

    private typealias Phase = CallerAcceptLatch.Phase
    private let call = "11111111-1111-4111-8111-111111111111"
    private let otherCall = "22222222-2222-4222-8222-222222222222"

    private struct CallerSim {
        var latch = CallerAcceptLatch()
        var phase: Phase
        var activeCallId: String?
        var keyReady = false
        var finalizeCount = 0
        var armedNets: [Double] = []
        var watchdogArmed = false
        var held = 0
        var drops: [CallerAcceptLatch.DropReason] = []

        /// `startCall()`: the OFFER round trip returned, the call is in its pre-ring `.active`.
        init(call: String, phase: Phase = .active) {
            self.phase = phase
            self.activeCallId = call
        }

        /// `peerAnswered` in `CallService`: set by `finalizeCallActive()` -> `handleCallAnswered()` only.
        var peerAnswered: Bool { finalizeCount > 0 }

        var micMuted: Bool {
            NativeSenderMuteDecisions.shouldMute(
                peerAnswered: peerAnswered, userMuted: false, fallbackActive: false)
        }

        mutating func callReady() {
            // `ws.onCallReady`: ignored once the call finalized.
            guard latch.finalizedCallId != activeCallId else { return }
            setPhase(.ringing)
        }

        mutating func callAnswer(_ id: String, sdp: Bool) {
            let step = latch.answerArrived(
                envelopeCallId: id, activeCallId: activeCallId, carriedSdp: sdp, phase: phase)
            apply(step, id: id)
        }

        mutating func callAccepted(_ id: String) {
            switch latch.acceptedArrived(envelopeCallId: id, activeCallId: activeCallId, phase: phase) {
            case .finalizeNow: finalize()
            case .waitForAnswer: watchdogArmed = true
            case .latched: break
            case .dropped(let reason): drops.append(reason)
            }
        }

        /// The callee's ACCEPT was verified and the session key is live (`sasReady`).
        mutating func acceptBound() {
            keyReady = true
            setPhase(CallerAcceptLatch.phaseOnSessionKeyReady(phase))
        }

        mutating func netFires(_ id: String) {
            if latch.netFired(callId: id, phase: phase) { finalize() }
        }

        mutating func endCall() {
            setPhase(.ended)
            latch.reset()
            activeCallId = nil
        }

        mutating func offerReturned() { setPhase(.active) }

        mutating func setPhase(_ new: Phase) {
            guard new != phase else { return }
            phase = new
            if let replay = latch.phaseChanged(to: new, activeCallId: activeCallId) {
                apply(replay.step, id: replay.callId)
            }
        }

        private mutating func apply(_ step: CallerAcceptLatch.AnswerStep, id: String) {
            switch step {
            case .finalizeNow: finalize()
            case .waitForAccept(let net): if let net { armedNets.append(net) }
            case .held: held += 1
            case .dropped(let reason): drops.append(reason)
            }
        }

        /// `finalizeCallActive()`.
        private mutating func finalize() {
            finalizeCount += 1
            latch.markFinalized(callId: activeCallId)
            if keyReady || phase == .encrypted { phase = .encrypted } else { phase = .active }
        }
    }

    // MARK: - iOS callee: call_accepted, call_answer, ACCEPT

    func testIosCalleeOrder_callReadyApplied() {
        var sim = CallerSim(call: call)
        sim.callReady()
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: false)
        sim.acceptBound()
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
        XCTAssertEqual(sim.phase, .encrypted)
    }

    func testIosCalleeOrder_callReadyNotYetApplied() {
        var sim = CallerSim(call: call)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: false)
        sim.acceptBound()
        sim.callReady()
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
        XCTAssertEqual(sim.phase, .encrypted, "a late call_ready must not knock a connected call back to ringing")
    }

    // MARK: - Android callee: call_accepted, call_answer (SDP), ACCEPT

    func testAndroidCalleeOrder_callReadyApplied() {
        var sim = CallerSim(call: call)
        sim.callReady()
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: true)
        sim.acceptBound()
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
        XCTAssertTrue(sim.armedNets.isEmpty, "accept was already latched: no countdown needed")
    }

    func testAndroidCalleeOrder_callReadyNotYetApplied() {
        var sim = CallerSim(call: call)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: true)
        sim.acceptBound()
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
    }

    // MARK: - Android callee after its 5 s reserve timer: call_accepted, ACCEPT, call_answer (SDP)

    func testAndroidReserveTimerOrder_callReadyApplied() {
        var sim = CallerSim(call: call)
        sim.callReady()
        sim.callAccepted(call)
        sim.acceptBound()
        sim.callAnswer(call, sdp: true)
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
    }

    /// THE REGRESSION. No call_ready yet: the ACCEPT moves the pre-ring `.active` caller to `.encrypted`, and the
    /// answer used to be dropped there, leaving the microphone muted for the whole call.
    func testAndroidReserveTimerOrder_callReadyNotYetApplied() {
        var sim = CallerSim(call: call)
        sim.callAccepted(call)
        sim.acceptBound()
        XCTAssertEqual(sim.phase, .encrypted)
        sim.callAnswer(call, sdp: true)
        XCTAssertEqual(sim.finalizeCount, 1, "the answer must close the latch, not be dropped at .encrypted")
        XCTAssertFalse(sim.micMuted)
        XCTAssertEqual(sim.phase, .encrypted, "finalizing must never walk .encrypted back to .active")
        XCTAssertTrue(sim.drops.isEmpty)
    }

    // MARK: - Desktop callee: call_accepted, ACCEPT, call_answer

    func testDesktopCalleeOrder_callReadyApplied() {
        var sim = CallerSim(call: call)
        sim.callReady()
        sim.callAccepted(call)
        sim.acceptBound()
        sim.callAnswer(call, sdp: false)
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
    }

    /// THE REGRESSION, desktop shape: ACCEPT always precedes the answer, so whenever call_ready has not been
    /// applied the caller is `.encrypted` when the bare answer lands.
    func testDesktopCalleeOrder_callReadyNotYetApplied() {
        var sim = CallerSim(call: call)
        sim.callAccepted(call)
        sim.acceptBound()
        sim.callAnswer(call, sdp: false)
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
        XCTAssertEqual(sim.phase, .encrypted)
    }

    // MARK: - accept lost or late

    /// call_accepted lost on a dead socket and retransmitted after the ACCEPT and the answer: the retransmit lands at
    /// `.encrypted` and must close the latch.
    func testAcceptedArrivingLastAtEncryptedClosesTheLatch() {
        var sim = CallerSim(call: call)
        sim.acceptBound()
        sim.callAnswer(call, sdp: true)
        XCTAssertEqual(sim.finalizeCount, 0, "an SDP answer alone is not a human accept")
        XCTAssertTrue(sim.micMuted)
        XCTAssertEqual(sim.armedNets, [AcceptGateDecisions.ringSafetyFallbackSeconds])
        sim.callAccepted(call)
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
    }

    /// A peer that never sends call_accepted: the countdown must fire in `.encrypted` (and in pre-ring `.active`),
    /// not only in `.ringing`.
    func testCountdownFiresAtEncryptedAndPreRingActive() {
        for phase in [Phase.encrypted, Phase.active] {
            var sim = CallerSim(call: call)
            if phase == .encrypted { sim.acceptBound() }
            sim.callAnswer(call, sdp: false)
            XCTAssertEqual(sim.armedNets, [AcceptGateDecisions.bareAnswerFallbackSeconds], "phase \(phase)")
            XCTAssertTrue(sim.micMuted)
            sim.netFires(call)
            XCTAssertEqual(sim.finalizeCount, 1, "phase \(phase)")
            XCTAssertFalse(sim.micMuted)
        }
    }

    func testCountdownDoesNothingAfterFinalizeOrAtCallEnd() {
        var sim = CallerSim(call: call)
        sim.callReady()
        sim.callAnswer(call, sdp: false)
        sim.callAccepted(call)
        XCTAssertEqual(sim.finalizeCount, 1)
        sim.netFires(call)
        XCTAssertEqual(sim.finalizeCount, 1, "already finalized: the net must not run it twice")

        var ended = CallerSim(call: call)
        ended.callAnswer(call, sdp: false)
        ended.endCall()
        ended.netFires(call)
        XCTAssertEqual(ended.finalizeCount, 0, "call ended before the net fired")
    }

    // MARK: - another call

    /// A `call_answer` that names another call is dropped and never touches the current call's latch.
    func testAnswerForAnotherCallIsDropped() {
        for phase in [Phase.ringing, Phase.active, Phase.encrypted] {
            var sim = CallerSim(call: call, phase: phase)
            sim.callAccepted(call)
            sim.callAnswer(otherCall, sdp: false)
            XCTAssertEqual(sim.finalizeCount, 0, "phase \(phase)")
            XCTAssertEqual(sim.drops, [.otherCall], "phase \(phase)")
            XCTAssertNil(sim.latch.localHandshakeReadyCallId, "phase \(phase)")
            XCTAssertTrue(sim.micMuted)
            // The genuine answer still closes the latch afterwards.
            sim.callAnswer(call, sdp: false)
            XCTAssertEqual(sim.finalizeCount, 1, "phase \(phase)")
        }
    }

    /// A stale `call_accepted` for another call must not overwrite the current call's accept flag.
    func testAcceptedForAnotherCallNeitherFinalizesNorOverwritesTheFlag() {
        var sim = CallerSim(call: call)
        sim.callAccepted(call)
        sim.callAccepted(otherCall)
        XCTAssertEqual(sim.drops, [.otherCall])
        XCTAssertEqual(sim.latch.acceptedCallId, call)
        sim.callAnswer(call, sdp: false)
        XCTAssertEqual(sim.finalizeCount, 1)
    }

    // MARK: - redelivery

    func testRedeliveredMessagesAfterFinalizeAreDropped() {
        var sim = CallerSim(call: call)
        sim.callReady()
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: false)
        sim.acceptBound()
        XCTAssertEqual(sim.finalizeCount, 1)
        sim.callAnswer(call, sdp: false)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: true)
        XCTAssertEqual(sim.finalizeCount, 1, "a redelivery must not re-open a closed latch")
        XCTAssertEqual(sim.drops, [.finalized, .finalized, .finalized])
    }

    func testMessagesOutsideACallAreDropped() {
        for phase in [Phase.idle, Phase.ended] {
            var latch = CallerAcceptLatch()
            XCTAssertEqual(
                latch.answerArrived(envelopeCallId: call, activeCallId: nil, carriedSdp: false, phase: phase),
                .dropped(.notInCall))
            XCTAssertEqual(
                latch.acceptedArrived(envelopeCallId: call, activeCallId: nil, phase: phase),
                .dropped(.notInCall))
            XCTAssertNil(latch.held)
            XCTAssertNil(latch.acceptedCallId)
        }
    }

    func testAnswerWithNoCallIdAtAllIsDropped() {
        var latch = CallerAcceptLatch()
        XCTAssertEqual(
            latch.answerArrived(envelopeCallId: "", activeCallId: nil, carriedSdp: false, phase: .ringing),
            .dropped(.noCallId))
    }

    /// An envelope without a call id falls back to the bound active call, as every other call_* handler does.
    func testAnswerWithoutEnvelopeIdUsesTheActiveCall() {
        var sim = CallerSim(call: call, phase: .ringing)
        sim.callAccepted(call)
        let step = sim.latch.answerArrived(
            envelopeCallId: "", activeCallId: call, carriedSdp: false, phase: .ringing)
        XCTAssertEqual(step, .finalizeNow)
    }

    // MARK: - early answer while the caller is still .connecting

    /// An answer that beats the caller's own OFFER round trip is held, then applied once the call moves on.
    func testAnswerWhileConnectingIsHeldAndAppliedWhenTheCallBecomesActive() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callAccepted(call)  // latched while connecting
        XCTAssertEqual(sim.finalizeCount, 0)
        sim.callAnswer(call, sdp: true)
        XCTAssertEqual(sim.held, 1)
        XCTAssertEqual(sim.finalizeCount, 0, "nothing is applied before the call is far enough along")
        XCTAssertTrue(sim.micMuted)
        sim.offerReturned()
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
        XCTAssertNil(sim.latch.held)
    }

    func testHeldAnswerWithoutAcceptWaitsForTheAccept() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callAnswer(call, sdp: true)
        sim.offerReturned()
        XCTAssertEqual(sim.finalizeCount, 0)
        XCTAssertEqual(sim.armedNets, [AcceptGateDecisions.ringSafetyFallbackSeconds])
        sim.callAccepted(call)
        XCTAssertEqual(sim.finalizeCount, 1)
    }

    /// One slot: a second answer replaces the first, and only the newest is ever applied.
    func testOnlyOneAnswerIsHeld() {
        var latch = CallerAcceptLatch()
        _ = latch.answerArrived(envelopeCallId: call, activeCallId: nil, carriedSdp: false, phase: .connecting)
        _ = latch.answerArrived(envelopeCallId: otherCall, activeCallId: nil, carriedSdp: true, phase: .connecting)
        XCTAssertEqual(latch.held, CallerAcceptLatch.HeldAnswer(callId: otherCall, carriedSdp: true))
    }

    /// The held answer is for one call id: if another call became current, it is discarded, never applied.
    func testHeldAnswerForAnotherCallIsDiscardedWhenTheCallMovesOn() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callAnswer(call, sdp: false)
        sim.activeCallId = otherCall
        sim.offerReturned()
        XCTAssertEqual(sim.finalizeCount, 0)
        XCTAssertNil(sim.latch.held)
        XCTAssertNil(sim.latch.localHandshakeReadyCallId)
    }

    /// Discarded on call end: a held answer must not leak into the next call.
    func testHeldAnswerIsDiscardedOnCallEnd() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callAnswer(call, sdp: false)
        XCTAssertNotNil(sim.latch.held)
        sim.endCall()
        XCTAssertNil(sim.latch.held)
        XCTAssertEqual(sim.finalizeCount, 0)

        // And reset() alone clears it, whatever phase the app is in.
        var latch = CallerAcceptLatch()
        _ = latch.answerArrived(envelopeCallId: call, activeCallId: nil, carriedSdp: false, phase: .connecting)
        latch.reset()
        XCTAssertNil(latch.held)
        XCTAssertNil(latch.phaseChanged(to: .active, activeCallId: call))
    }

    // MARK: - the microphone, before and after

    /// The state this whole change is about: until the latch closes the native sender is muted, afterwards it is
    /// open (a user mute still wins).
    func testMicrophoneStaysMutedUntilTheLatchClosesAndOpensExactlyOnce() {
        var sim = CallerSim(call: call)
        XCTAssertTrue(sim.micMuted)
        sim.callAccepted(call)
        XCTAssertTrue(sim.micMuted, "an accept alone does not open the microphone")
        sim.acceptBound()
        XCTAssertTrue(sim.micMuted, "neither does the ACCEPT: the latch is closed by call_answer + call_accepted")
        sim.callAnswer(call, sdp: false)
        XCTAssertFalse(sim.micMuted)
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertTrue(
            NativeSenderMuteDecisions.shouldMute(peerAnswered: true, userMuted: true, fallbackActive: false),
            "a mute the user set while ringing still wins after the latch closes")
    }

    // MARK: - rules the glue relies on

    func testSessionKeyReadyOnlyAdvancesThePreRingPhases() {
        XCTAssertEqual(CallerAcceptLatch.phaseOnSessionKeyReady(.active), .encrypted)
        XCTAssertEqual(CallerAcceptLatch.phaseOnSessionKeyReady(.connecting), .encrypted)
        XCTAssertEqual(CallerAcceptLatch.phaseOnSessionKeyReady(.ringing), .ringing,
                       "the callee has not answered: the caller UI stays on ringing")
        XCTAssertEqual(CallerAcceptLatch.phaseOnSessionKeyReady(.encrypted), .encrypted)
        XCTAssertEqual(CallerAcceptLatch.phaseOnSessionKeyReady(.idle), .idle)
        XCTAssertEqual(CallerAcceptLatch.phaseOnSessionKeyReady(.ended), .ended, "a finished call is never revived")
    }

    func testAdmittedPhases() {
        XCTAssertTrue(CallerAcceptLatch.admits(.ringing))
        XCTAssertTrue(CallerAcceptLatch.admits(.active))
        XCTAssertTrue(CallerAcceptLatch.admits(.encrypted))
        XCTAssertFalse(CallerAcceptLatch.admits(.connecting))
        XCTAssertFalse(CallerAcceptLatch.admits(.idle))
        XCTAssertFalse(CallerAcceptLatch.admits(.ended))
    }

    func testShouldAcceptAnswerAdmitsEncryptedUntilFinalized() {
        XCTAssertTrue(AcceptGateDecisions.shouldAcceptAnswer(
            isRinging: false, isPreRingActive: false, isEncrypted: true, alreadyFinalized: false))
        XCTAssertFalse(AcceptGateDecisions.shouldAcceptAnswer(
            isRinging: false, isPreRingActive: false, isEncrypted: true, alreadyFinalized: true))
    }
}
