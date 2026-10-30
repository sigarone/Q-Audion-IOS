import AVFoundation
import Foundation
import QAudionEngine

/// Plays the sound of a message the app announces itself (its own banner while the app is open) at the volume the
/// user chose in Settings, through an ambient audio session: it still follows the ringer switch and mixes with
/// other audio. Nothing is played through a session while a call or a ring is active: the system sound service is
/// used then, which needs no session (and ignores the volume).
@MainActor
final class MessageSoundPlayback {

    static let shared = MessageSoundPlayback()

    /// True while a call is live or ringing; supplied by `AppState`.
    var callOrRingActive: () -> Bool = { false }

    private var player: AVAudioPlayer?
    private var releaseWork: DispatchWorkItem?
    private let session = RingAudioSession()

    /// What to do for one in-app message sound. Pure, so it is tested without an audio device.
    enum Plan: Equatable {
        case none
        case player(MessageSoundPreviewPolicy.Source, volume: Float)
        case systemSound
    }

    nonisolated static func plan(for sound: MessageSound, volume: Float, busy: Bool) -> Plan {
        if case .silent = sound { return .none }
        if volume <= 0 { return .none }
        if busy { return .systemSound }
        switch MessageSoundPreviewPolicy.plan(for: sound, inCall: false) {
        case .player(let source): return .player(source, volume: volume)
        case .none: return .none
        case .callSafe: return .systemSound
        }
    }

    nonisolated static func url(for source: MessageSoundPreviewPolicy.Source) -> URL? {
        switch source {
        case .bundled(let fileName):
            let name = (fileName as NSString).deletingPathExtension
            return Bundle.main.url(forResource: name, withExtension: (fileName as NSString).pathExtension)
        case .systemTone:
            let path = MessageSoundPreviewPolicy.systemToneFile
            return FileManager.default.isReadableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
    }

    /// What one call to `play` did, for the diagnostics only.
    struct Outcome: Equatable {
        /// `none`, `player` or `systemSound`.
        let plan: String
        let busy: Bool
        /// Result of `AVAudioPlayer.play()`: 1 played, 0 refused or failed to start, -1 no player used.
        let playOk: Int
        /// True when the system sound service played instead of the player.
        let fallback: Bool
    }

    @discardableResult
    func play(_ sound: MessageSound, settings: MessageSoundSettings) -> Outcome {
        let volume = MessageSoundPreviewPolicy.playerVolume(for: settings)
        let busy = !AppAudioSession.isIdleNow(callInFlight: callOrRingActive())
        switch Self.plan(for: sound, volume: volume, busy: busy) {
        case .none:
            return Outcome(plan: "none", busy: busy, playOk: -1, fallback: false)
        case .systemSound:
            MessageSoundPlayer.shared.play(sound)
            return Outcome(plan: "systemSound", busy: busy, playOk: -1, fallback: false)
        case .player(let source, let volume):
            guard let url = Self.url(for: source) else {
                MessageSoundPlayer.shared.play(sound)
                return Outcome(plan: "player", busy: busy, playOk: -1, fallback: true)
            }
            let ok = start(url: url, volume: volume, fallback: sound)
            return Outcome(plan: "player", busy: busy, playOk: ok ? 1 : 0, fallback: !ok)
        }
    }

    func stopForCall() { release(callStarting: true) }

    /// True when the player is playing; false when the system sound service played instead.
    private func start(url: URL, volume: Float, fallback: MessageSound) -> Bool {
        release(callStarting: false)
        session.begin(inCall: false, ignoreSilentSwitch: false)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = volume
            guard p.play() else {
                session.end(inCall: callOrRingActive())
                MessageSoundPlayer.shared.play(fallback)
                return false
            }
            player = p
            SoundPreviewCoordinator.register(self) { [weak self] in self?.stopForCall() }
            let work = DispatchWorkItem { [weak self] in self?.release(callStarting: false) }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + min(6, p.duration + 0.15), execute: work)
            return true
        } catch {
            session.end(inCall: callOrRingActive())
            MessageSoundPlayer.shared.play(fallback)
            return false
        }
    }

    private func release(callStarting: Bool) {
        releaseWork?.cancel()
        releaseWork = nil
        guard player != nil else { return }
        player?.stop()
        player = nil
        SoundPreviewCoordinator.unregister(self)
        if callStarting {
            session.endAfterCall(isCallActive: callOrRingActive)
        } else {
            // `end` leaves the session alone if a call, a ring or a voice note has taken it meanwhile.
            session.end(inCall: callOrRingActive())
        }
    }
}

/// Whether the app's audio session is free to be taken for a short sound. The voice features of the app leave it in
/// their own category while they work (a voice note plays with `.playback` and records with `.playAndRecord`, the
/// voice unlock records with `.record`). Play-and-record with voice chat is the call category: the app also keeps it
/// outside calls, so it only counts as idle when no call or ring is in flight and no call audio is running.
enum AppAudioSession {

    /// The one "a call or a ring is in flight" rule: a live call, an in-app or CallKit ring, a group call, even
    /// while `callState` is still idle.
    nonisolated static func callOrRingInFlight(callOrRingActive: Bool, noCallInFlight: Bool) -> Bool {
        callOrRingActive || !noCallInFlight
    }

    nonisolated static func isIdle(category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                                   callInFlight: Bool, callAudioActive: Bool) -> Bool {
        if callInFlight || callAudioActive { return false }
        switch category {
        case .ambient, .soloAmbient: return true
        case .playAndRecord: return mode == .voiceChat
        default: return false
        }
    }

    static func isIdleNow(callInFlight: Bool) -> Bool {
        let s = AVAudioSession.sharedInstance()
        return isIdle(category: s.category, mode: s.mode, callInFlight: callInFlight,
                      callAudioActive: RingAudioSession.isCallAudioActive)
    }
}
