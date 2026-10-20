import AVFoundation
import Foundation
import WebRTC

/// Audio session handling for the ring and the ringtone preview, which play outside a call.
///
/// The caller says whether a call is in progress (from the app's call state, never from the session's current
/// category: a stale category says nothing about a call). In a call the session belongs to the call and is not
/// touched at all. Outside a call the category is set under `RTCAudioSession`'s configuration lock, like the other
/// session changes in the app, and `end()` puts the call category back (play-and-record, voice chat), the same
/// state the voice-note player restores, so the next call finds the session as it expects.
public final class RingAudioSession {

    private var changed = false

    public init() {}

    /// Prepares playback. `ignoreSilentSwitch` is for the preview, which the user starts on purpose.
    /// Does nothing in a call. Returns whether the category was changed.
    @discardableResult
    public func begin(inCall: Bool, ignoreSilentSwitch: Bool) -> Bool {
        guard !inCall else { return false }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do {
            try rtc.setCategory(ignoreSilentSwitch ? .playback : .ambient, mode: .default, options: [])
            changed = true
        } catch {
            changed = false
        }
        return changed
    }

    /// Releases the session if `begin` changed it. When a call has taken over meanwhile, it is left alone.
    public func end(inCall: Bool) {
        guard changed else { return }
        changed = false
        guard !inCall else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        #if os(iOS) && !targetEnvironment(simulator)
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .interruptSpokenAudioAndMixWithOthers]
        #else
        let options: AVAudioSession.CategoryOptions = [.interruptSpokenAudioAndMixWithOthers]
        #endif
        try? rtc.setCategory(.playAndRecord, mode: .voiceChat, options: options)
    }
}
