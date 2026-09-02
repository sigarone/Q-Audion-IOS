import Foundation

/// W-SIGSWALLOW (2026-09-01) — pure decisions for what happens when a
/// call-signaling ACTION fails: a setup envelope whose fast path finds no
/// authenticated socket, or a CallKit answer transaction the system refuses.
///
/// Background (audit memory reference_ios_stability_audit_2026_09_01, P1
/// item 7): every call-signaling send in the app was fire-and-forget behind
/// `try?` — `call_accepted`, `call_processing`/`call_ready`, `call_hangup`,
/// ICE candidates, the CallKit answer, the PQC ACCEPT. A failure left no
/// log line at all, which is exactly why the calls we could not explain
/// from the logs could not be explained: the evidence was swallowed at the
/// send site. This file holds the two behaviors that CHANGE at runtime as
/// a consequence (both compile-time kill switches, default = new behavior,
/// same style as `CallCapabilities.longAudioSendEnabled` /
/// `RestartIceDecisions`), plus the pure "may this envelope arm a
/// retransmit" decision so the reasoning is pinned by a test instead of
/// living only in a comment.
///
/// Contains NO socket / CallKit / PeerConnection state so every branch is
/// unit-testable — same discipline as `RestartIceDecisions`,
/// `IceTerminationPolicy`, `GlareDecisions`.
public enum CallSignalingFailurePolicy {

    // MARK: - Kill switches (compile-time, a revert is a flip)

    /// When `call_accepted`'s fast path (`ws.ensureAuthenticated(5s)`) fails,
    /// still do a best-effort send AND arm the EXISTING bounded setup
    /// retransmit ladder (`BCryptoCallingApiImpl.scheduleSetupRetransmit`,
    /// W-SETUPRETRY: 2.5 s / 5 s, stops on unbind or progression) before
    /// throwing. Before this flag the method threw BEFORE sending anything,
    /// so an accept pressed while the socket was reconnecting was lost for
    /// good — the ladder that already protects the SUCCESS path never got
    /// armed on the one path that needed it most. `false` restores the old
    /// throw-and-lose behavior byte-for-byte.
    public static let acceptedRetransmitWhenSocketNotReady: Bool = true

    /// When `CXAnswerCallAction` fails on a 1:1 call (CallKit has no record
    /// of the uuid, transaction refused, ...), run the direct in-app accept
    /// path instead of doing nothing. Mirrors the W-GRPDOUBLEDIALER fallback
    /// the group path has had since 2026-07-27 (live-confirmed "Accetta does
    /// nothing" regression there); the 1:1 path had the identical `try?`
    /// swallow and no fallback. `false` restores the old behavior ("Accept"
    /// silently no-ops on a CallKit refusal).
    public static let directAcceptOnCallKitAnswerFailure: Bool = true

    // MARK: - Socket-not-ready action per setup envelope

    /// The three responder-side JSON setup envelopes whose impl methods gate
    /// on `ws.ensureAuthenticated(timeoutSec: 5)` and throw
    /// `BCryptoCallingError.wsUnavailable` when the gate fails.
    public enum SetupEnvelope: Equatable {
        case callAccepted
        case callProcessing
        case callReady
    }

    public enum SocketNotReadyAction: Equatable {
        /// Send once anyway (`ws.send` kicks its own reconnect for control
        /// envelopes) and arm the existing bounded retransmit ladder, then
        /// throw so the caller can log the fast-path miss.
        case bestEffortSendAndArmRetransmit
        /// Throw without sending — today's behavior, kept where a resend is
        /// either unsafe for the peer or not worth a retransmit.
        case dropAndThrow
    }

    /// Which envelopes may arm the retransmit ladder when the socket is not
    /// ready. Deliberately NOT symmetric across the three:
    ///
    /// - `call_accepted`: the caller's RX is idempotent by contract (the
    ///   two-flag latch that gates the SAS/active display) and the ladder is
    ///   the SAME one the success path already arms — so arming it on the
    ///   failure path can only recover an accept, never duplicate a state
    ///   transition. Gated by `acceptedRetransmitWhenSocketNotReady`.
    /// - `call_ready`: the caller's RX handler (`ws.onCallReady` in AppState)
    ///   sets `callState = .ringing` UNCONDITIONALLY. A resend landing after
    ///   the caller already received `call_answer` would knock an active
    ///   call back to "ringing" on its screen. Never retransmit.
    /// - `call_processing`: informational ack (advances the caller's
    ///   integration `.capabilitySent → .connecting`); losing it is not
    ///   fatal because the ACCEPT bundle drives the same machine to
    ///   `.active` on its own (W540-A). A resend buys nothing worth the
    ///   extra frame. Never retransmit.
    public static func socketNotReadyAction(
        for envelope: SetupEnvelope,
        acceptedRetransmitEnabled: Bool = acceptedRetransmitWhenSocketNotReady
    ) -> SocketNotReadyAction {
        switch envelope {
        case .callAccepted:
            return acceptedRetransmitEnabled ? .bestEffortSendAndArmRetransmit : .dropAndThrow
        case .callProcessing, .callReady:
            return .dropAndThrow
        }
    }
}
