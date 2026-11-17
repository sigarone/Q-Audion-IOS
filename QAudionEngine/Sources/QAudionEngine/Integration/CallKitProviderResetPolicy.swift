import Foundation

/// W-CKPCRESET (2026-09-02) — pure decision for what `providerDidReset`
/// should do with an active 1:1 `RTCPeerConnection`.
///
/// Once `providerDidReset` fires, CallKit has invalidated every call it knows
/// about; the app's job is to clean up its ongoing calls and revert to a
/// clean state — terminate the audio session and dispose of active calls —
/// without calling back into the (already-reset) `CXProvider` for those
/// calls (a `reportCallEnded` for a call CallKit itself just discarded would
/// be such a post-reset `CXProvider` interaction).
///
/// AppState's `onProviderReset` handler stops the video pipeline/ABR loop,
/// deactivates the audio session, and asks this policy what to do with the
/// 1:1 `RTCPeerConnection` (mic, camera capture, ICE/DTLS sockets). For
/// `.closeAndNotifyPeer` it calls `sendHangupAndClose()` on the controller,
/// sets `webRtcController` to nil and wipes the pending ICE candidate queue.
///
/// Scoped to the 1:1 `QAudionWebRtcCallController` only. A group call's media
/// is a separately-owned media session (`GroupCallController`), not this
/// PeerConnection, so this policy never acts on it; `AppState` handles a
/// provider reset during a group call itself (the group controller leaves).
public enum CallKitProviderResetPolicy {

    // MARK: - Kill switch (compile-time)

    /// Compile-time switch for the policy. `true` lets `peerConnectionAction`
    /// return `.closeAndNotifyPeer` for an active 1:1 PeerConnection, using
    /// the same teardown as an ordinary hangup
    /// (`QAudionWebRtcCallController.sendHangupAndClose()`, the call
    /// `AppState.endCall()` makes). `false` makes it always return
    /// `.leaveUntouched`: the handler then does only the video/ABR/
    /// audio-session cleanup and the PeerConnection is left open.
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
