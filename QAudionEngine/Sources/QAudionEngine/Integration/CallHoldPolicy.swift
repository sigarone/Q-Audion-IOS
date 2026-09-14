import Foundation

/// W-CKHOLD (2026-09-02) — pure decision for `CallKitProvider`'s B5 fix:
/// whether local VIDEO should pause/resume when the SYSTEM places THIS
/// call on or off hold (`CXSetHeldCallAction` — another CallKit call
/// becoming active, or a Siri "hold my call" request; the SAME delegate
/// callback also fires for the app's own in-app Hold button, since
/// `CallKitManaging.setOnHold` requests the identical action via
/// `CXCallController`). Evidence: audit memory
/// `reference_ios_stability_audit_2026_09_01`, P2 — the action reached no
/// delegate method at all before this, so a hold silently timed out.
///
/// AUDIO is deliberately NOT decided here: `CallService.isOnHold` /
/// `setOnHold(_:)` is already the app's real, shipped hold mechanism (it
/// gates `processAndSendEncryptedFrame`'s TX chokepoint and the call
/// duration timer, and is exactly what `InCallContainer.tapHold()` already
/// drives for a self-initiated hold). `AppState` calls that SAME method
/// directly for every hold-state change regardless of source, so system
/// and self-initiated holds always converge on identical local audio
/// state — a second, parallel audio decision here would only risk
/// diverging from it.
///
/// `AppState` owns the actual `VideoCallPipeline`/`CallService` calls (and
/// the group-call fork that guards them, `groupCallKitId`); this type only
/// decides WHETHER to pause/resume video, so every branch is pinned by
/// `CallHoldPolicyTests` without a live call or capture session — same
/// split as `AudioInterruptionRecoveryPolicy` / `RestartIceDecisions`.
public enum CallHoldPolicy {

    /// What the caller should do to local video in response to one
    /// hold-state change. Mutually exclusive: `isOnHold` alone selects one
    /// side (or neither, for a group call — see `.none`).
    public struct VideoAction: Equatable {
        public let pauseLocalVideo: Bool
        public let resumeLocalVideo: Bool

        public init(pauseLocalVideo: Bool, resumeLocalVideo: Bool) {
            self.pauseLocalVideo = pauseLocalVideo
            self.resumeLocalVideo = resumeLocalVideo
        }

        /// Group calls: no local video change here. A group call's video
        /// belongs to the LiveKit SFU room, never to the legacy 1:1
        /// `VideoCallPipeline`. Routing a group hold through that pipeline
        /// is the exact class of bug that crashed both test devices before
        /// (W-GRPVPIO-CRASH); group calls get their own hold path later,
        /// not a blind flip here.
        public static let none = VideoAction(pauseLocalVideo: false, resumeLocalVideo: false)
    }

    /// - Parameters:
    ///   - isOnHold: `CXSetHeldCallAction.isOnHold`.
    ///   - isGroupCall: `groupCallKitId != nil`. Always yields `.none`
    ///     regardless of every other parameter — see `VideoAction.none`.
    ///   - isVideoCall: the call currently sends video at all. `false` for
    ///     an audio-only call, which never touches the video pipeline here.
    ///   - localVideoAlreadyPaused: the user's OWN camera-toggle state
    ///     going into this hold. Going on-hold must never claim credit for
    ///     pausing a camera the user had already turned off themselves, or
    ///     the matching resume would wrongly turn it back on for them.
    ///   - videoPausedByPriorHold: latched by the caller from a PRIOR call
    ///     to this function's `pauseLocalVideo` result (the matching
    ///     `isOnHold: true`) — the only case in which `isOnHold: false`
    ///     should un-pause video.
    public static func videoAction(
        isOnHold: Bool,
        isGroupCall: Bool,
        isVideoCall: Bool,
        localVideoAlreadyPaused: Bool,
        videoPausedByPriorHold: Bool
    ) -> VideoAction {
        guard !isGroupCall else { return .none }
        if isOnHold {
            let pause = isVideoCall && !localVideoAlreadyPaused
            return VideoAction(pauseLocalVideo: pause, resumeLocalVideo: false)
        }
        return VideoAction(pauseLocalVideo: false, resumeLocalVideo: videoPausedByPriorHold)
    }
}
