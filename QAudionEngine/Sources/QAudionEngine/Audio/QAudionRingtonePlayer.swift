import Foundation
#if canImport(AVFoundation)
import AVFoundation

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

    private func ensureRunning() {
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
                return
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connected = true
        }
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("[QAudionRingtonePlayer] engine start failed: \(error.localizedDescription)")
        }
    }

    /// Replace the currently-playing loop with `cue`, or start one.
    public func loop(_ cue: Cue) {
        guard let buf = buffer(for: cue) else { return }
        ensureRunning()
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    /// Fire a one-shot cue (connected chime, ended dissolve).
    public func play(_ cue: Cue) {
        guard let buf = buffer(for: cue) else { return }
        ensureRunning()
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    /// Stop any looping/playing cue. Idempotent — safe to call even if
    /// nothing was ever started.
    public func stop() {
        player.stop()
    }
}
#endif
