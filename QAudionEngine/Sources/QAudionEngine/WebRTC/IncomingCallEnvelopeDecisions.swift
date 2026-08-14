import Foundation

/// W-DCSTUCK (2026-08-13) — pure decision helper for the `call_incoming`
/// duplicate guard.
///
/// ## Why this exists
///
/// An iOS→iOS call ships **two** `call_offer` envelopes carrying the SAME
/// `call_id`, in this fixed order:
///
/// 1. `CallService.beginAndroidOutgoing` — the vestigial PQC offer, `sdp: ""`.
///    Its only job is to create the server call session and ring the callee.
/// 2. `QAudionWebRtcCallController.startOutgoingCall` — the REAL WebRTC offer,
///    with the SDP that carries the `m=application` sealed-audio DataChannel
///    section.
///
/// The server relays both verbatim as `call_incoming` (`TrackCallWithDevice`
/// returning false on the second one only skips metrics/logging — the relay
/// itself still happens, see `cmd/bcrypto-lite/main.go` `case "call_offer"`).
///
/// The callee's W450 duplicate guard then dropped envelope 2 wholesale, because
/// by that point envelope 1 had already provisioned CallKit + the responder
/// integration. The SDP went in the bin, `handleIncomingWebRtcOffer` never ran,
/// no `webRtcController` was ever built on the callee, so `consumeDeferredAnswerIfReady`
/// answered with `sdp: ""` — and the caller's PeerConnection sat in
/// HAVE_LOCAL_OFFER for the whole call. ICE never left `.new`, the sealed-audio
/// DataChannel never left `.connecting`, and 100% of the voice fell back to the
/// WS relay through the VPS.
///
/// Live signature this produced, on every iOS↔iOS call for weeks
/// (`0375af1e`, `e14eed99`, `7622b045`, …):
/// ```
/// dcmux txfall why=conn st=0 <callId> n=<frames>
/// dcmux tx dc=0 ws=<N> rx dc=0 ws=<M> <callId> n=<N>
/// ```
/// `dc=0` forever, `st=0` = `RTCDataChannelState.connecting` forever.
///
/// The guard's own documented intent was only ever "don't double-report to
/// CallKit" — never "discard signalling payload". This helper separates those
/// two things.
public enum IncomingCallEnvelopeDecisions {

    /// What the `call_incoming` handler should do with the envelope in hand.
    public enum DuplicateAction: Equatable {
        /// Not a duplicate — run the full provisioning path (CallKit report,
        /// responder integration, ring, WebRTC offer if the SDP is present).
        case provisionNormally
        /// A genuine duplicate carrying nothing new — drop it silently, as
        /// before. Re-reporting to CallKit here is what W450 exists to prevent.
        case dropDuplicate
        /// The call is already provisioned, but THIS envelope carries a WebRTC
        /// SDP offer that has not been consumed yet. Feed the SDP to
        /// `handleIncomingWebRtcOffer` and then stop — no second CallKit
        /// report, no second responder integration, no state change.
        case rescueWebRtcOffer
    }

    /// - Parameters:
    ///   - sameCallProvisioned: this `call_id` is the one already provisioned
    ///     here (CallKit id matches AND the responder integration exists AND
    ///     `callState != .idle`).
    ///   - differentCallActive: a DIFFERENT call already owns the device.
    ///   - sdpLength: `data["sdp"]`'s length; `0` for the vestigial PQC offer.
    ///   - hasWebRtcController: a `QAudionWebRtcCallController` already exists
    ///     for this call — the SDP was already consumed, so a further copy is
    ///     a true duplicate.
    public static func resolveDuplicateCallIncoming(
        sameCallProvisioned: Bool,
        differentCallActive: Bool,
        sdpLength: Int,
        hasWebRtcController: Bool
    ) -> DuplicateAction {
        // A different call owning the device wins over everything: adopting a
        // foreign SDP mid-call would point the live PeerConnection at the wrong
        // peer. Unchanged from the original guard.
        if differentCallActive { return .dropDuplicate }
        if !sameCallProvisioned { return .provisionNormally }
        if sdpLength > 0 && !hasWebRtcController { return .rescueWebRtcOffer }
        return .dropDuplicate
    }
}
