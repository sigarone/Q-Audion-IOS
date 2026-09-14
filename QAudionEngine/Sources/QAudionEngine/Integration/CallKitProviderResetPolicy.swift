import Foundation

/// W-CKPCRESET (2026-09-02) — pure decision for what `providerDidReset`
/// should do with an active 1:1 `RTCPeerConnection`.
///
/// Evidence: audit memory `reference_ios_stability_audit_2026_09_01`, P2 —
/// "`providerDidReset` does not close PC". Apple's own doc
/// (`CXProviderDelegate.providerDidReset(_:)`) says only "the provider is
/// reset"; the operative guidance is the documented contract every public
/// CallKit integration guide converges on independently: once
/// `providerDidReset` fires, CallKit has invalidated every call it knows
/// about and the app's job is to "clean up any ongoing calls and revert to
/// a clean state" — terminate the ongoing audio session and dispose of any
/// active calls, with NO further calls back into the (already-reset)
/// `CXProvider` for those calls (an app-level `reportCallEnded` for a call
/// CallKit itself just discarded is exactly the kind of post-reset
/// `CXProvider` interaction the public guidance and Apple's own developer
/// forum ("Frequent providerDidReset Callback") flag as the wrong thing to
/// do — the provider that owned that call is gone). AppState's existing
/// `onProviderReset` handler already stops the video pipeline/ABR loop and
/// deactivates the audio session; it never touched `webRtcController`, so
/// the 1:1 `RTCPeerConnection` (mic, camera capture, ICE/DTLS sockets) was
/// left running with nothing left to close it — a silent resource leak
/// until the process happened to exit.
///
/// Deliberately scoped to the 1:1 `QAudionWebRtcCallController` only. A
/// group call's media is a separately-owned LiveKit room
/// (`LiveKitGroupCallRoom`/`GroupCallController`), not this PeerConnection —
/// folding that in here would touch the adaptiveStream/dynacast-adjacent
/// group call stack the audit already flags as unsafe to change without a
/// live-verified reason (see `reference_ios_stability_audit_2026_09_01`).
/// That gap (does a system-level provider reset also need to disconnect an
/// active LiveKit room?) is untouched by this fix and reported separately.
public enum CallKitProviderResetPolicy {

    // MARK: - Kill switch (compile-time)

    /// This is a pure resource-leak fix reusing an already-shipped,
    /// already-tested teardown primitive (`QAudionWebRtcCallController
    /// .sendHangupAndClose()` — the exact call `AppState.endCall()` makes to
    /// close the same PeerConnection on every ordinary hangup) behind a
    /// system callback that fires only on a genuine CallKit-level reset
    /// (rare; Apple's own forum reports it as an edge case, not a hot path).
    /// No adaptiveStream/dynacast-class live-unverified technique is
    /// involved, so default = the new behaviour. `false` restores today's
    /// exact behaviour (video/ABR/audio-session cleanup only, PC left open).
    public static let closesActivePeerConnectionEnabled: Bool = true

    // MARK: - Pure decision

    public enum PeerConnectionAction: Equatable {
        /// Close the PeerConnection and let the peer know (mirrors a normal
        /// hangup: `sendHangupAndClose()`).
        case closeAndNotifyPeer
        /// Nothing to do — no active 1:1 PeerConnection, the call in
        /// question is a group call (a different owner), or the kill switch
        /// is off.
        case leaveUntouched
    }

    /// - Parameters:
    ///   - hasActivePeerConnection: whether the app currently holds a
    ///     live 1:1 `QAudionWebRtcCallController` (`AppState.webRtcController
    ///     != nil`).
    ///   - isGroupCall: whether the call CallKit was tracking is a group
    ///     call (`AppState.groupCallKitId != nil`) — out of scope, see kdoc.
    ///   - enabled: the kill switch; defaults to
    ///     `closesActivePeerConnectionEnabled`.
    public static func peerConnectionAction(
        hasActivePeerConnection: Bool,
        isGroupCall: Bool,
        enabled: Bool = closesActivePeerConnectionEnabled
    ) -> PeerConnectionAction {
        guard enabled, hasActivePeerConnection, !isGroupCall else { return .leaveUntouched }
        return .closeAndNotifyPeer
    }
}
