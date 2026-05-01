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
            p.prepareToPlay()
            guard p.play() else {
                print("[VoiceNotePlayer] play() returned false for \(url.lastPathComponent)")
                stop()
                return
            }
            self.player = p
            self.currentlyPlayingId = messageId
            self.isPaused = false
            self.progress = 0
            startTick()
        } catch {
            print("[VoiceNotePlayer] failed to load \(url.path): \(error)")
            stop()
        }
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

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
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
