import Foundation

/// W-CRYPTORQUEUE (2026-09-27, watchdog 0x8BADF00D deadlock fix) — the pure
/// decision behind `QAudionWebRtcCallController.attachVideoSenderCryptorOnQueue`'s
/// guards, pulled out so it is unit-testable without the WebRTC binary
/// target (no local toolchain to build against it — see that method's own
/// doc and this task's report).
///
/// An audio-only call never adds a local video track (`addLocalVideoTrack`
/// only ever runs for a video call or a mid-call upgrade), so
/// `QAudionPeerConnection.videoSender` stays `nil` for that call's whole
/// life. Before this task, the video sender-cryptor retry loop had no way
/// to tell that apart from "the sender has not been created yet, keep
/// retrying" and burned all 5 retries — 1.5 s of scheduled work and one
/// misleading "attach failed, retrying" log line per attempt — on every
/// single audio-only call, forever, for no reason: `attachVideoSenderCryptor()`
/// itself always fails fast with no sender, so nothing was ever actually
/// racing or transient there.
///
/// `.skipNoSender` is not "give up" — `ensureVideoSealerInternal`'s rekey
/// branch re-invokes the attach itself, unretried, the moment
/// `addLocalVideoTrack()` actually creates a sender mid-call (see
/// `QAudionWebRtcCallController.upgradeToVideo`'s own "SENDER-CRYPTOR
/// MID-CALL-UPGRADE FIX" doc).
public enum VideoSenderCryptorAttachDecision: Equatable {
    /// The sender cryptor is already attached — nothing to do.
    case alreadyAttached
    /// No local video sender exists for this call (audio-only, or a video
    /// sender not created yet) — do not attempt or retry the attach.
    case skipNoSender
    /// A local video sender exists and the cryptor is not attached yet —
    /// attempt `attachVideoSenderCryptor()`.
    case attempt

    public static func evaluate(senderIsAttached: Bool, hasLocalVideoSender: Bool) -> Self {
        if senderIsAttached { return .alreadyAttached }
        guard hasLocalVideoSender else { return .skipNoSender }
        return .attempt
    }
}
