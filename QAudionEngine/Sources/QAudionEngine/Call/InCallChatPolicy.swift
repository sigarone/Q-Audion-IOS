import Foundation

/// The pure rules of the chat opened over a 1:1 call (`InCallChatCover`, on the audio call screen and on the video call screen).
///
/// The chat itself is the ordinary chat with the peer; the call stays up underneath and nothing of it is touched. Two decisions are
/// not UI and live here so they can be pinned by tests:
///
///  - who the chat is with (``chatPeer(callContactId:)``): the button is offered only when the call has a peer, and opening it never
///    guesses another conversation;
///  - whether taking a photo with the camera from that chat is refused (``cameraCaptureBlocked(inCall:videoCall:)``): in a video call
///    the camera belongs to the call's capture session, and a second camera user (`UIImagePickerController`) would take it away.
///    The photo library and the document picker are not affected: they run out of process and do not touch the capture session.
///
/// Audio is the same story and is handled by the chat itself (`ChatDetailScreen.callAudioBlock`: no voice notes recorded or played, no
/// video played, while a call is up).
public enum InCallChatPolicy {

    /// The person the chat opened over a call is with: the call's contact when there is one, `nil` otherwise (no button, and opening
    /// does nothing). An empty id counts as none.
    public static func chatPeer(callContactId: String?) -> String? {
        guard let callContactId, !callContactId.isEmpty else { return nil }
        return callContactId
    }

    /// `true` when "take a photo" in the chat must refuse and say why. `inCall` is `AppState.isInCall` (a 1:1 call is up; group calls
    /// have their own panel and do not reach the chat cover) and `videoCall` is `AppState.isVideoCall` (the call carries video, so
    /// the app's capture session is the call's: camera on, paused, or receive-only, the camera is not free for a second user).
    /// In an audio call the camera is free and the photo is allowed.
    public static func cameraCaptureBlocked(inCall: Bool, videoCall: Bool) -> Bool {
        inCall && videoCall
    }
}
