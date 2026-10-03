import Foundation

/// W-CALLERSTATEGUARD (2026-10-03) — which `callState` writes the caller's outgoing path may make, as pure
/// functions so every arrival order can be tested without `AppState` (the same shape as `CallerAcceptLatch`,
/// whose `Phase` it shares).
///
/// ## The defect this closes
///
/// `AppState.startCall` set `callState = .active` UNCONDITIONALLY when `CallService.beginAndroidOutgoing`
/// returned. That call first ships `call_offer` and only then builds and signs the PQC OFFER, so for a while the
/// callee can already answer with `call_ready`, and the callee's ACCEPT can already be bound. The unconditional
/// assignment then overwrote whatever the call had become in the meantime:
///   - an early `call_ready` had moved the call to `.ringing`: it went back to the pre-ring `.active`;
///   - the session-key observer had moved the call to `.encrypted` (the ACCEPT was bound first): it was walked
///     back to `.active`;
///   - the user had hung up (or the peer was offline / busy / cancelled) while the OFFER was being built: the call
///     was resurrected from `.idle`/`.ended` to `.active` and `startCall` went on to build a WebRTC controller,
///     a video pipeline and a call record for a call that no longer existed.
/// The same class of overwrite sat in three more places on that path: `ws.onCallReady` wrote `.ringing` from any
/// state (a late `call_ready` re-opened a finished call, or knocked an `.encrypted` one back), the peer-offline
/// and busy handlers settled `.ended` to `.idle` one second later whatever the call had become (a redial inside
/// that second lost its `.connecting`), and the two `beginAndroidOutgoing` failure branches reset `.idle` and
/// `isInCall` for a call that had already been torn down (and may by then be another call).
///
/// ## The rule
///
/// A write moves the state forward from the exact state it is meant to leave, and nothing else:
///   - the OFFER having returned moves `.connecting` to `.active`, and only that;
///   - `call_ready` moves `.connecting`/`.active`/`.ringing` to `.ringing`, and only those;
///   - `.ended` settles to `.idle`, and only that;
///   - a call torn down while the OFFER was in flight is never touched again by the continuation.
/// "Torn down" is not read from the phase alone: `CallService.endCall()` bumps a generation counter at its single
/// choke point, so a continuation that finds the generation changed knows its call ended even when a NEW call
/// has since put the phase back to `.connecting`.
public enum CallerOutgoingStatePolicy {

    public typealias Phase = CallerAcceptLatch.Phase

    /// What `startCall` does when `beginAndroidOutgoing` returned normally.
    public enum OfferReturnedStep: Equatable {
        /// The call is still in the phase `startCall` put it in (`.connecting`): it is now the pre-ring `.active`.
        case advanceToActive
        /// The call moved on while the OFFER was in flight (`.ringing`, `.active`, `.encrypted`): leave it.
        case keepPhase
        /// The call was torn down while the OFFER was in flight: stop, touch nothing, tell the peer to dismiss it.
        case abandon
    }

    /// What `startCall` does when `beginAndroidOutgoing` threw (cancelled or failed).
    public enum OfferThrewStep: Equatable {
        /// This call is still the current one: tear it down and reset to `.idle`.
        case teardownAndIdle
        /// The call was already torn down (by a hangup, a peer-offline/busy/cancel, ...): do not tear down again,
        /// that would end whatever call is current now.
        case leaveAlone
    }

    /// The OFFER round trip returned.
    /// - Parameters:
    ///   - phase: the caller's phase right now.
    ///   - callTornDown: `CallService.endCall()` ran since the OFFER was started (its generation changed).
    public static func afterOfferReturned(phase: Phase, callTornDown: Bool) -> OfferReturnedStep {
        // TEMP MUTANT (do not merge): the old unconditional `callState = .active`.
        _ = (phase, callTornDown)
        return .advanceToActive
    }

    /// `beginAndroidOutgoing` threw.
    public static func afterOfferThrew(callTornDown: Bool) -> OfferThrewStep {
        // TEMP MUTANT (do not merge): the old unconditional teardown.
        _ = callTornDown
        return .teardownAndIdle
    }

    /// The phase an inbound `call_ready` moves the caller to, or nil when it must be ignored. `call_ready` only
    /// means "the callee's phone is ringing": it is stale on a call that already ended (`.idle`/`.ended`, a late or
    /// redelivered envelope must not re-open it) and on one whose ACCEPT is already bound (`.encrypted`, the callee
    /// answered, R-ANSWER-FIRST). A call already finalized is excluded by the caller of this function.
    public static func phaseOnCallReady(_ phase: Phase) -> Phase? {
        // TEMP MUTANT (do not merge): the old unconditional `callState = .ringing`.
        _ = phase
        return .ringing
    }

    /// The deferred `.ended` -> `.idle` settle after a peer-offline / busy teardown. True only while the state is
    /// still the `.ended` that teardown left: a redial inside the hold window owns the state by then.
    public static func shouldSettleToIdle(_ phase: Phase) -> Bool {
        // TEMP MUTANT (do not merge): the old unconditional `callState = .idle`.
        _ = phase
        return true
    }
}
