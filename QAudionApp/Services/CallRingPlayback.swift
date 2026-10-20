import AVFoundation
import AudioToolbox
import Foundation
import UIKit
import QAudionEngine

/// Where the files of a ringtone are.
enum CallRingFiles {

    /// The in-app loop of a resolved ringtone: the bundled loop, or the imported file.
    static func loopURL(_ resolution: CallSoundCatalog.Resolution) -> URL? {
        if resolution.isCustom { return CustomRingtone.customFileURL() }
        guard let name = resolution.bundledLoopResource else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "caf")
    }

    /// The ringtone in force, resolved against the files on disk.
    static func currentResolution(_ store: SettingsStore = SettingsStore()) -> CallSoundCatalog.Resolution {
        CustomRingtone.currentResolution(store: store)
    }
}

/// The ring of an incoming call while the app is in the foreground and CallKit's own UI is not showing: the chosen
/// ringtone looped by an `AVAudioPlayer` at the user's ring volume, with optional haptics.
///
/// If the player cannot start (a missing or unreadable file) the old system alert chime is repeated every 3 s,
/// so a packaging problem never means a silent ring.
@MainActor
final class InAppRingPlayer {

    private var player: AVAudioPlayer?
    private var fallbackTimer: DispatchSourceTimer?
    private var hapticTimer: DispatchSourceTimer?
    private let session = RingAudioSession()
    /// True while a call (1:1 or group) is in progress; supplied by `AppState` from its call state.
    private let inCall: () -> Bool

    init(inCall: @escaping () -> Bool) { self.inCall = inCall }

    var isRunning: Bool { player != nil || fallbackTimer != nil || hapticTimer != nil }

    /// Starts the ring. Idempotent.
    func start() {
        guard !isRunning else { return }
        // An invite that arrives during a live call must not start the looping ring or the haptics, and must not
        // touch the call's audio session: one short chime, as before.
        if inCall() {
            playSingleChime()
            return
        }
        let store = SettingsStore()
        let settings = store.loadCallSounds()
        let resolution = CallRingFiles.currentResolution(store)
        let line = "inappring start id=\(resolution.effectiveId) fallback=\(resolution.usedFallback ? 1 : 0)"
        RTLog.info("call", line)
        if settings.ringVolume > 0 {
            startPlayer(resolution: resolution, volume: settings.ringVolume)
        } else {
            RTLog.info("call", "inappring silent=1")
        }
        if settings.ringHapticsEnabled && HapticFeedback.masterEnabled { startHaptics() }
    }

    /// Stops the ring and its haptics. Idempotent.
    func stop() {
        let wasRunning = isRunning
        player?.stop()
        player = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
        hapticTimer?.cancel()
        hapticTimer = nil
        session.end(inCall: inCall())
        if wasRunning { RTLog.info("call", "inappring stop=1") }
    }

    private func startPlayer(resolution: CallSoundCatalog.Resolution, volume: Float) {
        session.begin(inCall: false, ignoreSilentSwitch: false)
        guard let url = CallRingFiles.loopURL(resolution) else {
            RTLog.warn("call", "inappring res=0")
            startFallbackChime()
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = volume
            p.prepareToPlay()
            guard p.play() else {
                RTLog.warn("call", "inappring play=0")
                startFallbackChime()
                return
            }
            player = p
        } catch {
            let code: Int = (error as NSError).code
            RTLog.warn("call", "inappring init=0 err=\(code)")
            startFallbackChime()
        }
    }

    /// One short chime (the default ringtone's 3 s unit) as a system sound, which uses no audio session.
    private func playSingleChime() {
        RTLog.info("call", "inappring inCall=1 single=1")
        var id: SystemSoundID = 0
        if let url = Bundle.main.url(forResource: CallSoundCatalog.defaultLoopResourceName, withExtension: "caf"),
           AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError {
            AudioServicesPlayAlertSoundWithCompletion(id) { AudioServicesDisposeSystemSoundID(id) }
        } else {
            AudioServicesPlayAlertSound(1005)
        }
    }

    private func startFallbackChime() {
        // 1005 = "sms-received5.caf".
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 3.0)
        timer.setEventHandler { AudioServicesPlayAlertSound(1005) }
        fallbackTimer = timer
        timer.resume()
    }

    private func startHaptics() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        hapticTimer = timer
        timer.resume()
    }
}

/// Plays a short preview of a ringtone in the settings screen.
@MainActor
final class RingPreviewPlayer: ObservableObject {

    @Published private(set) var playingId: String?
    private var player: AVAudioPlayer?
    private var stopWork: DispatchWorkItem?
    private let session = RingAudioSession()
    private let inCall: () -> Bool

    init(inCall: @escaping () -> Bool) { self.inCall = inCall }

    /// Plays `url` at `volume` for a few seconds. Starting another preview, or `stop()`, ends this one.
    func play(id: String, url: URL?, volume: Float, startAt: TimeInterval = 0) {
        stop()
        // No preview during a call: it would take the call's audio session.
        guard !inCall() else {
            RTLog.info("call", "ringpreview skip=1 inCall=1")
            return
        }
        guard let url else {
            RTLog.warn("call", "ringpreview res=0")
            return
        }
        session.begin(inCall: false, ignoreSilentSwitch: true)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = max(0.2, volume)
            if startAt > 0 { p.currentTime = min(startAt, max(0, p.duration - 1)) }
            guard p.play() else {
                RTLog.warn("call", "ringpreview play=0")
                session.end(inCall: inCall())
                return
            }
            player = p
            playingId = id
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        } catch {
            let code: Int = (error as NSError).code
            RTLog.warn("call", "ringpreview init=0 err=\(code)")
            session.end(inCall: inCall())
        }
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        player?.stop()
        player = nil
        if playingId != nil { session.end(inCall: inCall()) }
        playingId = nil
    }
}

/// One-shot cues played as system sounds: they need no audio session, so they work before CallKit activates one
/// (the start tick) and after it released it (the call-ended chime, the busy tone). A system sound has no volume
/// of its own: it follows the ringer volume and the silent switch.
@MainActor
final class CallCueSystemSound {

    private var ids: [CallCueKind: SystemSoundID] = [:]

    /// Plays the cue if the settings allow it. Returns whether a sound was started.
    @discardableResult
    func play(_ kind: CallCueKind, settings: CallSoundSettings = SettingsStore().loadCallSounds()) -> Bool {
        guard CallCueGate.shouldPlay(kind, settings: settings) else {
            RTLog.info("call", "cue skip name=\(kind.rawValue) disabled=1")
            return false
        }
        guard let url = Bundle.main.url(forResource: kind.resourceName, withExtension: "caf") else {
            RTLog.warn("call", "cue fail name=\(kind.rawValue) reason=missing_file")
            return false
        }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else {
            RTLog.warn("call", "cue fail name=\(kind.rawValue) reason=register")
            return false
        }
        if let previous = ids[kind] { AudioServicesDisposeSystemSoundID(previous) }
        ids[kind] = id
        AudioServicesPlaySystemSoundWithCompletion(id) { [weak self] in
            DispatchQueue.main.async { self?.dispose(kind, id: id) }
        }
        RTLog.info("call", "cue start name=\(kind.rawValue) system=1")
        return true
    }

    private func dispose(_ kind: CallCueKind, id: SystemSoundID) {
        guard ids[kind] == id else { return }
        AudioServicesDisposeSystemSoundID(id)
        ids[kind] = nil
    }
}
