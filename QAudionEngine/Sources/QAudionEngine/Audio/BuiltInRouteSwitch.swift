import AVFoundation
import Foundation
import WebRTC

/// IN-CALL NARROWBAND BLUETOOTH NOTICE (2026-10-22) -- "use the phone": move the call audio from a Bluetooth hands-free
/// headset to the built-in microphone and receiver, the same effect as choosing the iPhone in the system route picker.
///
/// Two session calls and nothing else: the preferred input becomes the built-in microphone, and any output override is
/// cleared (`.none`). Nothing about the category, its options, the mode or the speaker preference is touched here: with
/// the Bluetooth route gone the session falls back to its own default output (the receiver, or the loudspeaker where
/// `.defaultToSpeaker` is already set). Which of the two the call should end on is the caller's decision (the app turns
/// the speaker button of a 1:1 call off before this, and puts the loudspeaker of a group call back after it). The user
/// can go back to Bluetooth from the system route picker, which sets its own preferred route.
///
/// On a call whose audio runs in WebRTC's manual audio mode (native SRTP, group calls v2: `NativeAudioSessionGate.isArmed`)
/// the two calls run under `RTCAudioSession`'s configuration lock, like every other session mutation of such a call
/// (`NativeAudioSessionGate.applySpeakerRoute`); on any other call they go straight to `AVAudioSession`.
public enum BuiltInRouteSwitch {

    /// Returns true when both session calls succeeded. A missing built-in microphone (never the case on an iPhone or an
    /// iPad) counts as a failure.
    @discardableResult
    public static func useBuiltInMicAndReceiver() -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard NativeAudioSessionGate.isArmed else {
            return apply(to: session)
        }
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        let ok: Bool = apply(to: session)
        rtcSession.unlockForConfiguration()
        return ok
    }

    private static func apply(to session: AVAudioSession) -> Bool {
        var ok = true
        if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            do {
                try session.setPreferredInput(builtInMic)
            } catch {
                ok = false
            }
        } else {
            ok = false
        }
        do {
            try session.overrideOutputAudioPort(.none)
        } catch {
            ok = false
        }
        return ok
    }
}
