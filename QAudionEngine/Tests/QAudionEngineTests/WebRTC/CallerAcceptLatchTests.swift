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
        /// `CallService.endCall()`'s generation counter, and the value `startCall` captured before the OFFER.
        var generation = 0
        var offerGeneration = 0
        /// `startCall` hit the `.abandon` branch after the OFFER returned.
        var abandoned = false
        /// `startCall`'s video start (after the OFFER): whether the pipeline was created paused, and whether the
        /// setup stopped there because the call was torn down during the camera start.
        var videoStartedPaused: Bool?
        var abandonedAfterVideoStart = false

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
            // W-CALLERSTATEGUARD: and ignored in the phases `call_ready` is stale in.
            guard let next = CallerOutgoingStatePolicy.phaseOnCallReady(phase) else { return }
            setPhase(next)
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
            generation += 1
            setPhase(.ended)
            latch.reset()
            activeCallId = nil
        }

        /// `startCall` after `beginAndroidOutgoing` returned: what the app does with `callState`.
        mutating func offerReturned() {
            switch CallerOutgoingStatePolicy.afterOfferReturned(
                phase: phase, callTornDown: generation != offerGeneration
            ) {
            case .advanceToActive: setPhase(.active)
            case .keepPhase: break
            case .abandon: abandoned = true
            }
        }

        /// `startCall` after `await startVideoPipeline(...)`: the pipeline start and the teardown check.
        mutating func videoStarted() {
            let finalized = latch.finalizedCallId != nil && latch.finalizedCallId == activeCallId
            videoStartedPaused = CallerOutgoingStatePolicy.videoStartsPaused(callAlreadyFinalized: finalized)
            if !CallerOutgoingStatePolicy.shouldContinueSetupAfterVideoStart(
                callTornDown: generation != offerGeneration) {
                abandonedAfterVideoStart = true
            }
        }

        /// A NEW call started while the previous call's OFFER was still in flight.
        mutating func redial(_ id: String) {
            activeCallId = id
            setPhase(.connecting)
        }

        /// The deferred `.ended` -> `.idle` settle of the peer-offline / busy handlers.
        mutating func settleEndedToIdle() {
            if CallerOutgoingStatePolicy.shouldSettleToIdle(phase) { setPhase(.idle) }
        }

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
        XCTAssertEqual(sim.drops, [.otherCall], "the discard is reported, not silent")
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

    // MARK: - W-CALLERSTATEGUARD: what the OFFER returning may do to callState

    /// Normal order: the OFFER returns first, `call_ready` comes after, then accepted + answer.
    func testStateGuard_normalOrderStillReachesActive() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.offerReturned()
        XCTAssertEqual(sim.phase, .active, "the OFFER returning moves .connecting to the pre-ring .active")
        XCTAssertFalse(sim.abandoned)
        sim.callReady()
        XCTAssertEqual(sim.phase, .ringing)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: false)
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
        XCTAssertEqual(sim.phase, .active, "finalized without the session key: the connected .active")
    }

    /// A desktop callee sends `call_ready` as soon as the call_offer reaches it, while the OFFER is still being
    /// built: the caller is `.ringing` when `beginAndroidOutgoing` returns, and stays so.
    func testStateGuard_earlyCallReadyKeepsRinging() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callReady()
        XCTAssertEqual(sim.phase, .ringing)
        sim.offerReturned()
        XCTAssertEqual(sim.phase, .ringing, "the OFFER returning must not overwrite .ringing with .active")
        XCTAssertFalse(sim.abandoned)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: true)
        XCTAssertEqual(sim.finalizeCount, 1, "the latch still finalizes")
        XCTAssertFalse(sim.micMuted, "and opens the microphone")
    }

    /// Same early `call_ready`, and the callee's whole answer already in: the held answer is replayed when
    /// `call_ready` moves the caller to `.ringing`, and the OFFER returning afterwards changes nothing.
    func testStateGuard_earlyCallReadyWithEarlyAnswerAndAccept() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: true)
        XCTAssertEqual(sim.held, 1)
        sim.callReady()
        XCTAssertEqual(sim.finalizeCount, 1, "the held answer is applied once the call is ringing")
        XCTAssertFalse(sim.micMuted)
        let phaseAfterFinalize = sim.phase
        sim.offerReturned()
        XCTAssertEqual(sim.phase, phaseAfterFinalize, "the OFFER returning leaves a finalized call alone")
        XCTAssertEqual(sim.finalizeCount, 1, "and finalizes nothing twice")
    }

    /// The callee's ACCEPT is bound while the OFFER is still being built: `.encrypted` must survive the return.
    func testStateGuard_acceptBoundBeforeOfferReturnsKeepsEncrypted() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.acceptBound()
        XCTAssertEqual(sim.phase, .encrypted)
        sim.offerReturned()
        XCTAssertEqual(sim.phase, .encrypted, "the OFFER returning must not walk .encrypted back to .active")
        XCTAssertFalse(sim.abandoned)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: false)
        XCTAssertEqual(sim.finalizeCount, 1, "the latch still finalizes")
        XCTAssertFalse(sim.micMuted, "and opens the microphone")
        XCTAssertEqual(sim.phase, .encrypted)
    }

    /// Desktop order (accepted, ACCEPT, answer) entirely inside the OFFER window.
    func testStateGuard_desktopOrderInsideTheOfferWindow() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callAccepted(call)
        sim.acceptBound()
        sim.callAnswer(call, sdp: true)
        XCTAssertEqual(sim.phase, .encrypted)
        sim.offerReturned()
        XCTAssertEqual(sim.phase, .encrypted)
        XCTAssertEqual(sim.finalizeCount, 1, "the latch still finalizes")
        XCTAssertFalse(sim.micMuted)
    }

    /// A late `call_ready` after the ACCEPT was bound (call not finalized yet) is stale.
    func testStateGuard_callReadyAfterAcceptBoundIsIgnored() {
        var sim = CallerSim(call: call)
        sim.acceptBound()
        XCTAssertEqual(sim.phase, .encrypted)
        sim.callReady()
        XCTAssertEqual(sim.phase, .encrypted, "call_ready must not knock an .encrypted call back to ringing")
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: false)
        XCTAssertEqual(sim.finalizeCount, 1)
        XCTAssertFalse(sim.micMuted)
    }

    /// A late or redelivered `call_ready` on a call that ended must not re-open it.
    func testStateGuard_callReadyOnAFinishedCallIsIgnored() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.endCall()
        // `canonicalActiveCallId()` can still name a call (the CallKit id fallback): the finalized-id guard alone
        // does not stop this one.
        sim.activeCallId = call
        sim.callReady()
        XCTAssertEqual(sim.phase, .ended, "call_ready must not resurrect a finished call")
    }

    /// The user hangs up (or the peer is offline / busy / cancels) while the OFFER is being built, and the OFFER
    /// then returns normally: the call stays finished.
    func testStateGuard_hangupDuringOfferDoesNotResurrectTheCall() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.endCall()
        XCTAssertEqual(sim.phase, .ended)
        sim.offerReturned()
        XCTAssertTrue(sim.abandoned, "startCall stops instead of building a call on a finished one")
        XCTAssertEqual(sim.phase, .ended, "and the state is not touched")
        XCTAssertEqual(sim.finalizeCount, 0)
        XCTAssertTrue(sim.micMuted)
        // `.idle` (endCall's own immediate reset) is the same.
        var idleSim = CallerSim(call: call, phase: .connecting)
        idleSim.endCall()
        idleSim.setPhase(.idle)
        idleSim.offerReturned()
        XCTAssertTrue(idleSim.abandoned)
        XCTAssertEqual(idleSim.phase, .idle)
    }

    /// An answer held while .connecting, then a hangup: nothing is replayed onto the finished call.
    func testStateGuard_heldAnswerIsNotAppliedAfterAHangupDuringTheOffer() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: true)
        sim.endCall()
        sim.offerReturned()
        XCTAssertTrue(sim.abandoned)
        XCTAssertEqual(sim.phase, .ended)
        XCTAssertEqual(sim.finalizeCount, 0)
        XCTAssertNil(sim.latch.held)
    }

    /// Hangup, then a NEW call is placed (phase back to .connecting) before the first call's OFFER returns: the
    /// first call's continuation must not touch the new call. The phase alone cannot tell, the teardown generation can.
    func testStateGuard_redialDuringTheOldOfferIsLeftAlone() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.endCall()
        sim.redial(otherCall)
        XCTAssertEqual(sim.phase, .connecting)
        sim.offerReturned()
        XCTAssertTrue(sim.abandoned)
        XCTAssertEqual(sim.phase, .connecting, "the new call is still connecting, not advanced by the old continuation")
    }

    /// The peer-offline / busy handlers settle `.ended` to `.idle` one second later: not over a redial.
    func testStateGuard_deferredIdleDoesNotClobberARedial() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.endCall()  // peer offline: .ended
        sim.redial(otherCall)
        sim.settleEndedToIdle()
        XCTAssertEqual(sim.phase, .connecting, "a redial inside the hold window keeps its state")
        var quiet = CallerSim(call: call, phase: .connecting)
        quiet.endCall()
        quiet.settleEndedToIdle()
        XCTAssertEqual(quiet.phase, .idle, "with no redial the .ended still settles to .idle")
    }

    /// A video call nobody has answered: the pipeline starts paused (nothing leaves the device before the accept).
    func testStateGuard_videoStartsPausedOnAnUnansweredCall() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.offerReturned()
        sim.videoStarted()
        XCTAssertEqual(sim.videoStartedPaused, true)
        XCTAssertFalse(sim.abandonedAfterVideoStart)
        XCTAssertEqual(sim.finalizeCount, 0)
    }

    /// The call finalized inside the OFFER window (early `call_ready` replayed the held answer): `finalizeCallActive()`
    /// ran before any pipeline existed, so its un-pause did nothing; the pipeline must not be created paused.
    func testStateGuard_videoStartsUnpausedWhenTheCallFinalizedInTheOfferWindow() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.callAccepted(call)
        sim.callAnswer(call, sdp: true)
        sim.callReady()
        XCTAssertEqual(sim.finalizeCount, 1)
        sim.offerReturned()
        sim.videoStarted()
        XCTAssertEqual(sim.videoStartedPaused, false, "a finalized call's video must not stay paused for the whole call")
        XCTAssertFalse(sim.abandonedAfterVideoStart)
        XCTAssertFalse(sim.micMuted)
    }

    /// A hangup during the camera start: the setup stops, no WebRTC controller is built for the dead call.
    func testStateGuard_hangupDuringTheVideoStartAbandonsTheSetup() {
        var sim = CallerSim(call: call, phase: .connecting)
        sim.offerReturned()
        XCTAssertEqual(sim.phase, .active)
        sim.endCall()
        sim.videoStarted()
        XCTAssertTrue(sim.abandonedAfterVideoStart, "startCall must not go on to build a call that ended")
        XCTAssertEqual(sim.phase, .ended)
        XCTAssertEqual(sim.finalizeCount, 0)
        XCTAssertTrue(sim.micMuted)
    }

    // MARK: - W-CALLERSTATEGUARD: the pure rules

    func testStateGuardRules_afterOfferReturned() {
        typealias P = CallerOutgoingStatePolicy
        XCTAssertEqual(P.afterOfferReturned(phase: .connecting, callTornDown: false), .advanceToActive)
        XCTAssertEqual(P.afterOfferReturned(phase: .ringing, callTornDown: false), .keepPhase)
        XCTAssertEqual(P.afterOfferReturned(phase: .active, callTornDown: false), .keepPhase)
        XCTAssertEqual(P.afterOfferReturned(phase: .encrypted, callTornDown: false), .keepPhase)
        XCTAssertEqual(P.afterOfferReturned(phase: .idle, callTornDown: false), .abandon)
        XCTAssertEqual(P.afterOfferReturned(phase: .ended, callTornDown: false), .abandon)
        for phase in [Phase.idle, .connecting, .ringing, .active, .encrypted, .ended] {
            XCTAssertEqual(P.afterOfferReturned(phase: phase, callTornDown: true), .abandon,
                           "a torn-down call is abandoned whatever the phase is by now")
        }
    }

    func testStateGuardRules_afterOfferThrew() {
        typealias P = CallerOutgoingStatePolicy
        XCTAssertEqual(P.afterOfferThrew(callTornDown: false), .teardownAndIdle)
        XCTAssertEqual(P.afterOfferThrew(callTornDown: true), .leaveAlone,
                       "an already torn-down call is not torn down again (that would end the current call)")
    }

    func testStateGuardRules_phaseOnCallReady() {
        typealias P = CallerOutgoingStatePolicy
        XCTAssertEqual(P.phaseOnCallReady(.connecting), .ringing)
        XCTAssertEqual(P.phaseOnCallReady(.active), .ringing)
        XCTAssertEqual(P.phaseOnCallReady(.ringing), .ringing)
        XCTAssertNil(P.phaseOnCallReady(.encrypted))
        XCTAssertNil(P.phaseOnCallReady(.idle))
        XCTAssertNil(P.phaseOnCallReady(.ended))
    }

    func testStateGuardRules_shouldContinueSetupAfterVideoStart() {
        typealias P = CallerOutgoingStatePolicy
        XCTAssertTrue(P.shouldContinueSetupAfterVideoStart(callTornDown: false))
        XCTAssertFalse(P.shouldContinueSetupAfterVideoStart(callTornDown: true))
    }

    func testStateGuardRules_videoStartsPaused() {
        typealias P = CallerOutgoingStatePolicy
        XCTAssertTrue(P.videoStartsPaused(callAlreadyFinalized: false))
        XCTAssertFalse(P.videoStartsPaused(callAlreadyFinalized: true))
    }

    func testStateGuardRules_shouldSettleToIdle() {
        typealias P = CallerOutgoingStatePolicy
        XCTAssertTrue(P.shouldSettleToIdle(.ended))
        for phase in [Phase.idle, .connecting, .ringing, .active, .encrypted] {
            XCTAssertFalse(P.shouldSettleToIdle(phase))
        }
    }
}
