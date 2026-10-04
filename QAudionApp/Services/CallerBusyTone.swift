import Foundation
import AudioToolbox
import QAudionEngine

/// W-CALLERBUSY (2026-10-03) — plays the busy tone when the callee is busy (`call_busy`).
///
/// A system sound, not the cue player (`QAudionRingtonePlayer`), on purpose and for the same reason the in-app
/// ringtone is one (`AppState.startInAppRingtone`): the tone starts the instant the caller reports the outgoing
/// call ended to CallKit, and that report is what makes iOS deactivate the audio session. The cue player's engine
/// lives on that session (the W464 gate), so it would be cut or fail to start; a system sound uses no audio
/// session, and so leaves nothing behind for the next call's CallKit activation to trip over.
///
/// The WAV is rendered by the engine (`QAudionCueWav.busyTone()`, 425 Hz, 0.5 s on / 0.5 s off, repeated to fill
/// the busy hold) and written once to the temporary directory, under a name that carries its length. Like every
/// system sound it follows the ringer switch.
///
/// W-BUSYHOLD (2026-10-04) — the tone is as long as the "Occupato" screen (`CallerBusyFeedback.holdMs`, 4000 ms),
/// and the sound id is disposed `CallerBusyFeedback.soundDisposeAfterMs` after it starts: after the tone's end,
/// never before it (#169 disposed at 3.5 s, which would have cut the last burst of a 4 s tone).
///
/// `stop()` is idempotent and is what `startCall` and the teardown call: disposing the id also stops a tone that
/// is still playing, so a redial never starts under a tail of the previous call's tone. A tone cut before its end
/// (the close button, a redial, an incoming ring) is logged, so a short tone in a trace has a name.
@MainActor
final class CallerBusyTone {

    private var soundId: SystemSoundID?
    private var disposeWork: DispatchWorkItem?
    /// `DispatchTime` uptime, in nanoseconds, of the moment the tone started.
    private var startedAtNs: UInt64 = 0

    /// Plays the tone from the start, replacing one that is still playing.
    func play() {
        stop()
        guard let id = register() else {
            RTLog.warn("call", "busytone reg=0")
            return
        }
        soundId = id
        startedAtNs = DispatchTime.now().uptimeNanoseconds
        AudioServicesPlaySystemSound(id)
        RTLog.info("call", "busytone play=1")
        // Dispose after the tone has ended (never before: see the type's doc).
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        disposeWork = work
        let disposeAfter: Double = Double(CallerBusyFeedback.soundDisposeAfterMs) / 1_000
        DispatchQueue.main.asyncAfter(deadline: .now() + disposeAfter, execute: work)
    }

    /// Stops the tone if it is playing and frees its sound id. Safe to call when nothing was started.
    func stop() {
        disposeWork?.cancel()
        disposeWork = nil
        guard let id = soundId else { return }
        let playedMs: Int = Int((DispatchTime.now().uptimeNanoseconds &- startedAtNs) / 1_000_000)
        if playedMs < CallerBusyFeedback.holdMs {
            let line: String = "busytone stop early=1 ms=\(playedMs)"
            RTLog.info("call", line)
        }
        AudioServicesDisposeSystemSoundID(id)
        soundId = nil
    }

    private func register() -> SystemSoundID? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(QAudionCueWav.busyToneFileName)
        // Written once per process (a purged temporary directory is rewritten the next time).
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try QAudionCueWav.busyTone().write(to: url, options: .atomic)
            } catch {
                RTLog.warn("call", "busytone write=0 err=\(error)")
                return nil
            }
        }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        return id
    }
}
