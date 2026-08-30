import Foundation
import AVFoundation
import SwiftUI

/// W81 — singleton voice-note playback service.
///
/// Wraps an ``AVAudioPlayer`` so the chat bubble can drive playback
/// without each row owning its own player. Only one note plays at a
/// time; starting a new playback stops the previous one. SwiftUI views
/// observe `@Published` state to render the play/pause icon and the
/// progress bar.
///
/// Lifecycle:
///   1. ``play(url:messageId:)`` activates the audio session, loads the
///      file, starts playback, ticks `progress` via a 100 ms `Timer`.
///   2. ``pause()`` pauses the player without releasing it; resuming
///      via ``play(url:messageId:)`` for the SAME id continues from the
///      pause point.
///   3. ``stop()`` releases everything and clears `currentlyPlayingId`.
///   4. ``audioPlayerDidFinishPlaying`` stops + clears so the bubble
///      flips back to the play icon when the file ends.
@MainActor
final class VoiceNotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {

    /// App-wide singleton — exposed via SwiftUI environment / direct
    /// access. The chat row injects it into the bubble content.
    static let shared = VoiceNotePlayer()

    /// Local message id of the currently-playing voice note. `nil` when
    /// nothing is playing (so all bubbles show the play icon).
    @Published private(set) var currentlyPlayingId: UUID?

    /// 0...1 playback progress for the active note. Resets to 0 between
    /// plays.
    @Published private(set) var progress: Double = 0

    /// Whether the player is paused (vs. playing). Lets the bubble
    /// distinguish "tap to resume" from "tap to play from start".
    @Published private(set) var isPaused: Bool = false
    /// W95: playback speed multiplier. Cycles 1.0 → 1.5 → 2.0 → 1.0
    /// via `cyclePlaybackRate()`. Persisted across plays so the user's
    /// preferred speed sticks for the whole session. AVAudioPlayer
    /// requires `enableRate = true` before prepareToPlay; we set it
    /// unconditionally now that this property exists.
    /// W144: persist across app launches via UserDefaults so the user
    /// doesn't have to re-tap 1.5× every time they reopen the app.
    @Published private(set) var playbackRate: Float = {
        let stored = UserDefaults.standard.float(forKey: "qa.voiceNote.playbackRate")
        // UserDefaults returns 0.0 for missing keys; coerce to default.
        return stored > 0 ? stored : 1.0
    }()

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?

    /// Start playback for `url`, stamping `currentlyPlayingId = messageId`.
    /// If the same id is currently paused, resume from the pause point;
    /// otherwise start from the beginning.
    func play(url: URL, messageId: UUID) {
        if currentlyPlayingId == messageId, let p = player, isPaused {
            // Resume.
            activateAudioSession()
            p.play()
            isPaused = false
            startTick()
            return
        }

        // Stop any other playback first.
        stop()

        // Load + play.
        activateAudioSession()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            // W95: enable rate so cyclePlaybackRate can adjust speed.
            // Must be set BEFORE prepareToPlay per AVAudioPlayer docs.
            p.enableRate = true
            p.rate = playbackRate
            p.prepareToPlay()
            guard p.play() else {
                // I8 FIX: the filename embeds the attachment's fileId (see
                // ChatVoiceNoteReceiver.fetch) — truncate like every other
                // identifier print in this codebase.
                print("[VoiceNotePlayer] play() returned false for \(url.lastPathComponent.prefix(8))…")
                stop()
                return
            }
            self.player = p
            self.currentlyPlayingId = messageId
            self.isPaused = false
            self.progress = 0
            startTick()
        } catch {
            // I8 FIX: same fileId-in-filename concern as above — print only
            // the truncated last path component, not the full sandbox path.
            print("[VoiceNotePlayer] failed to load \(url.lastPathComponent.prefix(8))…: \(error)")
            stop()
        }
    }

    /// W98: jump to a normalized position (0...1) in the currently-
    /// playing note. Used by the bubble's drag-to-scrub gesture on
    /// the waveform. No-op if no player is loaded for `messageId`.
    func seek(to normalizedPosition: Double, messageId: UUID) {
        guard let p = player, currentlyPlayingId == messageId else { return }
        let target = max(0.0, min(1.0, normalizedPosition)) * p.duration
        p.currentTime = target
        // Update the published progress immediately so the waveform
        // cursor jumps without waiting for the next 100ms tick.
        progress = max(0.0, min(1.0, p.duration > 0 ? p.currentTime / p.duration : 0))
    }

    /// W99: skip relative seconds within the active note. Negative
    /// values rewind. Clamps to [0, duration].
    func skip(seconds: Double, messageId: UUID) {
        guard let p = player, currentlyPlayingId == messageId else { return }
        let newTime = max(0.0, min(p.duration, p.currentTime + seconds))
        p.currentTime = newTime
        progress = p.duration > 0 ? newTime / p.duration : 0
    }

    /// W95: cycle through playback speeds 1× → 1.5× → 2× → 1×. If a
    /// note is currently playing, the rate is applied immediately
    /// (AVAudioPlayer adjusts in real time when enableRate=true).
    func cyclePlaybackRate() {
        let next: Float
        switch playbackRate {
        case 1.0: next = 1.5
        case 1.5: next = 2.0
        default:  next = 1.0
        }
        playbackRate = next
        player?.rate = next
        // W144: persist the choice. UserDefaults float lookups are
        // O(1) in-memory after first hit so this is cheap.
        UserDefaults.standard.set(next, forKey: "qa.voiceNote.playbackRate")
    }

    /// Pause the active playback without releasing the player. The
    /// bubble still shows "this is the active note"; tapping play
    /// resumes from where we paused.
    func pause() {
        guard let p = player, p.isPlaying else { return }
        p.pause()
        isPaused = true
        stopTick()
    }

    /// Hard-stop. Releases the AVAudioPlayer, deactivates the session,
    /// resets all observable state.
    func stop() {
        if let p = player {
            p.stop()
            p.delegate = nil
        }
        player = nil
        stopTick()
        currentlyPlayingId = nil
        isPaused = false
        progress = 0
        deactivateAudioSession()
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("[VoiceNotePlayer] decode error: \(error?.localizedDescription ?? "nil")")
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    // MARK: - Internals

    private func activateAudioSession() {
        // .playback so playback continues if the user locks the screen
        // mid-listen. `.duckOthers` lets the system music dim while
        // we play instead of stopping it.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }

    // W-SESSIONCATLEAK (2026-08-30) — restore the VoIP category on the way
    // out. Six places in this app set a category on the SHARED
    // AVAudioSession and, until now, not one of them put it back: this
    // player left `.playback` (no input at all, speaker output, long
    // buffer), voice-unlock and enrollment leave `.record` (no output).
    // Whatever ran last owned every later call. Measured consequence on the
    // live 1.0.1063 call: the in-call session reported `in=` EMPTY,
    // `out=Speaker`, `buf=0.02` — the `.playback` signature exactly — so
    // BOTH capture engines were silent (native `tx=0 ptx=0`, AVAudioEngine
    // `capfail=1`). Restoring here is the fix at the source; the call path
    // also re-asserts the category under RTCAudioSession's lock
    // (W-SESSIONLOCK), which is the belt to this pair of braces.
    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        restoreVoipCategory()
    }

    /// See W-SESSIONCATLEAK above.
    private func restoreVoipCategory() {
        let session = AVAudioSession.sharedInstance()
        #if os(iOS) && !targetEnvironment(simulator)
        let opts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .interruptSpokenAudioAndMixWithOthers]
        #else
        let opts: AVAudioSession.CategoryOptions = [.interruptSpokenAudioAndMixWithOthers]
        #endif
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
    }


    private func startTick() {
        stopTick()
        // 10 fps progress updates — good enough for a 1px progress bar
        // without flooding the runloop.
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshProgress()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func refreshProgress() {
        guard let p = player, p.duration > 0 else { return }
        progress = min(1.0, max(0.0, p.currentTime / p.duration))
    }
}
