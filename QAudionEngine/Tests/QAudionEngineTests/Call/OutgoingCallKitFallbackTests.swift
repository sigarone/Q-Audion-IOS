import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03, review of #169) — the CallKit-start `Task` of `AppState.startCall` has four exits, and the
/// success branch was the only one that asked `OutgoingCallKitStartPolicy` whether the call it was started for is
/// still the current one. The other three (CallKit-free mode, `startOutgoingCall` returning `nil`, and it throwing)
/// self-activate the call's audio (`CallService.handleAudioSessionActivated()` + the ring-back cue gate) after an
/// `await`, i.e. possibly after a `call_busy` already ended the call and the teardown cleared
/// `CallService.audioSessionActive`: the late activation set it back to `true` with no call behind it, and the redial
/// (busy, then redial) started with the W464 gate pre-satisfied. Each of the three is now gated by
/// `OutgoingCallKitStartPolicy.decideFallback`; `CallerBusyWiringTests` pins that `AppState` does so.
final class OutgoingCallKitFallbackTests: XCTestCase {

    private let callA = "11111111-1111-4111-8111-111111111111"
    private let callB = "22222222-2222-4222-8222-222222222222"

    // MARK: - the pure decision

    func testAStillCurrentCallActivatesItsAudio() {
        XCTAssertEqual(OutgoingCallKitStartPolicy.decideFallback(callStillCurrent: true), .activateSession)
    }

    func testAnEndedCallActivatesNothing() {
        XCTAssertEqual(OutgoingCallKitStartPolicy.decideFallback(callStillCurrent: false), .callIsOver)
    }

    // MARK: - the three branches, replayed

    /// `AppState` reduced to what the three fallback branches look at.
    private final class Dialer {
        var latch = CallerAcceptLatch()
        var isInCall = false
        var phase: CallerAcceptLatch.Phase = .idle
        /// `CallService.audioSessionActive` (the W464 gate): set by `handleAudioSessionActivated`, cleared by the
        /// teardown's `callService.endCall()`.
        var audioSessionActive = false
        /// `outgoingAudioSessionReady` (the ring-back cue gate).
        var ringbackReady = false

        func dial(_ id: String) {
            latch.beginOutgoing(callId: id)
            isInCall = true
            phase = .ringing
        }

        /// `AppState.endCall`.
        func endCall() {
            latch.reset()
            isInCall = false
            phase = .idle
            audioSessionActive = false
            ringbackReady = false
        }

        /// The gate, then `endOutgoingCallAfterTerminalEnvelope`.
        func busy(_ id: String) {
            guard case .endOutgoingCall = latch.terminalEnvelopeArrived(envelopeCallId: id, phase: phase) else { return }
            endCall()
        }

        /// One of the three fallback branches, as `startCall`'s `Task` runs it
        /// (`outgoingFallbackActivationAllowed`, then the activation).
        func fallbackBranch(wireCallId: String) {
            let current = isInCall && latch.isCurrentOutgoingCall(envelopeCallId: wireCallId)
            switch OutgoingCallKitStartPolicy.decideFallback(callStillCurrent: current) {
            case .activateSession:
                audioSessionActive = true            // callService.handleAudioSessionActivated()
                ringbackReady = true                 // markOutgoingAudioSessionReady()
            case .callIsOver:
                break
            }
        }
    }

    /// The normal case (no busy): every one of the three branches still activates the call's audio, as before.
    func testAllThreeBranchesStillActivateACurrentCall() {
        for _ in 0..<3 {
            let d = Dialer()
            d.dial(callA)
            d.fallbackBranch(wireCallId: callA)
            XCTAssertTrue(d.audioSessionActive)
            XCTAssertTrue(d.ringbackReady)
        }
    }

    /// The incident: busy first, the fallback branch runs afterwards. Nothing is activated, so the W464 gate of the
    /// redial is not pre-satisfied.
    func testABusyBeforeTheFallbackBranchLeavesTheGateClosedForTheRedial() {
        let d = Dialer()
        d.dial(callA)
        d.busy(callA)
        d.fallbackBranch(wireCallId: callA)               // the late Task of call A

        XCTAssertFalse(d.audioSessionActive, "no activation behind an ended call")
        XCTAssertFalse(d.ringbackReady)

        d.dial(callB)                                     // the redial
        XCTAssertFalse(d.audioSessionActive, "the redial must not start with the W464 gate already satisfied")
        d.fallbackBranch(wireCallId: callB)
        XCTAssertTrue(d.audioSessionActive, "and its own activation opens it")
    }

    /// Call A's late Task lands after the redial was dialled: it must neither activate nor mark the REDIAL's audio.
    func testAnEarlierCallsLateBranchNeverActivatesTheRedial() {
        let d = Dialer()
        d.dial(callA)
        d.busy(callA)
        d.dial(callB)

        d.fallbackBranch(wireCallId: callA)

        XCTAssertFalse(d.audioSessionActive)
        XCTAssertFalse(d.ringbackReady)
    }

    /// A call that ended without a busy (a local hangup before the branch ran) is over just the same.
    func testAHangupBeforeTheFallbackBranchActivatesNothing() {
        let d = Dialer()
        d.dial(callA)
        d.endCall()
        d.fallbackBranch(wireCallId: callA)
        XCTAssertFalse(d.audioSessionActive)
        XCTAssertFalse(d.ringbackReady)
    }
}
