import Foundation

/// W-ACCEPTLATCH (2026-10-03) — the caller's side of the WIRE_SPEC §3.5 two-flag latch, as a pure
/// value type so every arrival order can be tested without `AppState`.
///
/// ## What the latch decides
///
/// The caller may only open its microphone (and unpause video, play the "connected" chime, arm the
/// media-dead watchdog) once BOTH of these are true for the current call:
///   - the callee's `call_answer` has arrived (the "network is ready" flag, `localHandshakeReady`), and
///   - the callee's `call_accepted` has arrived (a human tapped Answer, `accepted`).
/// Whichever lands second runs `finalizeCallActive()` in `AppState`, exactly once. That function is the ONLY
/// place `CallService.handleCallAnswered()` is reached on the caller, and until it runs the native sender
/// stays muted (`NativeSenderMuteDecisions.shouldMute(peerAnswered: false ...)`): a latch that never closes
/// is a call in which the caller can hear but cannot be heard, for the whole call, with no watchdog armed
/// (the media-dead watchdog is armed by the same function).
///
/// ## The defect this closes
///
/// `AppState`'s gate for both messages used to read "caller is `.ringing`, or pre-ring `.active`". The
/// session-key observer moves a pre-ring `.active` caller to `.encrypted` the moment the callee's signed
/// ACCEPT is bound (that is the only call state it advances from). From then on neither message passed the
/// gate: `call_answer` was dropped ("callanswer dropped=1 reason=gate ringing=0 active=0 finalized=0"),
/// `call_accepted` was dropped, the latch never closed, and the caller's microphone stayed muted for the
/// whole call (in-app report from a 1.0.1161 TestFlight build: caller TX dead on both calls, audio start
/// deferred at the "peer answered" gate for the whole call).
///
/// The order that triggers it needs two things at once:
///   1. the callee's ACCEPT reaches the caller BEFORE its `call_answer`, and
///   2. the caller has not yet seen `call_ready` (so it is still in pre-ring `.active`, not `.ringing`).
/// Per callee platform under R-ANSWER-FIRST (the ACCEPT is only sent after the user answered):
///   - iOS callee:     call_accepted, call_answer, ACCEPT     (ACCEPT held until its own call_answer left)
///   - Android callee: call_accepted, call_answer, ACCEPT     (ACCEPT held until its call_answer left, or
///                     until a 5 s reserve timer: after that, call_accepted, ACCEPT, call_answer)
///   - desktop callee: call_accepted, ACCEPT, call_answer     (ACCEPT first, always)
/// so the desktop callee, and an Android callee whose answer is slower than its reserve timer, hit it whenever
/// `call_ready` has not been applied yet. `call_ready` is a separate relayed message with no ordering
/// guarantee against the others; field logs show callers still in pre-ring `.active` when `call_accepted`
/// arrives, so the precondition is real.
///
/// ## What changed
///
///   - `.encrypted` is an admitted phase. By then the signed ACCEPT has been verified and the session key
///     is live, so the latch is no weaker there than in `.ringing`/`.active`, where it has always run before
///     the ACCEPT arrives. The latch is a UI and microphone-start latch; the media security gates (frame
///     cryptor readiness, identity hold, DTLS fingerprint check, KCMAC rules) are enforced separately in the
///     media layer and are untouched.
///   - A `call_answer` that arrives while the caller is still `.connecting` (its own OFFER round trip has not
///     returned) is HELD, one per call and for that call id only, and applied when the call reaches a phase
///     that admits it. It is discarded when the call ends or another call becomes current.
///   - The accept-gate countdown fires in every admitted phase, not only `.ringing`: a pre-ring or
///     `.encrypted` caller of a peer that never sends `call_accepted` is no longer stranded.
///   - A `call_answer` that names another call is dropped. It used to be applied to whatever call was current.
///   - A `call_accepted` for another call no longer overwrites the current call's accept flag.
///
/// ## W-STALEENVELOPE (2026-10-03): the same object owns "which outgoing call is current"
///
/// The caller-side terminal envelopes (`call_peer_offline`, `call_busy`, `call_cancel`) used to end whatever call
/// was current, whatever call id they named, and their teardown never reset this latch (only `AppState.endCall`
/// did). Both defects are closed here, in one place that can be tested:
///   - `beginOutgoing(callId:)` records the wire id of the call `startCall` just began, and clears every flag left by
///     the previous call (a backstop for any teardown path that does not reset: a held early answer of call A can
///     never be replayed against call B, because B cannot begin without this reset);
///   - `terminalEnvelopeArrived` ends the call only when the envelope names the current outgoing call, and resets
///     the latch (and forgets the outgoing id) in the same step, so a teardown through this path resets exactly once.
public struct CallerAcceptLatch: Equatable {

    /// Mirror of `AppState`'s `CallState`, so the decision does not depend on the app target.
    public enum Phase: String, Equatable {
        case idle, connecting, ringing, active, encrypted, ended
    }

    public enum DropReason: String, Equatable {
        /// No call id could be determined from the envelope or the active call.
        case noCallId = "nocallid"
        /// The caller is not in a call (`.idle`/`.ended`).
        case notInCall = "notincall"
        /// The message names a call other than the current one.
        case otherCall = "othercall"
        /// `finalizeCallActive()` already ran for this call (a redelivery).
        case finalized = "finalized"
    }

    /// What `AppState` must do after a `call_answer`.
    public enum AnswerStep: Equatable {
        /// Both flags are in hand: run `finalizeCallActive()` now.
        case finalizeNow
        /// The local flag is stashed; arm the countdown when `netSeconds` is non-nil.
        case waitForAccept(netSeconds: Double?)
        /// The caller is not far enough along yet; the answer is kept and re-applied by `phaseChanged`.
        case held
        case dropped(DropReason)
    }

    /// What `AppState` must do after a `call_accepted`.
    public enum AcceptedStep: Equatable {
        /// Both flags are in hand: run `finalizeCallActive()` now.
        case finalizeNow
        /// The accept is latched but the callee's `call_answer` has not been applied: arm the
        /// accepted-without-answer watchdog.
        case waitForAnswer
        /// The caller is still `.connecting`: the accept flag is recorded, nothing else to do yet.
        case latched
        case dropped(DropReason)
    }

    /// A caller-side terminal envelope.
    public enum TerminalKind: String, Equatable {
        case peerOffline = "peer_offline"
        case busy
        case cancel
    }

    /// Why a terminal envelope was left alone.
    public enum TerminalIgnoreReason: String, Equatable {
        /// The envelope carries no call id (or an empty one). The server always stamps `call_id` on these
        /// envelopes and the WS client already drops a frame without one, so this is only a defensive net.
        case noCallId = "nocallid"
        /// No outgoing call is current (none began, or it already ended and the latch was reset).
        case noOutgoingCall = "nooutgoing"
        /// The envelope names a call other than the current outgoing one (late envelope of an old call).
        case otherCall = "othercall"
        /// The current outgoing call is already `.idle`/`.ended`.
        case notInCall = "notincall"
    }

    /// What `AppState` must do after a caller-side terminal envelope.
    public enum TerminalStep: Equatable {
        /// The envelope names the current outgoing call: tear it down. The latch has ALREADY been reset.
        case endOutgoingCall
        /// Not for the current outgoing call: touch nothing.
        case ignore(TerminalIgnoreReason)
    }

    /// The single `call_answer` kept while the caller is `.connecting`.
    public struct HeldAnswer: Equatable {
        public let callId: String
        public let carriedSdp: Bool
    }

    /// A held `call_answer` that was just re-applied by `phaseChanged`.
    public struct Replay: Equatable {
        public let callId: String
        public let carriedSdp: Bool
        public let step: AnswerStep
    }

    /// `call_answer` was applied (SDP or not) for this call: the local-handshake flag.
    public private(set) var localHandshakeReadyCallId: String?
    /// `call_accepted` was received for this call: the human-answered flag.
    public private(set) var acceptedCallId: String?
    /// `finalizeCallActive()` has run for this call.
    public private(set) var finalizedCallId: String?
    /// At most one early `call_answer`.
    public private(set) var held: HeldAnswer?
    /// The wire call id (lowercased) of the outgoing call this latch belongs to; nil when none is current.
    public private(set) var outgoingCallId: String?

    public init() {}

    // MARK: - Pure rules

    /// The phase the session-key observer moves the caller to when the session key becomes live. Only the
    /// pre-ring phases advance; `.ringing` stays put on purpose (the callee has not answered yet, see the
    /// W528 note in `AppState`), and a finished call is never revived.
    public static func phaseOnSessionKeyReady(_ phase: Phase) -> Phase {
        switch phase {
        case .active, .connecting: return .encrypted
        case .idle, .ringing, .encrypted, .ended: return phase
        }
    }

    /// Whether the latch may run in `phase` for a call that is not yet finalized.
    public static func admits(_ phase: Phase) -> Bool {
        switch phase {
        case .ringing, .active, .encrypted: return true
        case .idle, .connecting, .ended: return false
        }
    }

    // MARK: - Events

    /// `startCall` began an outgoing call with this wire id. Clears whatever the previous call left behind first.
    public mutating func beginOutgoing(callId: String) {
        // TEMP-MUTANT-STALEENVELOPE (do not merge): reset removed
        outgoingCallId = Self.nonEmpty(callId.lowercased())
    }

    /// True when `envelopeCallId` names the current outgoing call (case-insensitive). False for a missing or
    /// empty id and when no outgoing call is current.
    public func isCurrentOutgoingCall(envelopeCallId: String?) -> Bool {
        guard let id = Self.nonEmpty(envelopeCallId?.lowercased()), let current = outgoingCallId else { return false }
        return id == current
    }

    /// A caller-side `call_peer_offline` / `call_busy` / `call_cancel` arrived.
    ///
    /// Only an envelope naming the current outgoing call, while that call is still in a phase, ends it. A late
    /// envelope of an old call (hangup + redial, a WS reconnect redelivery) leaves the current call untouched. On
    /// `.endOutgoingCall` the latch is reset here, so the teardown that follows never leaves a held early answer or a
    /// finalized marker for the next call.
    public mutating func terminalEnvelopeArrived(envelopeCallId: String?, phase: Phase) -> TerminalStep {
        guard let id = Self.nonEmpty(envelopeCallId?.lowercased()) else { return .ignore(.noCallId) }
        guard let current = outgoingCallId else { return .ignore(.noOutgoingCall) }
        // TEMP-MUTANT-STALEENVELOPE (do not merge): id check removed
        _ = current
        switch phase {
        case .idle, .ended: return .ignore(.notInCall)
        case .connecting, .ringing, .active, .encrypted:
            // TEMP-MUTANT-STALEENVELOPE (do not merge): reset removed
            return .endOutgoingCall
        }
    }

    /// Whether a remote terminal envelope that is NOT for the current outgoing call may still end the call that is
    /// current (the incoming path). False when it names a call other than `activeCallId`: a late envelope of a
    /// finished call must not end the call that is live now. An envelope without an id, or with no active call to
    /// compare against, is let through, as the `call_hangup` handler does.
    public static func envelopeMayEndActiveCall(envelopeCallId: String?, activeCallId: String?) -> Bool {
        guard let id = nonEmpty(envelopeCallId?.lowercased()), let active = nonEmpty(activeCallId?.lowercased()) else { return true }
        return id == active
    }

    /// A `call_answer` arrived.
    ///
    /// - Parameters:
    ///   - envelopeCallId: the envelope's own call id, lowercased; nil or empty when the envelope has none.
    ///   - activeCallId: the id `AppState.canonicalActiveCallId()` reports, lowercased.
    ///   - carriedSdp: the answer carried a non-empty `sdp`.
    public mutating func answerArrived(
        envelopeCallId: String?,
        activeCallId: String?,
        carriedSdp: Bool,
        phase: Phase
    ) -> AnswerStep {
        let named: String? = Self.nonEmpty(envelopeCallId)
        guard let id = named ?? Self.nonEmpty(activeCallId) else { return .dropped(.noCallId) }
        switch phase {
        case .idle, .ended:
            return .dropped(.notInCall)
        case .connecting:
            // The OFFER round trip has not returned: the call id the app can name may still be a local one,
            // so it cannot be compared yet. Keep the answer for this call id (one slot, newest wins).
            held = HeldAnswer(callId: id, carriedSdp: carriedSdp)
            return .held
        case .ringing, .active, .encrypted:
            return admitAnswer(id: id, activeCallId: Self.nonEmpty(activeCallId), carriedSdp: carriedSdp, phase: phase)
        }
    }

    /// A `call_accepted` arrived. `envelopeCallId` is the envelope's call id, lowercased.
    public mutating func acceptedArrived(
        envelopeCallId: String,
        activeCallId: String?,
        phase: Phase
    ) -> AcceptedStep {
        let id: String = envelopeCallId
        let active: String? = Self.nonEmpty(activeCallId)
        guard !id.isEmpty else { return .dropped(.noCallId) }
        switch phase {
        case .idle, .ended:
            return .dropped(.notInCall)
        case .connecting:
            // Recorded unconditionally: the app cannot name the wire id yet. Cleared at call end.
            acceptedCallId = id
            return .latched
        case .ringing, .active, .encrypted:
            if let active, active != id { return .dropped(.otherCall) }
            acceptedCallId = id
            guard AcceptGateDecisions.shouldAcceptAnswer(
                isRinging: phase == .ringing,
                isPreRingActive: phase == .active,
                isEncrypted: phase == .encrypted,
                alreadyFinalized: finalizedCallId == id
            ) else { return .dropped(.finalized) }
            return localHandshakeReadyCallId == id ? .finalizeNow : .waitForAnswer
        }
    }

    /// The caller's phase changed. Re-applies a held answer when the call has become admissible and drops it
    /// when the call ended or is no longer the one it was received for.
    public mutating func phaseChanged(to phase: Phase, activeCallId: String?) -> Replay? {
        guard let pending = held else { return nil }
        switch phase {
        case .idle, .ended:
            held = nil
            return nil
        case .connecting:
            return nil
        case .ringing, .active, .encrypted:
            held = nil
            let active: String? = Self.nonEmpty(activeCallId)
            if let active, active != pending.callId {
                // Another call became current while the answer was held: never applied, and the drop is reported.
                return Replay(callId: pending.callId, carriedSdp: pending.carriedSdp, step: .dropped(.otherCall))
            }
            let step = admitAnswer(
                id: pending.callId, activeCallId: active, carriedSdp: pending.carriedSdp, phase: phase)
            return Replay(callId: pending.callId, carriedSdp: pending.carriedSdp, step: step)
        }
    }

    /// The accept-gate countdown fired for `callId`. True when `finalizeCallActive()` should run.
    public func netFired(callId: String, phase: Phase) -> Bool {
        guard Self.admits(phase) else { return false }
        return localHandshakeReadyCallId == callId && finalizedCallId != callId
    }

    /// `finalizeCallActive()` ran for `callId`.
    public mutating func markFinalized(callId: String?) {
        finalizedCallId = callId
    }

    /// The call ended: every flag, the held answer and the outgoing call id are cleared for the next call.
    public mutating func reset() {
        localHandshakeReadyCallId = nil
        acceptedCallId = nil
        finalizedCallId = nil
        held = nil
        outgoingCallId = nil
    }

    // MARK: - Internals

    private mutating func admitAnswer(
        id: String,
        activeCallId: String?,
        carriedSdp: Bool,
        phase: Phase
    ) -> AnswerStep {
        if let activeCallId, activeCallId != id { return .dropped(.otherCall) }
        guard AcceptGateDecisions.shouldAcceptAnswer(
            isRinging: phase == .ringing,
            isPreRingActive: phase == .active,
            isEncrypted: phase == .encrypted,
            alreadyFinalized: finalizedCallId == id
        ) else { return .dropped(.finalized) }
        let action = AcceptGateDecisions.resolve(
            peerAlreadyAccepted: acceptedCallId == id,
            answerCarriedSdp: carriedSdp
        )
        if action == .finalizeNow { return .finalizeNow }
        localHandshakeReadyCallId = id
        return .waitForAccept(netSeconds: AcceptGateDecisions.fallbackSeconds(for: action))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
