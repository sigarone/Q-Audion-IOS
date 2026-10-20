import Foundation
import AudioToolbox
import QAudionEngine

/// W-CALLERBUSY (2026-10-03) — plays the busy tone when the callee is busy (`call_busy`).
///
/// A system sound unless the app owns an active audio session (`sessionPlayback`, set by `AppState`), on purpose:
/// the tone starts the instant the caller reports the outgoing call ended to CallKit, and that report is what makes
/// iOS deactivate the audio session. The cue player lives on that session (the W464 gate), so it would be cut or
/// fail to start; a system sound uses no audio session, and so leaves nothing behind for the next call's CallKit
/// activation to trip over. When a session does exist the tone goes through the cue player, which has a gain.
///
/// The tone is the bundled `qa_cue_busy.caf` (425 Hz, 0.5 s on / 0.5 s off, three bursts). Like every system sound
/// it follows the ringer switch. The "end-of-call and busy sounds" setting can switch it off.
///
/// W-BUSYHOLD (2026-10-04) — the "Occupato" screen holds for `CallerBusyFeedback.holdMs` (4000 ms) and the tone
/// (3 s) plays inside it; the sound id is disposed `CallerBusyFeedback.soundDisposeAfterMs` after it starts: after
/// the tone's end, never before it.
///
/// `stop()` is idempotent and is what `startCall` and the teardown call: disposing the id also stops a tone that
/// is still playing, so a redial never starts under a tail of the previous call's tone. A tone cut before its end
/// (the close button, a redial, an incoming ring) is logged, so a short tone in a trace has a name.
@MainActor
final class CallerBusyTone {

    private var soundId: SystemSoundID?
    /// Plays the tone through the cue player when the app owns an active audio session; returns whether it did.
    var sessionPlayback: (() -> Bool)?
    /// Stops the tone started through `sessionPlayback`.
    var sessionStop: (() -> Void)?
    private var playingViaSession = false
    private var disposeWork: DispatchWorkItem?
    /// `DispatchTime` uptime, in nanoseconds, of the moment the tone started.
    private var startedAtNs: UInt64 = 0

    /// Plays the tone from the start, replacing one that is still playing.
    func play() {
        stop()
        guard CallCueGate.shouldPlay(.busy, settings: SettingsStore().loadCallSounds()) else {
            RTLog.info("call", "busytone skip=1 disabled=1")
            return
        }
        if sessionPlayback?() == true {
            playingViaSession = true
            RTLog.info("call", "busytone play=1 via=player")
            return
        }
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
        if playingViaSession {
            playingViaSession = false
            sessionStop?()
        }
        disposeWork?.cancel()
        disposeWork = nil
        guard let id = soundId else { return }
        let playedMs: Int = Int((DispatchTime.now().uptimeNanoseconds &- startedAtNs) / 1_000_000)
        if playedMs < CallSoundCatalog.busyCueMs {
            let line: String = "busytone stop early=1 ms=\(playedMs)"
            RTLog.info("call", line)
        }
        AudioServicesDisposeSystemSoundID(id)
        soundId = nil
    }

    private func register() -> SystemSoundID? {
        guard let url = Bundle.main.url(forResource: CallCueKind.busy.resourceName, withExtension: "caf") else {
            RTLog.warn("call", "busytone res=0")
            return nil
        }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        return id
    }
}
