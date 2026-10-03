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
/// The WAV is rendered by the engine (`QAudionCueWav.busyTone()`, the same 425 Hz / 0.5 s on / 0.5 s off x 3 as
/// Android's `Cue.Busy`) and written once to the temporary directory. Like every system sound it follows the
/// ringer switch.
///
/// `stop()` is idempotent and is what `startCall` and the teardown call: disposing the id also stops a tone that
/// is still playing, so a redial never starts under a tail of the previous call's tone.
@MainActor
final class CallerBusyTone {

    private var soundId: SystemSoundID?
    private var disposeWork: DispatchWorkItem?

    /// Plays the tone from the start, replacing one that is still playing.
    func play() {
        stop()
        guard let id = register() else {
            RTLog.warn("call", "busytone reg=0")
            return
        }
        soundId = id
        AudioServicesPlaySystemSound(id)
        RTLog.info("call", "busytone play=1")
        // The tone is 3 s long: dispose a little after, so the id does not outlive it.
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        disposeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    /// Stops the tone if it is playing and frees its sound id. Safe to call when nothing was started.
    func stop() {
        disposeWork?.cancel()
        disposeWork = nil
        guard let id = soundId else { return }
        AudioServicesDisposeSystemSoundID(id)
        soundId = nil
    }

    private func register() -> SystemSoundID? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qaudion_busy_tone.wav")
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
