import Foundation

/// W-BYPASSDUCK (2026-09-25) -- the iOS port of Android's `SpeakerEchoSuppressor` idea, for ONE state
/// only: Voice-Processing I/O is bypassed AND the output is the built-in loudspeaker. Pure gain
/// arithmetic; `AudioCapture` owns the tap-thread state and folds the gain in (see there).
///
/// WHY. On the test iPhone VP-IO never delivers a tap buffer, so 71 of 71
/// built-in-mic calls run on the raw mic. Nothing cancels the echo any more: no VP-IO, and WebRTC's
/// AEC3 is not in this audio path (`audioSrtpSendEnabled = false`). On call 7727f262 (speakerphone,
/// volume 100, six minutes in bypass) the far end heard a very loud echo, made louder by the make-up
/// AGC (mean gain 4.81 against 1.9-2.6 on the Bluetooth calls). Everything below already applies to a
/// state that is degraded by definition -- the earpiece, headsets, and any call whose VP-IO works are
/// never touched.
///
/// WHAT IT DOES. While the far end is audible (the existing `AudioCapture.isFarEndActive` proxy: a
/// decoded RX frame with RMS >= 1% within the last 200 ms) and the local side does not clearly
/// dominate the mic, the TX gain ramps down to `floorGain` (0.25 = -12 dB) at `attackFullMs`, is held
/// for `hangoverHoldMs`, and ramps back at `releaseFullMs`. It never mutes: -12 dB is "quiet for a
/// moment", not a dropout, and when in doubt the gain goes back to 1 (cutting speech that should have
/// been sent is worse than passing echo that should have been cut).
///
/// PORTED FROM ANDROID (`SpeakerEchoSuppressor.kt` / `CallAudioBridge.gradeEchoAndComputeGain`,
/// e506f1c), with the differences that matter:
///  * floor 0.25 (-12 dB) instead of 0.15 (-16 dB): the state is already degraded and iOS has no
///    calibration data for this stage yet, so the cap is the conservative end;
///  * attack 100 ms and release 300 ms full-travel, as Android's 5 / ~12 frames at 20 ms, but stated in
///    ms and applied per buffer duration (the iOS tap buffer is whatever the hardware hands over);
///  * the near-end test has HYSTERESIS (enter at 1.4x the played level, leave below 1.0x) and a faster
///    release (`releaseNearFullMs`) when the local side takes over, so a double-talk onset is let through;
///  * a `hangoverHoldMs` after the far end goes quiet, because the far-end proxy is stamped when a frame
///    ARRIVES, ahead of the jitter buffer and the player queue: the acoustic echo of the last frame comes
///    out of the speaker up to ~0.1-0.3 s after the proxy has gone false.
///
/// WHERE IT SITS. `AudioCapture` folds this gain into the make-up AGC's per-sample multiplier as the LAST
/// factor, the AGC law itself still measuring the raw buffer. Applied BEFORE the AGC it would be undone:
/// the AGC would see the quieter signal and lift its gain to restore the level (Android measured exactly
/// that on call 69a3c5d6, W-AGCUNDOESAEC: 0.15 x 2.80 = 0.42 where 0.15 was intended). The AGC is NOT
/// limited here: capping its make-up gain does not improve the echo-to-speech ratio, it only makes both
/// quieter.
///
/// LIMITS (uncalibrated on iOS; the remote flag `ios_bypass_echo_duck` is the kill switch). The raw iPhone
/// mic is quiet (~1% RMS on normal speech), often below the far-end level, so the near-end test will
/// rarely call local speech dominant during far-end audio: in practice this is a -12 dB gate on the TX
/// while the far end talks. `echo_duck_near_pct` in `call.audio.diag` says how often it did.
///
/// The near-end test's reference is the PEAK-HELD level of the audible RX frames (`heldPlayedRms`), not the
/// last frame: that level is taken when a frame ARRIVES, ahead of the jitter buffer and the player queue,
/// while the mic hears it about 0.3-0.4 s later. Against the instantaneous level, wherever the echo is about
/// as loud as the played level (coupling >= ~1) or a weak frame follows a strong one, the echo itself reads
/// as local speech and is ducked LESS (simulation of these coefficients, synthetic syllables, 350 ms playout
/// delay: 16 / 47 / 67 % of echo buffers left unducked at coupling 1.0 / 1.5 / 2.5, against 0 / 0.4 / 4.6 %
/// with the 500 ms hold). Still unproven on a device: no ERLE is measured, and the far-end proxy itself is
/// still stamped at arrival (200 ms window + `hangoverHoldMs`), so the tail of a burst can outlast it when the
/// playout delay is longer than ~0.3 s.
public enum BypassEchoDuck {

    // MARK: - Remote kill switch

    /// `flags.json` key of the remote kill switch (`CallsGate.bypassEchoDuckEnabled()` reads it through
    /// `FeatureFlags`, once per call). Held here so the key and its default are pinned by a test.
    public static let remoteFlagKey: String = "ios_bypass_echo_duck"
    /// Default ON: an absent key, an unfetched file or a non-Bool value leave the ducker armed.
    public static let remoteFlagDefault: Bool = true

    // MARK: - Constants

    /// TX gain floor: 0.25 = -12.04 dB, the "tetto" of the attenuation.
    public static let floorGain: Float = 0.25
    /// Full travel 1.0 -> floor while the far end is audible (Android: 5 frames of 20 ms).
    public static let attackFullMs: Float = 100
    /// Full travel floor -> 1.0 once the far end is quiet and the hangover has elapsed (Android: ~300 ms).
    public static let releaseFullMs: Float = 300
    /// Full travel floor -> 1.0 when the local side dominates the mic (double-talk onset).
    public static let releaseNearFullMs: Float = 100
    /// How long the gain is held after the far end goes quiet.
    public static let hangoverHoldMs: Int = 120
    /// The mic must reach this multiple of the played level to count as local speech ...
    public static let nearEnterRatio: Float = 1.4
    /// ... and stays "local speech" until it falls below this multiple (hysteresis).
    public static let nearExitRatio: Float = 1.0
    /// Time constant (ms) of the decay of the held played level (`heldPlayedRms`): it has to outlast the
    /// playout delay (jitter target 240-360 ms + player queue ~80 ms) between a frame's arrival stamp and
    /// the moment the mic hears it.
    public static let playedHoldMs: Float = 500
    /// Mic RMS (0...1) below which nothing is worth ducking: there is no echo to hear, and gating a
    /// silent mic would only make the noise floor pump (Android: DEFAULT_MIC_NOISE_FLOOR).
    public static let micSilenceRms: Float = 0.002
    /// A buffer counts as "ducking" in the telemetry below this gain.
    public static let activeGainThreshold: Float = 0.99

    static let attackPerMs: Float = (1 - floorGain) / attackFullMs
    static let releasePerMs: Float = (1 - floorGain) / releaseFullMs
    static let releaseNearPerMs: Float = (1 - floorGain) / releaseNearFullMs

    // MARK: - Eligibility

    /// The ducker runs only in the degraded state it exists for: the remote switch is on, VP-IO is NOT
    /// active on this engine, and the output is the built-in loudspeaker.
    public static func isEligible(flagEnabled: Bool, vpioActive: Bool, onSpeaker: Bool) -> Bool {
        return flagEnabled && !vpioActive && onSpeaker
    }

    // MARK: - Gain

    public struct State: Equatable {
        /// The multiplier applied to the TX buffer, 1.0 ... `floorGain`.
        public var gain: Float
        /// ms left of the hold after the far end went quiet.
        public var hangoverMs: Int
        /// The last near-end classification (the hysteresis latch).
        public var nearLatched: Bool

        public init(gain: Float = 1, hangoverMs: Int = 0, nearLatched: Bool = false) {
            self.gain = gain
            self.hangoverMs = hangoverMs
            self.nearLatched = nearLatched
        }
    }

    /// The played-level reference of the near-end test after one more audible RX frame (`frameRms`,
    /// 0...1): the frame's own RMS, or `previous` decayed exponentially (time constant `playedHoldMs`) by
    /// `elapsedMs`, the time since the previous audible frame, if that is higher -- a peak-hold. Negative
    /// or huge `elapsedMs` (a clock step, the first frame of a call) is clamped to 0 ... 60 s.
    public static func heldPlayedRms(previous: Float, frameRms: Float, elapsedMs: Int64) -> Float {
        let elapsed: Float = Float(min(max(elapsedMs, 0), 60_000))
        let decayed: Float = previous * exp(-elapsed / playedHoldMs)
        return decayed > frameRms ? decayed : frameRms
    }

    /// Whether the local side dominates the mic (`micRms` and `playedRms` are 0...1 RMS of the raw mic
    /// buffer and of the played reference, see `heldPlayedRms`). Hysteresis: it takes `nearEnterRatio` x the played
    /// level to become dominant and dropping below `nearExitRatio` x to stop being so, so the decision
    /// does not chatter on a syllable that hovers around one threshold.
    public static func nextNearSpeechDominant(micRms: Float, playedRms: Float, wasDominant: Bool) -> Bool {
        let ratio: Float = wasDominant ? nearExitRatio : nearEnterRatio
        return micRms >= playedRms * ratio
    }

    /// The gain function. Order matters: local speech wins over everything (fast release, hangover
    /// cancelled); otherwise an audible far end ducks and re-arms the hangover; otherwise the gain is
    /// held while the hangover runs and only then released. Stays inside `floorGain` ... 1.
    /// `bufferMs` is the duration of the buffer this step covers (>= 1).
    public static func bypassEchoDuckGain(farEndActive: Bool,
                                          nearSpeechDominant: Bool,
                                          state: State,
                                          bufferMs: Int) -> State {
        let ms: Int = bufferMs > 0 ? bufferMs : 1
        let dt: Float = Float(ms)
        var next = state
        if nearSpeechDominant {
            next.hangoverMs = 0
            next.gain = min(1, state.gain + dt * releaseNearPerMs)
        } else if farEndActive {
            next.hangoverMs = hangoverHoldMs
            next.gain = max(floorGain, state.gain - dt * attackPerMs)
        } else if state.hangoverMs > 0 {
            next.hangoverMs = max(0, state.hangoverMs - ms)
        } else {
            next.gain = min(1, state.gain + dt * releasePerMs)
        }
        return next
    }

    /// One tap buffer: classify, then step. `farEndActive` is the shared proxy; a mic below
    /// `micSilenceRms` carries no echo worth ducking, so it does not count as "far end audible" here.
    public static func step(state: State,
                            farEndActive: Bool,
                            micRms: Float,
                            playedRms: Float,
                            bufferMs: Int) -> State {
        let near = nextNearSpeechDominant(micRms: micRms, playedRms: playedRms, wasDominant: state.nearLatched)
        let echoPresumed = farEndActive && micRms >= micSilenceRms
        var next = bypassEchoDuckGain(farEndActive: echoPresumed,
                                      nearSpeechDominant: near,
                                      state: state,
                                      bufferMs: bufferMs)
        next.nearLatched = near
        return next
    }

    /// Duration of a canonical (48 kHz mono Int16) buffer in whole ms, at least 1.
    public static func bufferMs(byteCount: Int) -> Int {
        let bytesPerMs = AudioConstants.sampleRate / 1000 * (AudioConstants.bitsPerSample / 8) * AudioConstants.channels
        guard bytesPerMs > 0, byteCount > 0 else { return 1 }
        let ms = byteCount / bytesPerMs
        return ms > 0 ? ms : 1
    }

    // MARK: - Telemetry

    /// Per-call totals, written on the tap thread (one buffer at a time) and read at teardown.
    public struct Totals: Equatable {
        /// Buffers the ducker was eligible for (bypass + speaker).
        public private(set) var frames: Int64 = 0
        /// ... of which the gain was below `activeGainThreshold`.
        public private(set) var activeFrames: Int64 = 0
        /// Buffers with the far end audible, and how many of those were judged "local speech dominates".
        public private(set) var farEndFrames: Int64 = 0
        public private(set) var nearFrames: Int64 = 0
        /// Lowest gain applied (1 = never ducked).
        public private(set) var gainMin: Float = 1

        public init() {}

        public mutating func note(gain: Float, farEndActive: Bool, nearDominant: Bool) {
            frames &+= 1
            if gain < BypassEchoDuck.activeGainThreshold { activeFrames &+= 1 }
            if farEndActive {
                farEndFrames &+= 1
                if nearDominant { nearFrames &+= 1 }
            }
            if gain < gainMin { gainMin = gain }
        }
    }

    /// The `call.audio.diag` attributes. `echo_duck_enabled` is always present (false shows the remote
    /// switch worked); the rest only when the ducker was eligible for at least one buffer, because
    /// absent is the honest value for "did not run":
    ///  * `echo_duck_frames` -- buffers it was eligible for;
    ///  * `echo_duck_active_pct` -- share of those with the gain below 0.99;
    ///  * `echo_duck_gain_min` -- the lowest gain applied (0.25 = the floor);
    ///  * `echo_duck_near_pct` -- share of far-end-audible buffers judged "local speech dominates"
    ///    (0 = the near-end test never fired, the calibration signal for `nearEnterRatio`).
    public static func diagAttrs(totals: Totals, enabled: Bool) -> [String: Any] {
        var attrs: [String: Any] = [:]
        attrs["echo_duck_enabled"] = enabled
        guard totals.frames > 0 else { return attrs }
        attrs["echo_duck_frames"] = Int(clamping: totals.frames)
        let activePct: Double = Double(totals.activeFrames) / Double(totals.frames) * 100
        attrs["echo_duck_active_pct"] = (activePct * 10).rounded() / 10
        attrs["echo_duck_gain_min"] = (Double(totals.gainMin) * 100).rounded() / 100
        if totals.farEndFrames > 0 {
            let nearPct: Double = Double(totals.nearFrames) / Double(totals.farEndFrames) * 100
            attrs["echo_duck_near_pct"] = (nearPct * 10).rounded() / 10
        }
        return attrs
    }

    /// One numeric line per engine start (see `VpioObservability` for the format rules): `en` = remote
    /// switch, `vpio` = VP-IO active on this engine, `spk` = built-in loudspeaker, `on` = eligible.
    public static func startLine(gen: Int, flagEnabled: Bool, vpioActive: Bool, onSpeaker: Bool) -> String {
        let eligible: Int = isEligible(flagEnabled: flagEnabled, vpioActive: vpioActive, onSpeaker: onSpeaker) ? 1 : 0
        let en: Int = flagEnabled ? 1 : 0
        let vp: Int = vpioActive ? 1 : 0
        let sp: Int = onSpeaker ? 1 : 0
        return "audioVp ev=duck gen=\(gen) on=\(eligible) en=\(en) vpio=\(vp) spk=\(sp)"
    }
}
