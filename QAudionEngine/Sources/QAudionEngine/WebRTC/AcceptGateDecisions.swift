import Foundation

/// W-ACCEPTGATE-SDP (2026-08-14) — WIRE_SPEC §3.5, the caller's side of the
/// two-flag latch: what to do when a `call_answer` lands while we are ringing.
///
/// ## The two flags, and why the second one exists
///
/// The caller may only show "connected" once BOTH are true: our own local
/// handshake completed, AND the callee's real user tapped Answer (`call_accepted`).
/// The second flag is the whole point — without it the caller's UI advances on a
/// signalling artifact rather than on a human decision.
///
/// `armAcceptGateTimeout` is a bounded rollout-safety net for a peer that never
/// sends `call_accepted` at all: after 7 s it finalizes anyway.
///
/// ## The regression this helper closes
///
/// Until W-DCSTUCK (2026-08-13) an iOS↔iOS callee never built a WebRTC controller
/// — the SDP-bearing `call_incoming` was dropped by the duplicate guard — so the
/// ONLY `call_answer` it ever sent was the bare `sdp:""` one that
/// `consumeDeferredAnswerIfReady` emits when the user genuinely answers. Answer
/// and acceptance were the same event, the two flags landed together, and the
/// 7 s net never had anything to fire on.
///
/// Rescuing that offer changed the timing, not just the transport: the callee now
/// builds the controller AT RING TIME and `acceptIncomingCall` ships an
/// SDP-bearing `call_answer` immediately, before anyone has touched the screen.
/// That armed the net while the callee was still ringing, so ~7 s later the
/// CALLER flipped itself to connected against a phone that was still ringing —
/// Pavel, 2026-08-14: "uno sembra connesso, l'altro ancora in connessione".
///
/// The fix is to read the answer for what it is. A bare answer is a peer telling
/// us a human accepted; an SDP-bearing answer is a WebRTC handshake artifact and
/// says nothing about the human. Only the former may arm the countdown.
///
/// Safe across the fleet because all three clients implement §3.5 and do send
/// `call_accepted` (`BCryptoCallingApiImpl.sendCallAccepted` on iOS,
/// `WsCommand.TYPE_CALL_ACCEPTED` on Android, `CallController.ts` on Desktop), so
/// dropping the countdown for the SDP case does not strand the caller — the
/// accept still finalizes it through `handleCallAccepted`.
public enum AcceptGateDecisions {

    /// What the caller should do with this `call_answer`.
    public enum Action: Equatable {
        /// `call_accepted` already arrived for this call — both flags are in
        /// hand, finalize now.
        case finalizeNow
        /// Bare (`sdp:""`) answer: the peer's way of saying a human accepted.
        /// Stash the local flag AND arm the rollout-safety countdown, exactly as
        /// before this helper existed.
        case waitForAcceptWithFallback
        /// SDP-bearing answer: a handshake artifact that can legitimately arrive
        /// while the callee is still ringing. Stash the local flag, but do NOT
        /// start a countdown that would declare the call connected on its own.
        case waitForAcceptOnly
    }

    /// - Parameters:
    ///   - peerAlreadyAccepted: `call_accepted` for THIS call id already landed.
    ///   - answerCarriedSdp: the `call_answer` envelope had a non-empty `sdp`.
    public static func resolve(
        peerAlreadyAccepted: Bool,
        answerCarriedSdp: Bool
    ) -> Action {
        if peerAlreadyAccepted { return .finalizeNow }
        return answerCarriedSdp ? .waitForAcceptOnly : .waitForAcceptWithFallback
    }
}
