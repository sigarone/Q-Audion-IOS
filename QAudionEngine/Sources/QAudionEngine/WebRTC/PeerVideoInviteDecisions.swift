import Foundation

/// W-VIDPARITY — pure decision helpers for the "peer is sending video, we
/// answered audio-only" invite banner and its two wire-level consequences
/// (asking the peer to pause, and honoring the peer's own pause ask).
/// These are the platform-independent CHOICES the feature makes; they
/// contain NO WebRTC / AppState state so they can be unit-tested directly.
///
/// Cross-platform sister: Android `InCallScreen.kt` (banner visibility
/// condition — `videoState == RemoteOnly && !dismissed &&
/// incomingUpgrade == null`) and `CallController.kt` (the
/// `call_video_pause_request` listener that auto-complies with no
/// dialog). iOS previously had NO equivalent of either: a peer calling in
/// video that we answered audio-only left our own "turn my camera on"
/// path broken (see `localCameraEnableRoute` below), and there was no way
/// to ask the peer to stop sending video, or to honor such a request from
/// them.
public enum PeerVideoInviteDecisions {

    // MARK: - Banner visibility (Android InCallScreen.kt condition)

    /// Whether to show the "Richiesta video" banner: the call has video,
    /// the peer IS sending it, WE are not, the peer isn't merely sharing
    /// their screen (that has its own badge, not this banner), the user
    /// hasn't already dismissed it for this call, and there's no OTHER
    /// incoming-upgrade consent prompt already on screen (never stack two
    /// video prompts at once — the existing `pendingIncomingUpgrade`
    /// dialog takes priority).
    public static func shouldShowPeerVideoInviteBanner(
        isVideoCall: Bool,
        peerCameraSending: Bool,
        localCameraSending: Bool,
        peerScreenShareActive: Bool,
        dismissedThisCall: Bool,
        pendingIncomingUpgrade: Bool
    ) -> Bool {
        isVideoCall
            && peerCameraSending
            && !localCameraSending
            && !peerScreenShareActive
            && !dismissedThisCall
            && !pendingIncomingUpgrade
    }

    // MARK: - Local camera enable routing (BUG (C) fix)

    /// Which mechanism turning the local camera ON must use, given the
    /// call's current shape. Three cases:
    ///  - the call has NO video at all yet → a real mid-call upgrade (SDP
    ///    renegotiation) is required: `upgradeFromAudio`.
    ///  - the call already HAS video, but the local pipeline's source is
    ///    `.external` (an inert placeholder — the answer already
    ///    negotiated m=video with no real capture behind it, W-VIDPRIVACY
    ///    `.receiveOnly`) OR there is no pipeline at all yet → no SDP
    ///    renegotiation is needed or possible; promote the existing
    ///    placeholder to a real camera pipeline: `promoteReceiveOnly`. A
    ///    nil pipeline on an already-video call is treated the same as
    ///    `.external` — there is nothing to "resume", so promoting (which
    ///    starts a fresh pipeline from scratch) is the only route that
    ///    does not silently no-op.
    ///  - the call has video AND the pipeline already owns a real camera
    ///    → this is a plain pause/resume: `resumeCapture`.
    public enum LocalCameraEnableRoute: Equatable {
        /// `videoSetCameraEnabled(true)` — pipeline already captures from
        /// a real camera, just unpause it.
        case resumeCapture
        /// `promoteReceiveOnlyToCamera()` — replace the `.external`/nil
        /// placeholder pipeline with a real `.camera` one, no SDP touch.
        case promoteReceiveOnly
        /// `upgradeToVideo()` — the call has no video yet; a real SDP
        /// renegotiation is required.
        case upgradeFromAudio
    }

    public static func localCameraEnableRoute(
        isVideoCall: Bool,
        pipelineIsExternalSource: Bool
    ) -> LocalCameraEnableRoute {
        guard isVideoCall else { return .upgradeFromAudio }
        return pipelineIsExternalSource ? .promoteReceiveOnly : .resumeCapture
    }

    // MARK: - call_video_pause_request receive filter (Android CallController.kt)

    /// Whether an incoming `call_video_pause_request` should be honored:
    /// it must name the call we actually believe is active, and we must
    /// actually have one (an empty/nil active id never matches anything —
    /// mirrors the `activeCallIdOrNil()`/`getActiveCallId()` "never
    /// fabricate" contract the rest of the call-signalling layer already
    /// follows). Case-insensitive, matching every other call-id compare
    /// in the wire-handling layer (an iOS-minted id and an Android-echoed
    /// one can differ only in case — see the `call_video_state` /
    /// `call_media_ready` handlers' own `caseInsensitiveCompare` use).
    public static func shouldHonorVideoPauseRequest(
        activeCallId: String?,
        requestCallId: String
    ) -> Bool {
        guard let activeCallId, !activeCallId.isEmpty, !requestCallId.isEmpty else { return false }
        return activeCallId.caseInsensitiveCompare(requestCallId) == .orderedSame
    }
}
