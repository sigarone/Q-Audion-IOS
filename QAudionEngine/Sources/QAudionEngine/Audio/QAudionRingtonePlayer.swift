import Foundation
#if canImport(AVFoundation)
import AVFoundation
import QAudionVPIOSafe

/// W-RINGBACKCONFIRMED (2026-09-02) — renders and plays Q-Audion's
/// procedural OUTGOING-call cue sounds (dialing / confirmed-ringback /
/// key-exchange / connected / ended). Mirrors Android's
/// `QAudionRingtonePlayer.kt` / Desktop's `QAudionRingtone.ts`: `loop(cue)`
/// for a seamless looping cue, `play(cue)` for a one-shot, `stop()`
/// idempotent teardown. Cue buffers are rendered once (pure DSP, see
/// `QAudionSynth`) and cached for the process lifetime.
///
/// Deliberately a SEPARATE, playback-only `AVAudioEngine` from the call's
/// own `AudioCapture` (mic capture + VP-IO) — it never touches the input
/// node, never calls `setVoiceProcessingEnabled`, and does not compete with
/// `AudioCapture`'s engine lifecycle. Both share the same underlying
/// `AVAudioSession` (a systemwide singleton), which is why this player must
/// still only be used AFTER CallKit activates that session — see
/// `AppState`'s `onAudioSessionActivated` bridge, the same gate
/// `AudioCapture` itself waits on (W464).
///
/// INCOMING calls are unaffected: they keep CallKit's native ringtone
/// (`CXProviderConfiguration.ringtoneSound`) and the separate
/// `startInAppRingtone()`/`stopInAppRingtone()` system-sound fallback — this
/// player owns only the outgoing-call cues, which had no audio feedback of
/// any kind before this (Apple's CXProvider does not auto-play an outgoing
/// ringback the way it auto-plays the incoming ringtone; the app is
/// responsible for it, same reason Android's self-managed
/// ConnectionService needed `QAudionRingtonePlayer.kt` built from scratch).
public final class QAudionRingtonePlayer {

    public enum Cue: Hashable {
        case outgoingRing
        case confirmedRingback
        case keyExchange
        case callConnected
        case callEnded
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var cache: [Cue: AVAudioPCMBuffer] = [:]
    private var connected = false

    public init() {
        engine.attach(player)
    }

    private func buffer(for cue: Cue) -> AVAudioPCMBuffer? {
        if let cached = cache[cue] { return cached }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: QAudionSynth.defaultSampleRate, channels: 1
        ) else { return nil }
        let samples: [Float]
        switch cue {
        case .outgoingRing: samples = QAudionSynth.renderOutgoingRingLoop()
        case .confirmedRingback: samples = QAudionSynth.renderConfirmedRingbackLoop()
        case .keyExchange: samples = QAudionSynth.renderKeyExchangeLoop()
        case .callConnected: samples = QAudionSynth.renderCallConnected()
        case .callEnded: samples = QAudionSynth.renderCallEnded()
        }
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buf.floatChannelData?[0]
        else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        cache[cue] = buf
        return buf
    }

    /// Returns true iff the engine is actually running afterward — callers
    /// MUST check this before touching `player`. `AVAudioPlayerNode.play()`
    /// raises an uncatchable Objective-C NSException (not a Swift `Error`)
    /// when its engine isn't running, and `engine.start()` below IS allowed
    /// to throw and leave `engine.isRunning == false` — e.g. when the
    /// shared `AVAudioSession` this engine deliberately doesn't own (see
    /// the class doc) is still mid-transition because CallKit's own
    /// activation and this player's first `ensureRunning()` land at
    /// effectively the same instant.
    ///
    /// W-RINGTONEPLAYSAFE (2026-09-05) — the `start()`-failing-silently
    /// case this comment used to describe as the fix (2026-09-02,
    /// 1.0.1075/2738) did NOT hold: live TestFlight crash reports pulled
    /// 2026-09-05 show the identical `-[AVAudioPlayerNode play]` SIGABRT
    /// still recurring on every build since (2597/2609/2621/2681/2709/
    /// 2750/2773/2795) — 13 reports over 7 weeks, unchanged stack.
    ///
    /// The server-side in-app bug reports (W561 auto-triggered "audio_quality"
    /// tickets, cross-referenced 2026-09-05) close the gap this comment
    /// speculated about: the app's own `CrashReporter` (W472) captured the
    /// REAL NSException on-device for the 2026-09-03T13:46 instance —
    /// `name: com.apple.coreaudio.avfaudio`, `reason: "player started when
    /// in a disconnected state"` — and every one of the 6 screenshots
    /// attached to those reports shows the exact same UI moment: the
    /// INCOMING-CALL ringing screen ("dovrai rispondere entro 30s"), i.e.
    /// the call's very first cue. So this is NOT "engine not running" (that
    /// path already prints+skips above) — it is the PLAYER NODE itself
    /// getting disconnected from the graph by an OS-level engine
    /// reset/reconfiguration (media-server reset, route change, CallKit's
    /// own session activation landing at the same instant) that can
    /// invalidate node connections even while `engine.isRunning` reads
    /// true afterward. `connected` used to be a one-shot latch — set once,
    /// never revisited — so once the OS silently tore the connection down,
    /// this method kept skipping the `engine.connect(...)` step forever and
    /// every subsequent `play()` aborted. It is now reset below whenever
    /// the engine is found not running, forcing a fresh reconnect on the
    /// next attempt instead of trusting stale state. `@MainActor`-isolating
    /// this class (all callers already are, see `AppState`) cannot close
    /// this gap on its own — the race is with the OS, not with another
    /// Swift call — so both NSException-raising AVFAudio calls in this
    /// file — `engine.connect(...)` immediately below (the format-race this
    /// comment already documented) AND `player.play()` in `loop()`/`play()`
    /// — are ALSO run through `QAudionVPIOSafe`'s
    /// `QAudionRunCatchingNSException` (the same ObjC `@try/@catch` shim
    /// `AudioProcessingPipeline` already uses for `setVoiceProcessingEnabled`'s
    /// identical footgun) as defense-in-depth, so any raise this reconnect
    /// logic doesn't preempt still degrades to a skipped cue instead of
    /// `abort()`.
    @discardableResult
    private func ensureRunning() -> Bool {
        if !engine.isRunning {
            // See the "disconnected state" root cause above: a stopped
            // engine means the graph state is no longer trustworthy, so
            // force the next connect attempt below instead of trusting a
            // `connected = true` set before the OS tore it down.
            connected = false
        }
        if !connected {
            // W-VAULTLOCKNFC follow-up (2026-09-02, live crash reports —
            // "si è schiantato in fase di connessione") — `player
            // .outputFormat(forBus: 0)` on a freshly-attached
            // AVAudioPlayerNode that has never scheduled a buffer is a
            // documented AVAudioEngine footgun: before the node has ever
            // played anything it can report a degenerate format (0
            // channels / 0 Hz), and `AVAudioEngine.connect(_:to:format:)`
            // is not a throwing function — an invalid format raises an
            // uncatchable Objective-C NSException instead of a Swift
            // error, crashing the process outright. This engine's first
            // connect+start happens exactly when a call needs its first
            // cue (onAudioSessionActivated / call_ready / call_answer),
            // i.e. exactly "in fase di connessione" — matches the timing
            // of the reports. Use the SAME explicit, always-valid format
            // already computed for the PCM buffers instead of trusting
            // the player's pre-connection format.
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: QAudionSynth.defaultSampleRate, channels: 1
            ) else {
                print("[QAudionRingtonePlayer] could not construct connect format")
                return false
            }
            var connectError: NSError?
            let connectRan = QAudionRunCatchingNSException({
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }, &connectError)
            guard connectRan else {
                print("[QAudionRingtonePlayer] engine.connect raised ObjC NSException — skipping cue (no crash): \(connectError?.localizedDescription ?? "unknown")")
                return false
            }
            connected = true
        }
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            print("[QAudionRingtonePlayer] engine start failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Replace the currently-playing loop with `cue`, or start one.
    public func loop(_ cue: Cue) {
        guard let buf = buffer(for: cue), ensureRunning() else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        var playError: NSError?
        let playRan = QAudionRunCatchingNSException({
            player.play()
        }, &playError)
        if !playRan {
            print("[QAudionRingtonePlayer] player.play() raised ObjC NSException in loop(\(cue)) — skipping cue (no crash): \(playError?.localizedDescription ?? "unknown")")
        }
    }

    /// Fire a one-shot cue (connected chime, ended dissolve).
    public func play(_ cue: Cue) {
        guard let buf = buffer(for: cue), ensureRunning() else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        var playError: NSError?
        let playRan = QAudionRunCatchingNSException({
            player.play()
        }, &playError)
        if !playRan {
            print("[QAudionRingtonePlayer] player.play() raised ObjC NSException in play(\(cue)) — skipping cue (no crash): \(playError?.localizedDescription ?? "unknown")")
        }
    }

    /// Stop any looping/playing cue. Idempotent — safe to call even if
    /// nothing was ever started.
    public func stop() {
        player.stop()
    }
}
#endif
