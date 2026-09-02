import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class AudioCapture {
    public var onFrame: ((Data) -> Void)?
    private var engine: AVAudioEngine?
    // SINGLE-ENGINE FIX — playback player node hosted on the SAME AVAudioEngine
    // as the capture tap. Two SEPARATE AVAudioEngine instances on one
    // AVAudioSession both instantiate the single hardware RemoteIO / Voice-
    // Processing I/O unit; starting the second one tears down the first's
    // OUTPUT route → the session reports "active" and engines report "started"
    // but NO PCM ever reaches the DAC → total silence in BOTH directions
    // (capture/input keeps working, which is why tx_enc grew while nobody heard
    // anything). Confirmed independently by OpenRouter (large) + Gemini + the
    // RemoteIO mechanism. One engine owning BOTH the input tap and the player
    // node fixes it — and lets VP-IO's AEC reference the playback for echo
    // cancellation, the canonical VoIP graph.
    private var playerNode: AVAudioPlayerNode?
    /// W-IOSPLAYOUT (2026-07-25) — buffers handed to `playerNode` whose completion has not
    /// fired yet, i.e. the player's own queue depth. Main-queue only (both sides of the
    /// ledger hop there), so no lock. Reset wherever the player is stopped: `stop()`
    /// discards its queued buffers WITHOUT firing their handlers on every documented path,
    /// so a stale count would make the depth read high for the rest of the call.
    // ── W-IOSJITTER wiring (2026-07-26) ────────────────────────────────────────
    /// The playout buffer the sealed-audio path never had. See `playFrame`.
    private let playoutJitter = PlayoutJitterBuffer()

    // ── W-LONGAUDIO (2026-08-10) — the two frame durations are not the same ──
    //
    // What we SEND and what we are SENT are independent. Truth-table row 8 makes
    // that explicit: the capability array is unauthenticated, so a relay can
    // strip the send tag in one direction only and leave the two ends latched
    // differently. Both directions still carry audio, and they do so precisely
    // because receive is unconditional and never consults what we latched.
    //
    // So: capture geometry follows the LATCHED profile, playout geometry follows
    // the OBSERVED inbound frames. Deriving one from the other is the bug this
    // split exists to prevent — and it was the shipped behaviour, because
    // `AudioPlayback` took its frame size from the encode constant.

    /// The profile this call CAPTURES and ENCODES at. Set once per call, before
    /// `start()`; never changes mid-call.
    ///
    /// W-ALL60 (2026-08-14) — defaults to the 60 ms profile. It used to default
    /// to `.standard`, so a call whose latch arrived after `start()` captured
    /// 20 ms chunks while the engine encoded for whatever it had latched. The
    /// re-chunker (`rechunkAndEmit`) reads THIS, so the two must not disagree.
    public private(set) var captureProfile: AudioProfile = AudioProfile.defaultProfile

    /// Duration of the frames currently ARRIVING, in ms, observed from their PCM
    /// length. 20 until something longer shows up.
    ///
    /// Stored in [PlayoutJitterBuffer] rather than here because it is written on
    /// whatever thread decrypts network audio and read on main by the pump; the
    /// buffer already owns a lock for exactly this pair of threads, and adding a
    /// second unsynchronised copy next to it is how the W-PLAYOUTRACE freeze
    /// happened.
    private var inboundFrameDurationMs: Int { playoutJitter.inboundFrameDurationMs }

    /// Latch the send-side profile for this call. Must be called before
    /// `start()`; ignored afterwards, because the capture graph and the encoder
    /// are already built around the previous value and mid-call switching is
    /// forbidden (no re-latch, in any direction, for any reason).
    @discardableResult
    public func setCaptureProfile(_ profile: AudioProfile) -> Bool {
        guard !isRunning else { return false }
        captureProfile = profile
        return true
    }

    /// Last frame actually delivered, for repeat-based concealment on underrun.
    private var lastDeliveredPlayoutFrame: Data?
    // W-ALL60 — 120 ms expressed at the default profile's frame duration (2 at
    // 60 ms), not at the module's 20 ms analysis constant, which would have
    // allowed 6 x 60 ms = 360 ms of repeated-frame buzz before the first real
    // frame re-armed the budget.
    private var playoutConcealBudget = AudioConstants.framesForMs(
        120, frameDurationMs: AudioProfile.defaultProfile.frameDurationMs)
    /// Concealed frames this call — the number that makes an underrun visible.
    private var playoutConcealed = 0

    private var playoutInFlight: Int = 0
    private var playFormat: AVAudioFormat?
    private var isRunning = false
    // W-AEC-FIX — VP-IO input-pull sink: when Voice-Processing I/O is active the
    // inputNode tap starves on iPad + builtInSpeaker unless the mic is actively
    // pulled through the graph; this muted mixer is that pull (see start()).
    private var inputSink: AVAudioMixerNode?
    // W-AEC-FIX — set true by the tap callback on its first delivered buffer.
    // The starve watchdog checks it to detect the VP-IO "tap never fires" case.
    private var firstFrameReceived = false
    private let audioPipeline: AudioProcessingPipeline
    // W475 — re-chunking accumulator. `installTap` delivers buffers of
    // an arbitrary size; the Opus encoder needs EXACTLY bytesPerFrame.
    // Touched only on the single tap-callback thread, so no lock.
    private var pcmAccumulator = Data()
    // AGC-DIAG (2026-07-10) — cheap per-call level tracker to get real
    // evidence on suspected AGC pumping/crackling near the mic on the
    // speaker route (W574c enables AGC there on purpose — see
    // AudioProcessingPipeline.enableVoiceProcessing). Int comparisons only,
    // no allocation, on samples already decoded for the accumulator above —
    // safe on the 50fps tap callback. `clipThreshold` is ~97% of Int16
    // full-scale (32767); `consumeLevelStats()` reads+resets at call end.
    private var peakAmplitude: Int16 = 0
    private var clipSampleCount: Int64 = 0
    /// W-AGCCEIL (2026-07-21) — was 31800 (97.05% FS), which sat BELOW the
    /// soft-knee limiter's output ceiling (0.98 × 32767 = 32112). The limiter's
    /// output asymptote therefore landed inside the "clip" band, so every
    /// limiter-shaped sample was reported as a clip and `clip_samples` measured
    /// LIMITER ACTIVITY, not clipping. The live data shows this cleanly: of the
    /// four post-dcace27 calls the only one that reported 0 clips (84c06f73) is
    /// exactly the one whose peak (96.7%) fell below 97.05%, while the three at
    /// 97.8–98.0% reported 29/29/405 — no exceptions. Raised above the limiter
    /// ceiling so a "clip" once again means a sample that reached full scale
    /// without passing through the knee (i.e. real upstream/ADC clipping, which
    /// only the gain≈1 pass-through path can produce). Limiter engagement is now
    /// counted separately as `limiterSampleCount`.
    static let clipThreshold: Int16 = 32600
    /// Samples the soft-knee limiter actually shaped this call. The duty cycle
    /// of the limiter was the one quantity the old telemetry could NOT answer
    /// (peak is a call-max, clip_samples was contaminated as described above),
    /// which is why "how often is the waveshaper engaged" had to be inferred
    /// rather than measured. Reported as `limiter_pct`.
    private var limiterSampleCount: Int64 = 0
    // W-MICAGC (2026-07-12) — gentle software make-up AGC. Server telemetry
    // showed the iOS mic ships systematically quiet (tx peak median ~5%, RMS ~1%
    // of full scale) because VP-IO/AGC is OFF on the earpiece route (W556) and
    // the TX-LIMITER below only CAPS peaks, never lifts level. This is the
    // middle ground between "raw = too quiet" and "Apple VP-IO AGC = spara
    // troppo / pumping": a SLOW, BOOST-ONLY make-up gain toward a target RMS,
    // gated on voice (never amplifies silence/background hiss) and capped so an
    // already-loud frame is never over-driven (the limiter still backstops
    // peaks). Runs in BOTH VP-IO modes (see agcMaxGainVpio below for why — W-
    // TUNEGAP 2026-07-20 restored this after a same-day-in-2026-07-12 refactor
    // (a542727) had silently disabled the VP-IO-on half). Lock-free
    // single-thread state (the 50 fps tap callback). Killswitch if it regresses.
    public static var micAgcEnabled = true
    private var micAgcGain: Float = 1.0
    private var micAgcMaxGainThisCall: Float = 1.0   // for telemetry
    // W-AGCNOISE (2026-07-21) — tracked background floor + the instruments that
    // make this loop's behaviour VISIBLE from server telemetry. `agc_gain` alone
    // is a call-MAX and, exactly like `peak_pct`, cannot distinguish "touched
    // the ceiling once" from "sat on the ceiling for 110 s" — which is why the
    // pumping went unnoticed. The mean gain and the hold ratio can.
    // Same single-thread (tap callback) ownership as the fields above.
    private var micAgcNoiseFloor: Float = 0
    private var micAgcGainSum: Double = 0
    private var micAgcBufferCount: Int64 = 0
    private var micAgcHoldCount: Int64 = 0
    // W-TXBURST (2026-07-21) — TX delivery cadence. `installTap` hands us
    // whatever the hardware I/O duration produces, so one callback can emit
    // several 20 ms frames back to back; on the far end that arrives as a burst
    // into a jitter buffer sized for a steady 50 fps. This counts the largest
    // such burst so the hypothesis can be tested instead of argued about (see
    // the Android `drops` split shipped alongside).
    private var txBurstMaxThisCall: Int = 0
    // W-IOSECHO (2026-07-22) — echo-cancellation EFFECTIVENESS measurement,
    // the iOS port of Android's W-SPKAEC/W-SPKECHO `echo_active_*`/
    // `echo_idle_*` telemetry. `vpio_ever_active`/`vpio_bypassed_ever` (in
    // AudioProcessingPipeline) already answer "was AEC nominally on"; they
    // say nothing about whether it actually cancelled the echo. This answers
    // that, by grading the near-end mic RMS while the far end was recently
    // audible vs while it was not. See `EchoBucketTotals` below for the full
    // rationale and honest limitations of the proxy. Plain vars, not locked:
    // `lastLoudPlayoutAtMs` is written on the (main-thread-dispatched)
    // playback path and read on the tap-callback thread, and `echoBucketThisCall`
    // is written only on the tap-callback thread and read by `consumeLevelStats()`
    // at teardown — the same benign-race pattern this file already accepts for
    // `peakAmplitude`/`clipSampleCount`/`sumSqAmplitude` above (single writer
    // per field, per-call diagnostic counters, not correctness-critical).
    private var lastLoudPlayoutAtMs: Int64 = 0
    private var echoBucketThisCall = EchoBucketTotals()
    // W-DEZIPPER (2026-07-12) — the gain actually applied to the LAST sample of
    // the previous frame. The make-up gain is ramped per-sample from this to the
    // current frame's target so the gain is continuous across the 20 ms frame
    // boundary; a constant-per-frame gain that changes frame-to-frame steps the
    // waveform at each boundary → an audible click every frame ("scoppiettante").
    private var micAgcRampFrom: Float = 1.0
    // W-AGCCEIL (2026-07-21) — DELIBERATELY LEFT AT 0.12.
    //
    // A first cut of the W-AGCCEIL fix lowered this to 0.05, reasoning from the
    // four post-dcace27 calls that a 12% target was "unreachable" and therefore
    // kept the loop railed against the peak wall. Adversarial review REFUTED
    // that on two counts and it was reverted before shipping:
    //
    //  1. UNIT CONFLATION. The 3.8–5.6% figures those calls report are
    //     `rms_pct` — a CALL-AVERAGE accumulated across the whole call
    //     INCLUDING silence (sumSqAmplitude/rmsSampleCount, reset only in
    //     consumeLevelStats). `agcTargetRms` is compared against a single
    //     20 ms buffer's RMS inside `nextMakeUpAgcGain`. Comparing the two is
    //     apples-to-oranges; the call-average is necessarily far below the
    //     voiced-buffer RMS the control law actually sees.
    //  2. It would have RE-BROKEN THE QUIET MIC. 0.05/0.12 is −7.60 dB applied
    //     to `desired` before the maxGain cap. Outside a ~0.35–0.9 dB-wide
    //     no-op band it strips up to 7.6 dB of make-up gain — precisely the
    //     faint-iOS-mic regression `04f82f1`/`dcace27` exist to fix. Live
    //     counter-example: call d1df20f0 ran with agc_gain 5.51 against a
    //     ceiling of 6.0, i.e. the RMS term was NOT inert on real material.
    //
    // The real defect was never this constant — it was `agcPeakHeadroom` being
    // applied to the one-pole's TARGET instead of to the APPLIED gain (see
    // `nextMakeUpAgcGain` below). With the ceiling now enforced on the result,
    // the peak term binds correctly on loud material and 0.12 simply lets the
    // loop lift genuinely quiet speech, which is its job.
    private static let agcTargetRms: Float = 0.12    // 12% of full scale
    // W-QUIETMIC (2026-07-12) — the iPhone earpiece mic sits very low on normal
    // speech: telemetry across calls c591a0b2/28398a12/7b03662a shows raw RMS
    // ~0.5–1.1% even at normal volume, so the old 2% gate held the AGC OFF for
    // most real speech → faint + inconsistent level ("non lineare"). Dropped to
    // 0.8%: engages on normal-quiet speech but still sits above the measured
    // room-noise floor (<0.8%), so silence/hiss is never pumped up (VP-IO NS is
    // off — W556). Above-gate speech is boosted toward agcTargetRms as intended.
    private static let agcNoiseGate: Float = 0.008   // below this = silence → hold gain
    private static let agcMaxGain: Float = 6.0
    // When VP-IO is active Apple's own AGC already contributes some make-up
    // gain, so our software make-up runs ON TOP of it with a lower ceiling to
    // bound any double-AGC interaction (still boost-only + noise-gated + slow,
    // so it can't pump). Evidence (call c4185402): iOS mic is intrinsically
    // quiet — ~5% peak raw, ~11% with VP-IO's AGC — vs Android ~71%; gating our
    // AGC to VP-IO-off left the transmitted level faint. Lifting under VP-IO too
    // closes that gap.
    //
    // W-TUNEGAP (2026-07-20) — this constant went DEAD for 8 days. Commit
    // 04f82f1 (2026-07-12 19:17) added it and wired the make-up AGC to run in
    // BOTH VP-IO modes for exactly the reason above. The SAME DAY at 23:32,
    // commit a542727 ("canonical iOS VoIP stack") re-gated the make-up AGC to
    // `!vpioActiveThisEngine` as a side effect of its broader "retire custom
    // DSP to the raw-mic fallback only" policy, silently discarding the
    // dual-mode fix and re-asserting — without new evidence — the very
    // "Apple's AGC alone is enough" assumption 04f82f1 had just measured to be
    // false. `agcMaxGainVpio` was left declared but unreachable ever since.
    // Real call 40f6d641 (2026-07-20) reproduced exactly the predicted
    // regression: agc_ever_active=true, vpio_ever_active=true, yet tx
    // rms_pct=2% — well below the "healthy 5-15%" band a542727's own commit
    // message set as its target. Restored below (see the micAgcEnabled gate
    // in the tap callback) — the ceiling here is unchanged from 04f82f1.
    private static let agcMaxGainVpio: Float = 3.0

    // ── W-AGCNOISE (2026-07-21) — the make-up stage learns how NOISY its input
    // is, and lets that (not "is Apple's AGC running") decide how much gain it
    // is allowed to apply.
    //
    // THE INVERSION THIS FIXES. `selectMakeUpAgcMaxGain` picks the ceiling from
    // `vpioActive`: 3.0 when Apple's VP-IO chain is running, 6.0 when it is not.
    // But VP-IO is the bundle that provides AEC **and noise suppression**. So
    // the signal with NO noise suppression, NO echo cancellation and NO Apple
    // AGC — a raw car-kit mic full of road noise and loudspeaker echo — is the
    // one this stage allows TWICE as much blind make-up gain on. Measured on two
    // real calls with the same pair of devices, ten minutes apart:
    //
    //   d0f84651  earpiece, VP-IO ON  (ceiling 3.0)  agc_gain 2.73  rms 6.0 %
    //   1de9935f  car kit,  VP-IO OFF (ceiling 6.0)  agc_gain 5.89  rms 9.7 %
    //
    // Both sit at 91 % / 98 % of their respective ceilings, i.e. the RMS-seeking
    // term was SATURATED in both and the ceiling alone decided the gain. The
    // second call was reported as "quasi incomprensibile" at the far end.
    //
    // WHY THE ABSOLUTE NOISE GATE CANNOT CATCH THIS. `agcNoiseGate` is 0.008,
    // tuned against a QUIET ROOM floor ("<0.8 %", see its note). A car cabin
    // with VP-IO's NS bypassed sits far above that, so the gate is open on
    // ROAD NOISE: `desired = agcTargetRms / bufferRms` saturates at the ceiling
    // on noise, the loop winds to 6.0 during every inter-word gap (τ ≈ 1 s) and
    // is ducked ≤3 dB per buffer on every syllable onset. That is textbook AGC
    // breathing, applied to unsuppressed noise. `limiter_pct` was 0.001 % on
    // that call, which RULES OUT the waveshaper as the distortion source — the
    // artifact is the gain modulation itself.
    //
    // ANDROID IS THE REFERENCE AND DOES NEITHER. `AudioCapture.kt` ships
    // `enableHwAgc = false` ("AGC pumps distant audio undesirably"),
    // `DEFAULT_NOISE_GATE_RMS = 0.0f`, and attaches HW NoiseSuppressor +
    // AcousticEchoCanceler unconditionally. `agc_ever_active=false` on both
    // calls above. Its transmitted level is lower and its dynamics intact.
    //
    // THE FIX. Track the background floor and derive the ceiling from it, so
    // the ceiling answers "how clean is this signal" instead of "who else is
    // running an AGC". This is standard practice (WebRTC's AGC2 bounds its
    // max gain by a noise estimate for the same reason) and it is
    // self-calibrating: it needs no per-route tuning.

    /// The highest level the BACKGROUND is allowed to reach after make-up gain,
    /// as a fraction of full scale. The ceiling becomes
    /// `agcNoiseCeilingRms / noiseFloor`, so a clean input is unrestricted and
    /// a noisy one loses the make-up entirely.
    ///
    /// WHY 0.02, from the two calls above and from Android:
    ///  • d0f84651 (must NOT bind — it is the acceptable call, and binding here
    ///    would re-open the faint-mic regression 04f82f1/dcace27 exist to fix).
    ///    VP-IO's NS was running; even taking the loosest possible reading of
    ///    the data — that the call-average post-gain RMS of 6.0 % was ENTIRELY
    ///    background at the max gain of 2.73 — the raw floor is at most 2.2 %,
    ///    and with NS in circuit it is realistically 0.1–0.4 %. At 0.3 % the
    ///    allowed gain is 0.02/0.003 = 6.7, well above the 3.0 configured
    ///    ceiling, so this term is inert there. It only starts to bind below
    ///    0.67 % of allowed floor, which NS does not produce.
    ///  • 1de9935f (must bind hard). No NS at all. The raw call-average was at
    ///    least 9.7/5.89 = 1.65 %, and the floor of a car cabin is the dominant
    ///    part of that average. At a 1.65 % floor the allowed gain is 1.21; at
    ///    2 % it is 1.0 (no make-up at all) — which is precisely Android's
    ///    behaviour on the same acoustics.
    ///  • Android's own transmitted call-average on the quiet call was 2.52 %
    ///    INCLUDING speech, so a 2 % ceiling on the BACKGROUND alone is a
    ///    generous bound, not an aggressive one.
    static let agcNoiseCeilingRms: Float = 0.02

    /// How far above the tracked background a buffer must sit before the
    /// RMS-seeking loop is allowed to adapt on it. 2.0 = +6 dB.
    ///
    /// This RELATIVE gate is what stops the loop winding up on road noise. The
    /// absolute `agcNoiseGate` is kept as well (a buffer under 0.8 % is silence
    /// in any environment), so on the quiet earpiece — where the floor is far
    /// below speech — the two gates agree and behaviour is unchanged.
    /// +6 dB is the smallest margin that separates speech from a stationary
    /// floor without also excluding genuinely quiet speech: at +3 dB normal
    /// floor wander would re-open the gate on noise, at +12 dB the quiet speech
    /// that `agcTargetRms` exists to lift would stop qualifying.
    static let agcSnrGateRatio: Float = 2.0

    /// Min-statistics follower for the background floor. Fast down so a new,
    /// quieter environment is adopted within ~5 buffers (100 ms); very slow up
    /// (τ ≈ 25 s at 50 fps) so a long talk-spurt cannot drag the "floor"
    /// estimate up to speech level and disable the whole mechanism.
    static let noiseFloorAlphaDown: Float = 0.25
    static let noiseFloorAlphaUp: Float = 0.0008

    /// W-VPIORETRY (2026-07-21) — how many times VP-IO may be re-attempted
    /// after a bypass, per call. See `shouldRetryVoiceProcessing`.
    static let maxVoiceProcessingRetries: Int = 1

    /// Update the background-floor estimate from one buffer's RMS.
    /// Pure; unit-tested in `AudioCaptureNoiseAdaptiveAgcTests`.
    static func nextNoiseFloor(previous: Float, bufferRms: Float) -> Float {
        let rms = bufferRms > 0 ? bufferRms : 0
        // First buffer of a call/engine: seed on the observed level rather than
        // starting at 0 (which would mean "perfectly clean" and disable the
        // ceiling for the ~25 s the slow-up path needs to climb).
        guard previous > 0 else { return rms }
        let alpha: Float = rms < previous ? noiseFloorAlphaDown : noiseFloorAlphaUp
        let next = previous + (rms - previous) * alpha
        return next > 0 ? next : 0
    }

    /// Bound the configured ceiling by how much the BACKGROUND may be lifted.
    /// Returns `configuredMaxGain` unchanged on a clean input; collapses toward
    /// 1.0 (no make-up at all — Android's behaviour) as the floor rises.
    static func noiseLimitedMaxGain(configuredMaxGain: Float, noiseFloorRms: Float) -> Float {
        guard noiseFloorRms > 0 else { return configuredMaxGain }
        let allowed = agcNoiseCeilingRms / noiseFloorRms
        if allowed >= configuredMaxGain { return configuredMaxGain }
        // W-NOISEFLOORUNKNOWN (2026-07-21) — a hard lower bound of 2.0 was
        // ADDED HERE AND THEN REMOVED, deliberately. Recording why, so nobody
        // re-adds it:
        //
        // The worry was that `agc_noise_floor_pct` ships for the first time
        // with this change, so the real post-VP-IO earpiece floor has never
        // been measured; back-solving the one good call admits 0.50%–1.20%,
        // and the bad end would cap at 1.67 instead of 3.0 (−4.3 dB) — close
        // to the class of strip that got the `agcTargetRms = 0.05` proposal
        // rejected in review the same night for reopening the faint mic.
        //
        // But the rule already handles that case BY CONSTRUCTION, and the
        // bound would have defeated the fix it was meant to guard:
        //  • A clean, quiet mic that genuinely SHOULD be lifted has, by
        //    definition, a LOW floor — so `allowed` stays at the configured
        //    ceiling and nothing is squeezed.
        //  • If the floor genuinely IS high, the input is noisy (NS bypassed,
        //    car cabin), and NOT amplifying is the correct answer for exactly
        //    the same reason it is correct in the car case.
        //  • The only estimator failure that could hurt is a positive bias
        //    (floor over-read), and the `> 1` clamp below already prevents it
        //    from ever becoming an attenuator.
        // Meanwhile a floor of 2.0 would have re-applied up to 2× gain at a
        // genuinely-measured 2% car floor — i.e. re-amplified the road noise
        // this rule exists to stop. Confirmed independently by an external
        // model before removing.
        return allowed > 1 ? allowed : 1
    }

    /// Whether the RMS-seeking term may adapt on this buffer. Absolute floor
    /// AND relative (SNR) gate — see `agcSnrGateRatio`.
    static func shouldAdaptMakeUpGain(bufferRms: Float, noiseFloorRms: Float) -> Bool {
        guard bufferRms > agcNoiseGate else { return false }
        guard noiseFloorRms > 0 else { return true }
        return bufferRms >= noiseFloorRms * agcSnrGateRatio
    }

    /// W-VPIORETRY (2026-07-21) — may VP-IO be re-attempted on this restart?
    ///
    /// THE BUG THIS FIXES. `AudioProcessingPipeline.forceDisableVoiceProcessing`
    /// is set by the W-AEC-FIX starve watchdog and cleared ONLY in
    /// `AudioCapture.stop()` — i.e. at CALL END. It is a one-way latch for the
    /// whole call: every later engine restart re-reads it and keeps VP-IO off.
    /// On call 1de9935f the engine restarted 3 times while a car kit was
    /// connecting, `vpio_bypassed_ever` came back true, and the remaining ~110 s
    /// of the call therefore ran with NO echo cancellation (car speakers →
    /// car mic), NO noise suppression and NO Apple AGC. A 1.2 s tap starve
    /// during a route transition — which is exactly what a route transition
    /// looks like — is enough to condemn the rest of the call.
    ///
    /// Only a ROUTE-driven restart is allowed to retry: the hardware conditions
    /// genuinely changed, so the previous starve says nothing about the new
    /// route. A watchdog-driven restart never retries, so the iPad W574f case
    /// (which starves on a STABLE route) keeps its fallback and cannot loop.
    /// Bounded at `maxVoiceProcessingRetries`, so the worst case is one extra
    /// 1.2 s starve window per call instead of ~110 s without AEC.
    static func shouldRetryVoiceProcessing(bypassCount: Int, restartIsRouteDriven: Bool) -> Bool {
        guard restartIsRouteDriven else { return false }
        return bypassCount > 0 && bypassCount <= maxVoiceProcessingRetries
    }

    /// W-TUNEGAP (2026-07-21) — extracted so this ONE contract has its own
    /// regression test (see `AudioCaptureAgcGateTests`), decoupled from the
    /// rest of `AudioCapture`'s hardware-dependent state (AVAudioEngine,
    /// VP-IO) so it runs on the macOS CI runner via `swift test` with no
    /// device or Xcode UI needed — same shape as
    /// `VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver` on
    /// the video side (same "hard-won fix, silently undone 4h later by an
    /// unrelated refactor" bug class). The specific regression this guards:
    /// the make-up AGC must NEVER be fully disabled by VP-IO being active —
    /// only its ceiling changes. If this ever needs to change (e.g. new
    /// telemetry justifies a different ceiling, or a real reason to disable
    /// it under VP-IO again), change this function AND its test together,
    /// deliberately — don't let a broader refactor touch the call site
    /// without also touching this.
    static func selectMakeUpAgcMaxGain(vpioActive: Bool) -> Float {
        vpioActive ? agcMaxGainVpio : agcMaxGain
    }

    /// Ceiling the make-up stage aims the loudest sample of a buffer at —
    /// i.e. the peak headroom the OPUS ENCODER is given.
    ///
    /// W-TXHEADROOM (2026-07-21) — 0.90 → 0.70 (−0.92 dBFS → −3.1 dBFS).
    ///
    /// WHY THIS IS A CODEC PARAMETER, NOT A LOUDNESS ONE. Opus is a lossy
    /// transform/predictive codec: its reconstruction is NOT bounded by its
    /// input. Feed it peaks at −0.9 dBFS and the decoder's float output
    /// routinely exceeds ±1.0, at which point libopus's own float→int16
    /// conversion (SATURATE16) HARD-CLIPS it. Hard clipping is broadband
    /// harmonic + intermodulation distortion, and it is produced at the
    /// RECEIVER, so it is invisible to every metric we already collect —
    /// loss 0 %, tx_enc_err 0, rx_dec_err 0 on the very calls that sound bad.
    /// That is exactly why "iOS-encoded audio sounds worse than Android's"
    /// survived many builds of investigation.
    ///
    /// MEASURED, not assumed (call d0f84651, iOS 1.0.828 ↔ Android a88d30f,
    /// one call so identical network for both directions):
    ///   iOS  TX peak 98 % / rms 6.0 %  →  Android decoded peak **100.003 %**
    ///        (= a sample at −32768, the int16 rail: libopus saturated)
    ///   Andr TX peak 35.2 % / rms 2.52 % →  iOS decoded peak 29.4 %
    /// Android reaches its encoder with 9.1 dB of headroom because it applies
    /// NO gain stage at all (`AudioCapture.kt`: VOICE_COMMUNICATION + HW
    /// NS/AEC, `disableSessionAgc()`, software gate 0.0). iOS reaches its
    /// encoder with 0.9 dB because Apple's VP-IO AGC and this make-up stage
    /// are cascaded. Same codec settings on both sides — the difference is
    /// entirely the level presented to it.
    ///
    /// WHY 0.70 AND NOT LOWER. Published true-peak overshoot for Opus-class
    /// codecs is ~1–3 dB, so −3.1 dBFS covers it. Working the same call
    /// backwards: raw post-VP-IO peak was 0.90/2.73 = 0.330, raw rms
    /// 6.0/2.73 = 2.20 %. At 0.70 the gain becomes 0.70/0.330 = 2.12, giving
    /// TX peak 70 % and TX rms 4.67 % — still 5.4 dB LOUDER than the Android
    /// leg that already sounds good, and 7.4 dB above the faint-mic
    /// regression 04f82f1/dcace27 exist to fix (call 40f6d641, rms 2.0 %).
    /// So the faint mic cannot come back; only the headroom changes.
    ///
    /// `agcTargetRms` is deliberately NOT touched in the same change — see its
    /// own note for why lowering it re-breaks the quiet mic.
    static let agcPeakHeadroom: Float = 0.70
    private static let agcAlphaRise: Float = 0.02    // slow lift  (τ ≈ 1 s)
    private static let agcAlphaFall: Float = 0.05    // RMS-driven duck (τ ≈ 400 ms)
    /// Most the gain may be cut in ONE buffer (0.708 ≈ −3 dB).
    /// Without a bound, a single full-scale outlier sample (a lip smack — real:
    /// call 4b8cacde logged exactly ONE such sample in a whole call) forces
    /// `agcPeakHeadroom / 1.0` and would duck the entire 20 ms buffer by ~9 dB,
    /// punching an audible hole. Bounded, an isolated outlier costs 3 dB for one
    /// buffer and recovers, while a GENUINE sustained level rise still converges
    /// in 1–3 buffers (20–60 ms) instead of the ~400 ms the old one-pole took.
    /// The soft-knee limiter backstops the residual during those buffers — which
    /// is exactly what a limiter is for, and is bounded to tens of ms per onset
    /// rather than being in-circuit continuously.
    static let agcMaxAttackStep: Float = 0.708
    /// Samples over which a gain DECREASE is ramped (≈1 ms at 48 kHz). A gain
    /// increase still ramps across the whole buffer. Fast-down/slow-up is the
    /// standard safe limiter shape and confines onset overshoot to ~1 ms.
    static let agcAttackRampSamples: Int = 48

    // ── Soft-knee limiter (shared by the inline make-up path and the standalone
    // raw-mic TX-LIMITER below, so the two stages can never drift apart).
    //
    // W-AGCCEIL (2026-07-21) — the knee was 0.90, EXACTLY equal to
    // `agcPeakHeadroom`. Two stages stacked on the same threshold overlap by
    // construction: the moment the AGC reached its own ceiling the limiter was
    // already at its knee, so the limiter was in-circuit continuously rather
    // than as a backstop. Because it is a MEMORYLESS waveshaper (per-sample
    // curve, no gain state), being continuously engaged means continuous
    // harmonic distortion — the reported "metallic" timbre. Raising the knee to
    // 0.95 puts 0.47 dB of clean separation above the AGC ceiling, so in steady
    // state the limiter is out of circuit entirely and only sees the ~1 ms
    // attack residual and upstream transients VP-IO already let through at full
    // scale (measured: peak_pct 100.0 on calls where our gain was 1.0).
    static let limiterKnee: Float = 0.95
    static let limiterCeiling: Float = 0.98

    /// W-AGCCEIL (2026-07-21) — the make-up AGC control law for ONE tap buffer,
    /// extracted pure so the peak-ceiling invariant has its own regression test
    /// (`AudioCaptureLevelControlTests`), same pattern as
    /// `selectMakeUpAgcMaxGain` / `IceTerminationPolicy` /
    /// `VideoTransceiverPhantomGuard`. No AVFoundation or WebRTC in the
    /// signature, so it runs on the macOS CI runner via `swift test`.
    ///
    /// Order matters and is the whole fix:
    ///   1. slow RMS-seeking term (voice-gated, boost-only) — unchanged;
    ///   2. HARD peak/headroom ceiling applied to the RESULT, not to the target.
    ///      This is the invariant that was documented but never enforced;
    ///   3. bounded attack, so step 2 cannot punch a hole on one outlier sample.
    /// Step 3 can hold the gain above the peak-safe value for a buffer or two;
    /// that is deliberate, and it is the ONLY case in which the limiter should
    /// ever engage on content we ourselves amplified.
    ///
    /// W-TXHEADROOM (2026-07-21) — step 2 may now take the gain BELOW unity,
    /// bounded at `agcPeakHeadroom`. The stage is still "boost-only" as a
    /// LOUDNESS stage (step 1 never asks for less than 1×); what it is no
    /// longer allowed to do is hand Opus a signal with no headroom just because
    /// something upstream — Apple's VP-IO AGC — already pushed it to the rail.
    /// See `agcPeakHeadroom` for the measured evidence.
    ///
    /// W-AGCNOISE (2026-07-21) — `noiseFloorRms` makes step 1's gate RELATIVE
    /// as well as absolute (see `shouldAdaptMakeUpGain`). It defaults to 0,
    /// which reproduces the pre-W-AGCNOISE gate exactly — that default exists
    /// so the existing regression tests keep asserting the same law; the live
    /// call site always passes the tracked floor.
    static func nextMakeUpAgcGain(previousGain: Float,
                                  bufferRms: Float,
                                  bufferPeak: Float,
                                  maxGain: Float,
                                  noiseFloorRms: Float = 0) -> Float {
        var gain = previousGain
        // 1. Only adapt when real voice is present; on silence/background HOLD
        //    the gain so hiss is never pumped up (VP-IO NS is off — W556).
        //    W-AGCNOISE — "real voice" now means "above the absolute silence
        //    floor AND at least agcSnrGateRatio above the tracked background".
        //    The absolute-only test held on a quiet-room floor but is wide open
        //    in a car with NS bypassed, which is how this loop came to wind to
        //    5.89× on road noise (call 1de9935f).
        if shouldAdaptMakeUpGain(bufferRms: bufferRms, noiseFloorRms: noiseFloorRms) {
            var desired = agcTargetRms / bufferRms
            if desired < 1 { desired = 1 }                   // boost-only
            if desired > maxGain { desired = maxGain }
            let alpha: Float = desired > gain ? agcAlphaRise : agcAlphaFall
            gain += (desired - gain) * alpha
        }
        // 2. Peak/headroom ceiling on the APPLIED gain. Note this runs even when
        //    the noise gate held the loop above: a loud transient arriving
        //    during an otherwise-quiet stretch must not be boosted just because
        //    the buffer's RMS was still under the gate.
        //
        //    W-TXHEADROOM (2026-07-21) — this clamp MAY now take the gain BELOW
        //    unity, which is the whole fix. The stage used to floor at 1.0
        //    ("boost-only"), so on the one input that actually needs the
        //    ceiling — a buffer VP-IO already handed us at or near full scale —
        //    the "hard peak ceiling" was completely inert and the signal went
        //    to Opus at full scale. Live proof that this is not hypothetical:
        //    across 07-13…07-20, with this stage disabled entirely (gain 1.0
        //    throughout), iOS still logged tx peak_pct 98.4/100/99.9/100/100 on
        //    calls 0712dd14/4b147452/2ce5f8f8/4b8cacde/40f6d641 — that is
        //    Apple's VP-IO AGC alone reaching the rail. Android never can:
        //    it runs no AGC at all.
        //
        //    This does NOT turn the stage into a downward compressor that could
        //    fight VP-IO's own loop. It is a per-buffer static clamp with no
        //    integrator below unity, and it is bounded by construction —
        //    peakSafe = agcPeakHeadroom / bufferPeak and bufferPeak ≤ 1, so the
        //    gain can never fall below `agcPeakHeadroom` itself (−3.1 dB). It
        //    removes exactly the amount by which the peak breaches the headroom
        //    target and nothing more, so it cannot hunt.
        var lowerBound: Float = 1
        if bufferPeak > 0 {
            let peakSafe = agcPeakHeadroom / bufferPeak
            if peakSafe < gain { gain = peakSafe }
            if peakSafe < lowerBound { lowerBound = peakSafe }
        }
        // 3. Bounded attack (see agcMaxAttackStep).
        //
        //    W-AGCNOISE (2026-07-21) — the ceiling clamp MOVED ABOVE the attack
        //    bound. It used to be the last statement, which was harmless while
        //    `maxGain` was a compile-time constant per route but is not now that
        //    it tracks the background floor: a floor rising into a noisy stretch
        //    can drop the ceiling from 6.0 to 1.0, and an unbounded final clamp
        //    would apply that −15.6 dB in a SINGLE 20 ms buffer — a step the
        //    1 ms de-zipper ramp turns into an audible click. Clamping first and
        //    then applying the same −3 dB/buffer attack bound makes a ceiling
        //    collapse decay geometrically instead (6.0 → 1.0 in 6 buffers,
        //    ~120 ms), which is inaudible.
        //
        //    This reordering is behaviour-IDENTICAL whenever `previousGain` ≤
        //    `maxGain` (then `attackFloor` = previousGain × 0.708 ≤ maxGain, so
        //    neither clamp can move the other's result), which is every case the
        //    existing tests exercise and every steady state. `attackFloor` is
        //    always strictly below `previousGain`, so it can never make the gain
        //    GROW past the ceiling — only descend to it at a bounded rate.
        if gain > maxGain { gain = maxGain }
        let attackFloor = previousGain * agcMaxAttackStep
        if gain < attackFloor { gain = attackFloor }
        if gain < lowerBound { gain = lowerBound }
        return gain
    }
    // TX-RMS (2026-07-12) — sum of squares + sample count for the mic RMS,
    // accumulated on the same 50fps tap callback as peakAmplitude (no lock,
    // no extra decode). `consumeLevelStats()` folds these into `rms` (in Int16
    // sample units) and resets them; CallService reports it as tx `rms_pct`.
    private var sumSqAmplitude: Double = 0
    private var rmsSampleCount: Int64 = 0
    /// Read the accumulated peak/clip/rms stats for the CURRENT call and reset
    /// them for the next one. Call from teardown, before `stop()` clears
    /// other per-call state. `rms` is in Int16 sample units (0…32767).
    /// `limiterPct` is the percentage of transmitted samples the soft-knee
    /// limiter actually shaped — the limiter's duty cycle. In steady state it
    /// should be ~0: the make-up AGC is capped at `agcPeakHeadroom` (0.70 since
    /// W-TXHEADROOM), well below the limiter knee (0.95), so the limiter should
    /// only ever catch the ~1 ms attack residual. Transients that arrive at full
    /// scale from VP-IO are now pulled down by the headroom clamp itself rather
    /// than left to the waveshaper. A persistently non-trivial value means the
    /// AGC is overdriving
    /// again — which is exactly the regression W-AGCCEIL fixed and which the
    /// old telemetry had no way to see.
    ///
    /// W-AGCNOISE (2026-07-21) — `agcGainMean`, `agcNoiseFloorPct`,
    /// `agcHoldPct` and `txBurstMax` are the instruments this loop never had.
    /// `agcGain` is a call-MAX and therefore has the same blind spot
    /// `peak_pct` has: it reads ~ceiling whether the loop touched the ceiling
    /// once or lived there. The mean gain is the number that distinguishes
    /// them, `agcHoldPct` says how much of the call the SNR gate classified as
    /// background, and `agcNoiseFloorPct` is the input this whole mechanism
    /// keys off — if the noise-floor model is wrong, that field says so.
    public struct LevelStats {
        public let peak: Int16
        public let clipSamples: Int64
        public let rms: Double
        public let agcGain: Float
        public let limiterPct: Double
        public let agcGainMean: Double
        public let agcNoiseFloorPct: Double
        public let agcHoldPct: Double
        public let txBurstMax: Int
        // W-IOSECHO — see `EchoBucketTotals` kdoc below.
        public let echoActiveFrames: Int64
        public let echoActiveRmsPct: Double
        public let echoIdleFrames: Int64
        public let echoIdleRmsPct: Double
    }

    // MARK: - W-IOSECHO (2026-07-22) — echo-cancellation effectiveness proxy

    /// RMS threshold (fraction of Int16 full scale) above which a decoded RX
    /// frame counts as "the far end was audible out of the transducer".
    /// Deliberately the SAME value as Android's
    /// `AudioPlayback.LOUD_PLAYOUT_RMS` (0.01 = 1 % FS) so the two platforms'
    /// `echo_active_*`/`echo_idle_*` telemetry is graded against the same
    /// yardstick and stays comparable in `tune-report.py`.
    static let echoRefLoudRms: Float = 0.01

    /// How long after the last "loud" RX frame the far end is still treated
    /// as "active" for echo grading. Mirrors Android's
    /// `SpeakerEchoSuppressor.DEFAULT_HOLD_MS` (200 ms): long enough to
    /// bridge a normal inter-syllable gap in the peer's speech without
    /// flapping the active/idle classification every frame, short enough
    /// that real silence (peer muted, peer stopped talking) is reclassified
    /// idle within a fraction of a second.
    static let echoRefHoldMs: Int64 = 200

    /// Whether the far end should be treated as "currently audible" for echo
    /// grading, given the last time a loud RX frame was scheduled for
    /// playback. Pure; unit-tested in `AudioCaptureEchoBucketTests`.
    static func isFarEndActive(lastLoudPlayoutAtMs: Int64, nowMs: Int64, holdMs: Int64 = echoRefHoldMs) -> Bool {
        guard lastLoudPlayoutAtMs > 0 else { return false }
        return nowMs - lastLoudPlayoutAtMs <= holdMs
    }

    /// Whether a decoded RX frame's RMS counts as "loud" for the
    /// far-end-active proxy above. Pure; unit-tested.
    static func isLoudPlayout(rms: Float, threshold: Float = echoRefLoudRms) -> Bool {
        rms >= threshold
    }

    /// One call's near-end-RMS-vs-far-end-activity split — the measurement
    /// iOS never had before W-IOSECHO. Two buckets of TX mic energy, summed
    /// as (per-buffer RMS)² so the aggregate is a true root-mean-square over
    /// the whole bucket rather than a mean of per-frame RMS values (energy
    /// adds; averaging RMS under-weights the loud frames that actually carry
    /// the echo — same reasoning as Android's `bucketRmsPct` kdoc):
    ///
    ///  - `active`: frames captured while the far end was recently audible
    ///    (`isFarEndActive` true) — an engaged AEC has real work to do here.
    ///  - `idle`: frames captured while it was not — near-silence is the
    ///    only honest expectation regardless of AEC state.
    ///
    /// On a canceler that is both ENABLED and EFFECTIVE the two buckets
    /// should be comparable (both are just room noise). An `active` bucket
    /// several times louder than `idle` is measured residual echo reaching
    /// the encoder — the number `vpio_ever_active`/`vpio_bypassed_ever` alone
    /// cannot supply, because Apple's VP-IO can be genuinely engaged and
    /// still not fully cancel a strong acoustic coupling (the speakerphone
    /// case this was built to investigate — see `speaker_ms`/
    /// `speaker_route_ever` alongside this field).
    ///
    /// HONEST LIMITATIONS (do not read this as an ERLE measurement):
    ///  - "far end audible" is a level-based proxy on the DECODED RX PCM,
    ///    not a hardware echo-return-loss measurement — no current iOS SDK
    ///    exposes a per-frame ERLE from the VP-IO unit via public API. A
    ///    loud RX frame does not prove the near-end mic picked up an
    ///    acoustic copy of it (an earpiece call has no acoustic coupling at
    ///    all — read this next to `speaker_route_ever`, not on its own).
    ///  - The mic frame graded runs on the same 20 ms tap cadence as the
    ///    callback, but there is no hard guarantee it is sample-aligned with
    ///    the specific RX frame that made the far end "loud" a moment
    ///    earlier — only that SOME far-end energy was recently audible. The
    ///    200 ms hold window is deliberately generous for exactly this
    ///    reason (matching Android's own hold, which has the same slack).
    ///  - Unlike Android's `SpeakerEchoSuppressor`, iOS runs no software
    ///    residual-echo suppression, so there is no `echo_gain_min`
    ///    equivalent to ship — Apple's VP-IO is the only canceler in the
    ///    chain and it is opaque past `setVoiceProcessingEnabled`. This
    ///    struct is purely a MEASUREMENT; it does not attenuate anything.
    struct EchoBucketTotals: Equatable {
        var activeSumSq: Double = 0
        var activeFrames: Int64 = 0
        var idleSumSq: Double = 0
        var idleFrames: Int64 = 0
    }

    /// Fold one buffer's RMS into the running totals. Pure; unit-tested.
    static func accumulatingEchoBucket(_ totals: EchoBucketTotals,
                                       frameRms: Float,
                                       farEndActive: Bool) -> EchoBucketTotals {
        var next = totals
        let sq = Double(frameRms) * Double(frameRms)
        if farEndActive {
            next.activeSumSq += sq
            next.activeFrames += 1
        } else {
            next.idleSumSq += sq
            next.idleFrames += 1
        }
        return next
    }

    /// Root-mean-square of one echo-leak bucket, as a percentage of full
    /// scale. Same formula as Android's `CallAudioBridge.bucketRmsPct` — RMS
    /// over the whole bucket, not a mean of per-frame RMS values (see
    /// `EchoBucketTotals` kdoc). Pure; unit-tested.
    static func bucketRmsPct(sumSq: Double, frames: Int64) -> Double {
        guard frames > 0 else { return 0 }
        return (sumSq / Double(frames)).squareRoot() * 100
    }

    /// Receive-side playout health. Every field below was already being
    /// counted and, until now, read by NOTHING — grep for `underruns` /
    /// `hardDrops` / `playoutConcealed` outside this file returned zero hits,
    /// so none of it ever reached a log line, let alone Loki. That made the
    /// iOS receiver the one leg of a call whose audio quality could not be
    /// measured at all: a user reporting choppy audio could not be confirmed
    /// or contradicted from telemetry (W-IOSAUDIOSTARVE, 2026-08-02).
    ///
    /// The counters discriminate between the two causes that look identical
    /// from the outside:
    ///   - starved CONSUMER — high `underruns` + high `concealed`, `depth`
    ///     normal or low. The render side could not keep up.
    ///   - bursty ARRIVAL — high `hardDrops` + `overruns`, `depth` spiking
    ///     toward capacity. Frames arrived clumped.
    /// `pushed` is the denominator; without it the drop counts cannot be read
    /// as a rate.
    public struct PlayoutStats: Sendable {
        public let pushed: Int64
        public let underruns: Int64
        public let overruns: Int64
        public let hardDrops: Int64
        public let silenceDrops: Int64
        public let concealed: Int
        public let depth: Int
        /// W-JBSTRETCH (2026-08-25) — pops satisfied by time-compression
        /// (`TimeStretch.compress`) instead of a whole-frame drop. High here
        /// with low `hardDrops` means jitter recovery mostly avoided the
        /// audible skip the excision tiers cost. In-process only for now,
        /// same as `silenceDrops` — see the CallService log line's own note
        /// on why a diagnostic field does not automatically get a wire slot.
        public let timeStretchFrames: Int64
        /// W-JBADAPT (2026-08-25) — the adaptive steady-state depth target
        /// in force when this snapshot was taken, in ms.
        public let adaptiveTargetMs: Int
    }

    /// Snapshot of [PlayoutStats]. Cheap (lock-guarded reads); safe from
    /// any thread. Cumulative for the call — the caller reports deltas.
    public var playoutStats: PlayoutStats {
        PlayoutStats(
            pushed: playoutJitter.pushed,
            underruns: playoutJitter.underruns,
            overruns: playoutJitter.overruns,
            hardDrops: playoutJitter.hardDrops,
            silenceDrops: playoutJitter.silenceDrops,
            concealed: playoutConcealed,
            depth: playoutJitter.depth,
            timeStretchFrames: playoutJitter.timeStretchFrames,
            adaptiveTargetMs: playoutJitter.adaptiveTargetMs,
        )
    }

    public func consumeLevelStats() -> LevelStats {
        let rms = rmsSampleCount > 0 ? (sumSqAmplitude / Double(rmsSampleCount)).squareRoot() : 0
        let limiterPct = rmsSampleCount > 0
            ? Double(limiterSampleCount) / Double(rmsSampleCount) * 100
            : 0
        let gainMean = micAgcBufferCount > 0
            ? micAgcGainSum / Double(micAgcBufferCount)
            : 1.0
        let holdPct = micAgcBufferCount > 0
            ? Double(micAgcHoldCount) / Double(micAgcBufferCount) * 100
            : 0
        let stats = LevelStats(peak: peakAmplitude,
                               clipSamples: clipSampleCount,
                               rms: rms,
                               agcGain: micAgcMaxGainThisCall,
                               limiterPct: limiterPct,
                               agcGainMean: gainMean,
                               agcNoiseFloorPct: Double(micAgcNoiseFloor) * 100,
                               agcHoldPct: holdPct,
                               txBurstMax: txBurstMaxThisCall,
                               echoActiveFrames: echoBucketThisCall.activeFrames,
                               echoActiveRmsPct: Self.bucketRmsPct(sumSq: echoBucketThisCall.activeSumSq,
                                                                   frames: echoBucketThisCall.activeFrames),
                               echoIdleFrames: echoBucketThisCall.idleFrames,
                               echoIdleRmsPct: Self.bucketRmsPct(sumSq: echoBucketThisCall.idleSumSq,
                                                                  frames: echoBucketThisCall.idleFrames))
        peakAmplitude = 0
        clipSampleCount = 0
        sumSqAmplitude = 0
        rmsSampleCount = 0
        limiterSampleCount = 0
        micAgcMaxGainThisCall = 1.0
        micAgcGainSum = 0
        micAgcBufferCount = 0
        micAgcHoldCount = 0
        txBurstMaxThisCall = 0
        echoBucketThisCall = EchoBucketTotals()
        // NOTE: micAgcNoiseFloor is deliberately NOT reset here — `start()`
        // owns that, so the value read above is the floor as it stood at
        // teardown rather than 0.
        return stats
    }
    // M-12 — AVAudioSession interruption (phone call, Siri, alarm)
    // handling. Without this the capture engine stays dead after an
    // interruption ends, silently killing call audio.
    private var interruptionObserver: NSObjectProtocol?
    private var wasInterrupted = false
    // W571 — route change observer (headset plug/unplug, Bluetooth connect/
    // disconnect). Without this, when a Bluetooth HFP device disconnects
    // the AVAudioEngine silently routes to the built-in speaker — correct
    // routing — but if the built-in microphone is at a different sample
    // rate or format the engine enters a degraded state: capture tap
    // continues on the old format → frame-size mismatches → Opus encode
    // errors or silence. Restarting the engine on route change ensures
    // the tap format matches the new hardware route.
    private var routeChangeObserver: NSObjectProtocol?

    // W574o — route-change anti-thrash. A flapping Bluetooth HFP link (and the
    // engine restart itself re-running AVAudioSession route selection) fired
    // new/oldDeviceAvailable several times per second; restarting on each one
    // thrashed the audio path so decrypted voice never played steadily (device
    // telemetry 1.0.658: route flapped BT↔built-in every ~1-2s while frames were
    // decrypting fine). Two purely time-based guards, no timers / no thread change:
    //   * throttle  — at most one route-driven restart per second;
    //   * suppress  — ignore the route change our OWN restart provokes (~0.6s),
    //                 which breaks the self-induced restart loop.
    private var lastEngineRestart: Date = .distantPast
    private var restartSuppressUntil: Date = .distantPast
    private let routeRestartThrottle: TimeInterval = 1.0

    // W-SPKFIX (2026-07-12) — in-call speaker toggle. `AppState.setSpeaker`
    // flips the OUTPUT route by adding `.defaultToSpeaker` to setCategory AND
    // calling overrideOutputAudioPort. On iOS 26 the *category* change fires a
    // route notification with reason `.categoryChange` (the override is then a
    // no-op → no `.override`), and handleRouteChange only rebuilt the engine on
    // `.override`/device cases — so `.categoryChange` fell through and the
    // engine was NEVER rebuilt for the new route. The single VP-IO/RemoteIO
    // graph's input tap silently dies when the underlying output route flips
    // out from under it: TX (mic) stopped the instant speaker was pressed and
    // never recovered (confirmed call 92dab394, v1.0.767 — RX kept flowing, TX
    // heartbeat froze at 250). Fix: detect the speaker<->earpiece flip
    // REASON-AGNOSTICALLY (compare the live route against the route the engine
    // was built for) and debounce-rebuild. A mid-call restart preserves the
    // route because pipeline.isConfigured stays true (only deactivateSession at
    // call end clears it) so start() skips configureForVoIP and does NOT reset
    // the speaker category.
    private var engineBuiltForSpeaker = false
    private var pendingRouteRestart: DispatchWorkItem?

    // ── W-AUDIORESUME / W-MEDIARESET / W-AUDIOBEACON (2026-09-01) ──────────
    // Evidence: audit memory reference_ios_stability_audit_2026_09_01, P1
    // (1)/(2) — background audio loss with the process alive for 80 s and no
    // shipped line able to say whether the engine was running; `.ended`
    // without `.shouldResume` never resumed; mediaServicesWereReset unhandled.
    // Decisions live in `AudioInterruptionRecoveryPolicy` (pure, tested);
    // this file only owns the timers/notifications and funnels every
    // recovery through the existing `start()` / `restartEngineForRoute`.

    /// Who owns the session this capture runs under. `.passive` (default)
    /// keeps every pre-existing behaviour for enrollment / unlock / group
    /// fallback captures; `CallService` sets `.voiceCall` on its 1:1 capture.
    public var sessionOwnership: AudioInterruptionRecoveryPolicy.SessionOwnership = .passive
    /// The armed resume retry of the bounded 1 s / 3 s ladder. Cancelled by
    /// a new `.began`, by `stop()`, and consumed by its own run.
    private var pendingResumeRetry: DispatchWorkItem?
    private var mediaServicesResetObserver: NSObjectProtocol?
    /// Engine-state beacon timer (main queue). nil = not armed.
    private var stateBeaconTimer: DispatchSourceTimer?
    /// Monotonic ms of the last tap buffer / of the last frame handed to the
    /// player node; 0 = never. `lastMicFrameAtMs` is written on the tap
    /// thread and read on main — the same single-writer benign race this
    /// file already accepts for `lastLoudPlayoutAtMs` (a diagnostic counter,
    /// never a correctness input). `lastPlayoutFrameAtMs` is main-only.
    /// Deliberately NOT reset by `start()`: an engine rebuild that never
    /// delivers a frame must show the age still growing.
    private var lastMicFrameAtMs: Int64 = 0
    private var lastPlayoutFrameAtMs: Int64 = 0

    /// Initialize with an optional audio processing pipeline.
    /// When provided, the pipeline configures AVAudioSession for VoIP and
    /// enables Apple's Voice Processing I/O (hardware AEC, NS, AGC) on the
    /// input node before capturing begins.
    public init(audioPipeline: AudioProcessingPipeline? = nil) {
        self.audioPipeline = audioPipeline ?? AudioProcessingPipeline()
    }

    /// W-GRPVPIO-CRASH-4 — set by the 1:1 CallService on ITS capture instance
    /// (never on the group-call controller's own capture). When it returns
    /// true, a LiveKit group call currently owns the hardware VP-IO audio
    /// unit, and this 1:1 engine MUST NOT start: `enableVoiceProcessing` →
    /// `setVoiceProcessingEnabled(true)` would make AVFAudio raise an
    /// Objective-C `NSException` from `AVAudioEngineGraph::_Connect` (the
    /// hardware unit is already claimed), which Swift's `try` cannot catch →
    /// SIGABRT (crashPointId B4lMk7amGdH7pnGoa5qsYT). The v807 fix guarded the
    /// two CallService *entry* chokepoints, but `AudioCapture` self-restarts
    /// through its OWN route-change / interruption observers + starve watchdog
    /// (all funnel back through `start()`), bypassing those app-layer guards —
    /// so the gate has to live HERE, at the single funnel. Left nil on the
    /// group-call controller's capture so the WS-relay group fallback (which
    /// legitimately owns VP-IO itself) is unaffected.
    public var isGroupCallActive: (() -> Bool)?

    public func start() throws {
        guard !isRunning else { return }
        // W-GRPVPIO-CRASH-4 — refuse to (re)build the 1:1 engine while a group
        // call owns VP-IO. Covers every restart path (route change,
        // interruption resume, starve watchdog) that funnels through start(),
        // not just the CallService entry points the v807 guard covered.
        if isGroupCallActive?() == true {
            print("[AudioCapture] start SKIPPED — group call owns VP-IO (LiveKit); refusing 1:1 engine to avoid setVoiceProcessingEnabled SIGABRT")
            return
        }
        // W475 — start each capture session with an empty re-chunk
        // accumulator so a stale partial frame from a prior call or a
        // pre-interruption session can't desync the frame boundaries.
        pcmAccumulator = Data()
        firstFrameReceived = false  // W-AEC-FIX — re-arm the VP-IO starve watchdog
        micAgcGain = 1.0            // W-MICAGC — start each call at unity gain
        micAgcMaxGainThisCall = 1.0
        micAgcRampFrom = 1.0        // W-DEZIPPER — reset the per-sample gain-ramp state
        // W-AGCNOISE — re-seed the background estimate on every engine (re)start.
        // A route change means new acoustics AND a new mic; carrying the old
        // floor across would apply a car cabin's ceiling to a built-in mic (or
        // the reverse) until the follower caught up. 0 = "unknown", which
        // `nextNoiseFloor` seeds from the first buffer.
        micAgcNoiseFloor = 0

        // 1. Configure AVAudioSession for VoIP (hardware AEC, AGC, NS)
        if !audioPipeline.isActive {
            try audioPipeline.configureForVoIP()
        }

        // 2. Create the audio engine
        let engine = AVAudioEngine()

        // force-unwrap safe: AVAudioFormat(commonFormat:sampleRate:channels:
        // interleaved:) only returns nil for an invalid sample-rate/channel
        // combination. AudioConstants.sampleRate/channels are fixed app
        // constants (48kHz mono) — a thoroughly standard, always-valid combo.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioConstants.sampleRate),
            channels: AVAudioChannelCount(AudioConstants.channels),
            interleaved: true
            // swiftlint:disable:next force_unwrapping
        )!

        // SINGLE-ENGINE FIX — attach + connect the PLAYBACK player node on the
        // SAME engine that owns the capture tap, BEFORE engine.start(), so the
        // one RemoteIO/VPIO unit drives both mic-in and speaker-out.
        // W-CANONICAL (2026-07-12) — moved BEFORE setVoiceProcessingEnabled:
        // Apple's documented silent-failure mode is enabling VP-IO on an engine
        // whose output side has no render chain yet (AEC gets no reference →
        // echo / severely quiet output, a plausible W574f contributor). The
        // player→mainMixer connection gives VP-IO its AEC reference from the
        // moment it is enabled. (The mixer resamples; the canonical Int16/48k
        // connection format stays valid whatever VP-IO negotiates underneath.)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // 3. Enable Voice Processing I/O on the input node BEFORE installing the tap.
        //    This activates Apple's full VoIP DSP chain:
        //    - Echo cancellation (AEC)
        //    - Noise suppression (NS)
        //    - Automatic gain control (AGC)
        try audioPipeline.enableVoiceProcessing(on: engine)
        // W-CANONICAL — latch the per-ENGINE-INSTANCE VP decision. The tap and
        // the custom-DSP bypass below key off THIS captured value, never off
        // live session/global state, so a mid-call watchdog flip can't desync
        // the "who owns AGC" decision (double-AGC risk) for buffers already in
        // flight on the old engine (each rebuild captures its own fresh value).
        let vpioActiveThisEngine = audioPipeline.voiceProcessingIsActive

        // 4. Install the input tap to capture PCM frames
        let inputNode = engine.inputNode

        // W574k — the tap format MUST match the input node's REAL output bus
        // format. Voice Processing I/O runs the input node as Float32 (and on
        // a warm engine / 2nd call it's already negotiated), so passing our
        // hardcoded Int16 `format` made installTap throw
        //   "Failed to create tap due to format mismatch, <…1 ch, 48000 Hz, Int16>"
        // → NSException → SIGABRT. That hit BOTH startCall and
        // activateIncomingCallAudio (both call start()), so the iPad crashed
        // whether it dialled OR answered. The tap callback below already
        // converts Float32→Int16, so feeding it the node's native format is
        // safe; fall back to our canonical format only if the node reports an
        // invalid (0-channel / 0-Hz) format before the engine is prepared.
        let nodeFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat: AVAudioFormat = (nodeFormat.channelCount > 0 && nodeFormat.sampleRate > 0)
            ? nodeFormat
            : format
        // W-CANONICAL — report the REAL post-enable tap format to telemetry
        // (call.audio.diag tap_sr/tap_ch): a tap_sr ≠ 48000 is exactly the
        // route/rate class behind the W556 "metallica e scattosa" artifact,
        // now handled by the converter below but kept visible per call.
        audioPipeline.noteTapFormat(sampleRate: tapFormat.sampleRate,
                                    channels: Int(tapFormat.channelCount))

        // W-CANONICAL — the missing resampler. The TX chain assumed 48 kHz all
        // the way to Opus (the W475 re-chunker slices by BYTE COUNT and
        // OpusCodec is pinned at 48 kHz), but nothing ever converted the tap's
        // real rate: any route granting ≠48 kHz (Bluetooth HFP 16 k, some
        // headsets 24/44.1 k) fed wrong-rate samples into a 48 k encoder →
        // pitch/tempo warp + aliasing ("metallica") and buffer-size mismatch
        // ("scattosa"). This AVAudioConverter — rebuilt on EVERY engine
        // (re)start from the freshly-read post-enable tap format — makes that
        // whole failure class structurally impossible: the accumulator only
        // ever sees canonical 48 kHz / mono / Int16. nil on the (typical)
        // built-in-mic path where the tap is already at the canonical rate —
        // the fast paths below stay allocation-identical to before.
        let needsConversion = tapFormat.sampleRate != Double(AudioConstants.sampleRate)
            || tapFormat.channelCount != AVAudioChannelCount(AudioConstants.channels)
        let rateConverter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: tapFormat, to: format)
            : nil
        if needsConversion {
            let msg = "[AudioCapture] W-CANONICAL: tap format \(Int(tapFormat.sampleRate)) Hz/\(tapFormat.channelCount)ch ≠ canonical 48000/1 — AVAudioConverter engaged"
            print(msg)
        }

        // W-AEC-FIX — VP-IO input-pull. When Voice-Processing I/O is active the
        // inputNode tap STARVES on iPad + builtInSpeaker (the duplex VP-IO unit
        // doesn't pull the mic when the inputNode has no downstream consumer —
        // only a tap; "callback never fires", W574f). Route inputNode → a MUTED
        // sink mixer → mainMixer so the engine actively pulls the mic (keeping
        // the tap alive) with NO local loopback (sink outputVolume = 0; the only
        // thing reaching the speaker is the remote audio via the player node,
        // which is exactly the VP-IO AEC reference). Gated on VP-IO active — the
        // no-VP-IO path already taps fine and is left byte-for-byte unchanged.
        if audioPipeline.voiceProcessingIsActive {
            let sink = AVAudioMixerNode()
            engine.attach(sink)
            engine.connect(inputNode, to: sink, format: tapFormat)
            sink.outputVolume = 0
            engine.connect(sink, to: engine.mainMixerNode, format: tapFormat)
            self.inputSink = sink
        }

        // W-LONGAUDIO (2026-08-10) — this stays at the 20 ms constant on EVERY
        // profile, deliberately, and that is what keeps iOS out of a whole class
        // of retuning bug.
        //
        // The mic DSP downstream of this tap — the make-up AGC, the noise-floor
        // follower (`nextNoiseFloor`, τ ≈ 25 s "at 50 fps"), the limiter — has
        // per-BUFFER time constants, calibrated against this cadence. On Android
        // the equivalent constants are per Opus FRAME, so a 60 ms profile moves
        // every one of them and each has to be re-derived. Here the tap cadence
        // and the Opus frame size are already separate concerns: `rechunkAndEmit`
        // accumulates whatever the tap delivers into exact encoder frames, which
        // is the job it was written for. Asking the tap for 2880 samples would
        // couple them for no benefit and silently stretch every DSP time
        // constant by 3x on a long call.
        //
        // (It is a hint either way — VP-IO ties the real buffer to the hardware
        // I/O duration and ignores this value entirely.)
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(AudioConstants.samplesPerFrame), format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.firstFrameReceived = true  // W-AEC-FIX — VP-IO tap is delivering
            self.lastMicFrameAtMs = Self.monotonicNowMs()  // W-AUDIOBEACON — one store, no other work on this thread
            guard var raw = self.convertTapBufferToInt16(buffer, rateConverter: rateConverter, canonicalFormat: format) else { return }
            self.updateEchoBucket(rawPcm: raw)
            if Self.micAgcEnabled {
                self.applyMicMakeUpAgc(rawPcm: &raw, vpioActiveThisEngine: vpioActiveThisEngine)
            }
            self.recordLevelDiagnostics(rawPcm: raw)
            if !vpioActiveThisEngine {
                self.applyRawMicTxLimiter(rawPcm: &raw)
            }
            self.rechunkAndEmit(rawPcm: raw)
        }

        // 5. Start the engine, then the player node (single engine drives both).
        engine.prepare()
        try engine.start()
        player.play()
        self.engine = engine
        self.playerNode = player
        self.playFormat = format
        isRunning = true
        // W-SPKFIX — record which output route (speaker vs earpiece) this engine
        // instance was built on, so handleRouteChange can detect a later
        // speaker<->earpiece flip reason-agnostically and rebuild.
        engineBuiltForSpeaker = AudioProcessingPipeline.currentRouteHasBuiltInSpeaker()

        // 6. M-12 — observe AVAudioSession interruptions so we can
        //    pause on .began and resume on .ended (.shouldResume).
        registerInterruptionObserver()
        // W-AUDIOBEACON — periodic engine-state line while a voice-call
        // capture is alive (no-op for .passive owners; no-op if already armed
        // by a previous start() of this same call).
        armStateBeaconIfNeeded()

        // 7. W-AEC-FIX — if VP-IO is active, arm the starve watchdog. If the
        //    input tap never delivers a buffer within the window (the iPad
        //    VP-IO + builtInSpeaker starve, W574f), restart WITHOUT VP-IO so the
        //    mic transmits. Worst case = the pre-fix behaviour (echo, working
        //    TX); never a dead mic. iPhone / no-VP-IO never arms it.
        if audioPipeline.voiceProcessingIsActive {
            scheduleVpioStarveWatchdog()
        }
    }

    /// W-AEC-FIX — VP-IO input-tap starve detector. The iPad's VP-IO + built-in
    /// speaker route can leave the inputNode tap callback completely silent
    /// (W574f). If no buffer has arrived 1.2 s after start, fall back to a
    /// no-VP-IO restart so the call still has a live mic (echo returns, but a
    /// working call beats a dead one). One-shot per start(); a delivering tap
    /// (firstFrameReceived) cancels it.
    private func scheduleVpioStarveWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.isRunning else { return }
            if self.firstFrameReceived { return }  // VP-IO tap is delivering — keep AEC
            print("[AudioCapture] W-AEC-FIX: VP-IO input tap starved (no frame in 1.2s) — restarting without VP-IO so the mic transmits")
            self.audioPipeline.forceDisableVoiceProcessing = true
            self.restartEngineForRoute()
        }
    }

    /// SINGLE-ENGINE FIX — schedule a decoded PCM frame for playback on the
    /// player node that lives on THIS capture engine. Replaces the old separate
    /// `AudioPlayback`, which ran a SECOND AVAudioEngine and was therefore mute.
    public func playFrame(_ pcmData: Data) {
        // W-IOSECHO (2026-07-22) — update the "far end recently audible"
        // proxy the mic-tap callback reads to grade echo-cancellation
        // effectiveness (see `EchoBucketTotals` above). Cheap Σx² scan on
        // the decoded PCM already in hand (mirrors the AGC-DIAG TX-side
        // scan). Deliberately runs before the guards below: "did the far end
        // send loud audio" is true the moment this frame arrived, regardless
        // of whether IT specifically ends up audible (engine not running,
        // format mismatch, etc.) — the mic can still be hearing the room's
        // response to the frames that DID play a moment earlier.
        if pcmData.count >= 2 {
            let n = pcmData.count / 2
            let frameRms: Float = pcmData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Float in
                guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return 0 }
                var sumSq: Double = 0
                for i in 0..<n {
                    let s = Double(samples[i]) / Double(Int16.max)
                    sumSq += s * s
                }
                return Float((sumSq / Double(n)).squareRoot())
            }
            if Self.isLoudPlayout(rms: frameRms) {
                lastLoudPlayoutAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
        }
        // W-IOSJITTER wiring (2026-07-26) — from here the frame goes into the
        // playout jitter buffer instead of straight onto the player node.
        //
        // What it replaces: `playFrame` scheduled EVERY arriving frame immediately.
        // `AVAudioPlayerNode` accepts them all, so frames arriving faster than
        // realtime became unbounded standing latency, frames arriving slower left the
        // node with nothing and the hole was plain silence, and nothing counted
        // either way. That is why every iOS leg on the tuning card shows `X` for
        // stalls, drops, PLC and playout rate while the Android leg on the SAME call
        // reports real numbers — iOS was not healthy, it was unmeasured.
        //
        // The pump below is self-clocking off the buffer-consumed completion handler,
        // which the in-flight ledger already had wired. Nothing here has control
        // authority over the engine: if a handler never fires, the pump stalls at the
        // in-flight target and frames queue in OUR buffer, where the emergency tier
        // bounds the backlog — the failure mode is bounded latency, not a dead call.
        //
        // W-LONGAUDIO (2026-08-10) — take the playout geometry from THIS frame.
        //
        // The frame is decoded PCM, so its duration is arithmetic, not a guess:
        // 48 kHz mono Int16 is 96 bytes per ms. Every watermark downstream is a
        // duration, and sizing them from what we ENCODE (which is what
        // `AudioPlayback` did, and what this path inherited) means the receiver's
        // buffer geometry is chosen by the transmitter's profile — wrong in
        // exactly the asymmetric case the negotiation cannot rule out.
        //
        // No negotiation state is consulted, deliberately: this is correct on an
        // endpoint that never negotiated anything.
        noteInboundFrameDuration(pcmBytes: pcmData.count)
        playoutJitter.push(pcmData)
        // W-PLAYOUTRACE (2026-07-26) — hop to main BEFORE touching the engine.
        //
        // Live incident, first call on a build carrying this pump: user tapped the
        // in-call speaker button and the phone froze. Root cause, found by reading
        // rather than guessing: `pumpPlayout` was called from TWO places on two
        // DIFFERENT, unsynchronized threads — inline here (whatever thread decrypts
        // network audio) and again inline inside `scheduleBuffer`'s OWN completion
        // handler, which AVFoundation fires on an internal thread that is neither
        // this one nor main. Both paths read/wrote `self.engine`/`self.playerNode`
        // with zero lock. `restartEngineForRoute` — which a speaker tap triggers via
        // `.override` — tears the SAME two properties down and rebuilds them, also
        // unsynchronized, on the main queue (`scheduleDebouncedRouteRestart`'s
        // `DispatchQueue.main.asyncAfter`). A teardown landing mid-schedule raced an
        // AVAudioEngine object that Apple does not document as safe for concurrent
        // configuration and scheduling from different threads — and it also meant
        // `scheduleBuffer` could be called REENTRANTLY, from inside its own
        // completion callback, which is its own known hazard independent of the race.
        //
        // The fix is not a lock. It is giving `engine`/`playerNode` exactly ONE
        // owning thread — main, since that is where `restartEngineForRoute` already
        // runs on its primary (debounced, i.e. every real route flip including this
        // one) path — and moving every entry point into the pump onto it. See the
        // completion handler below for the other half.
        DispatchQueue.main.async { [weak self] in
            self?.pumpPlayout()
        }
    }

    // MARK: - Tap callback stages
    //
    // Extracted from the installTap closure in start() (2026-07-28) so that
    // closure's own cyclomatic complexity / body length stop being counted
    // against start() itself (SwiftLint measures a closure's contents as part
    // of its enclosing function). Pure code motion — every line below is
    // unchanged from what used to run inline in the closure, in the same
    // order, on the same tap-callback thread. `raw` (the tap buffer,
    // progressively transformed by each stage) is threaded through via
    // `inout` rather than returned, so Data's copy-on-write never triggers an
    // extra copy across stage boundaries.

    /// W574 / W-CANONICAL — convert one delivered tap buffer to canonical
    /// Int16 PCM, resampling via `rateConverter` when the tap's native
    /// rate/channel layout differs from 48 kHz/mono (BT HFP 16 k, some
    /// headsets 24/44.1 k — the W556 "metallica e scattosa" warp class).
    /// Returns nil on any of the early-return cases the original closure had
    /// (conversion error, empty output, no usable channel data) — the caller
    /// must skip the rest of the tap callback for this buffer exactly as
    /// before.
    private func convertTapBufferToInt16(_ buffer: AVAudioPCMBuffer,
                                         rateConverter: AVAudioConverter?,
                                         canonicalFormat: AVAudioFormat) -> Data? {
        if let converter = rateConverter {
            let ratio = Double(AudioConstants.sampleRate) / max(buffer.format.sampleRate, 1)
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 64)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else { return nil }
            var fed = false
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let int16Data = outBuf.int16ChannelData, outBuf.frameLength > 0 else { return nil }
            return Data(bytes: int16Data[0], count: Int(outBuf.frameLength) * 2)
        } else if let int16Data = buffer.int16ChannelData {
            return Data(bytes: int16Data[0], count: Int(buffer.frameLength) * 2)
        } else if let floatData = buffer.floatChannelData {
            let count = Int(buffer.frameLength)
            var int16Buf = [Int16](repeating: 0, count: count)
            let src = floatData[0]
            for idx in 0..<count {
                let clamped = max(-1.0 as Float, min(1.0 as Float, src[idx]))
                int16Buf[idx] = Int16(clamped * Float(Int16.max))
            }
            return int16Buf.withUnsafeBytes { Data($0) }
        } else {
            return nil
        }
    }

    /// W-IOSECHO (2026-07-22) — echo-effectiveness proxy (iOS port of
    /// Android's W-SPKAEC/W-SPKECHO echo_active/idle buckets). Grades this
    /// frame's RAW mic RMS — post-hardware VP-IO AEC/NS/AGC if any, PRE our
    /// own software make-up gain — against whether the far end was recently
    /// audible out of the transducer. Runs unconditionally (not gated on
    /// micAgcEnabled or VP-IO state) so it always measures the true
    /// unprocessed near-end level, same as Android grades its raw capture
    /// frame before its own software residual suppressor. See
    /// `EchoBucketTotals` above for the full rationale and honest
    /// limitations.
    private func updateEchoBucket(rawPcm raw: Data) {
        raw.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let samples = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            let sampleCount = raw.count / 2
            guard sampleCount > 0 else { return }
            var echoSumSq: Double = 0
            for idx in 0..<sampleCount {
                let s = Double(samples[idx]) / Double(Int16.max)
                echoSumSq += s * s
            }
            let frameRms = Float((echoSumSq / Double(sampleCount)).squareRoot())
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let farEndActive = Self.isFarEndActive(lastLoudPlayoutAtMs: self.lastLoudPlayoutAtMs, nowMs: nowMs)
            self.echoBucketThisCall = Self.accumulatingEchoBucket(self.echoBucketThisCall,
                                                                   frameRms: frameRms,
                                                                   farEndActive: farEndActive)
        }
    }

    /// W-MICAGC — gentle make-up AGC. Runs in BOTH modes: VP-IO off (we own
    /// leveling entirely, ceiling agcMaxGain=6.0) and VP-IO on (rides on top
    /// of Apple's own AGC with a LOWER ceiling, agcMaxGainVpio=3.0, to bound
    /// any double-AGC interaction — still boost-only + noise-gated + slow
    /// one-pole + de-zippered + peak-headroom clamped, so it cannot pump).
    ///
    /// W-TUNEGAP (2026-07-20) — RESTORED. This dual-mode gate shipped in
    /// 04f82f1 (2026-07-12 19:17) after real telemetry (call c4185402)
    /// proved Apple's VP-IO AGC alone leaves the iOS mic at only ~11% peak
    /// vs Android's ~71% ("faint"). The SAME DAY at 23:32, commit a542727's
    /// broader "canonical VP-IO everywhere" refactor silently re-gated this
    /// to `!vpioActiveThisEngine` (VP-IO-off only) as a side effect of its
    /// "retire custom DSP to fallback only" policy — re-asserting, without
    /// new evidence, the very "Apple's AGC alone is enough" assumption
    /// 04f82f1 had just disproven. Real call 40f6d641 (2026-07-20)
    /// reproduced exactly the predicted regression: agc_ever_active=true,
    /// vpio_ever_active=true, yet tx rms_pct=2% (Android decoded the exact
    /// same 2% on its end — confirmed no transport/decode loss, this is
    /// genuinely how quiet the transmitted signal was), far below the
    /// "healthy 5-15%" band a542727's own commit message set as its target.
    /// `vpioActiveThisEngine` is the per-engine-instance latch captured
    /// right after setVoiceProcessingEnabled — never live global state — so
    /// the ceiling selection can't desync mid-call (double-AGC risk) for
    /// buffers already in flight on a prior engine.
    ///
    /// Caller gates this on `Self.micAgcEnabled` (the killswitch) exactly as
    /// the original inline code did — kept at the call site rather than
    /// inside here so the "AGC disabled entirely" case is visible at the
    /// tap-callback level, not buried inside this method.
    private func applyMicMakeUpAgc(rawPcm raw: inout Data, vpioActiveThisEngine: Bool) {
        let configuredMaxGain = Self.selectMakeUpAgcMaxGain(vpioActive: vpioActiveThisEngine)
        raw.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) in
            guard let samples = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            let n = rawBuf.count / 2
            guard n > 0 else { return }
            let fs = Float(Int16.max)
            var sumSq: Double = 0
            var peak: Float = 0
            for i in 0..<n {
                let s = Float(samples[i]) / fs
                sumSq += Double(s * s)
                let a = abs(s)
                if a > peak { peak = a }
            }
            let rms = Float((sumSq / Double(n)).squareRoot())
            // W-AGCCEIL — the whole control law now lives in the pure,
            // unit-tested `nextMakeUpAgcGain` (peak ceiling enforced on
            // the APPLIED gain + bounded attack). Keeping it out of this
            // closure is deliberate: this is the exact code a broad
            // refactor edited by accident once already.
            // W-AGCNOISE — track the background floor from the RAW
            // (pre-gain) buffer RMS, then let it bound the ceiling. The
            // gain multiply below has not run yet on these samples, so
            // this really is the input level and not our own output.
            self.micAgcNoiseFloor = Self.nextNoiseFloor(previous: self.micAgcNoiseFloor,
                                                        bufferRms: rms)
            let noiseFloor = self.micAgcNoiseFloor
            let maxGain = Self.noiseLimitedMaxGain(configuredMaxGain: configuredMaxGain,
                                                   noiseFloorRms: noiseFloor)
            if !Self.shouldAdaptMakeUpGain(bufferRms: rms, noiseFloorRms: noiseFloor) {
                self.micAgcHoldCount &+= 1
            }
            self.micAgcGain = Self.nextMakeUpAgcGain(previousGain: self.micAgcGain,
                                                     bufferRms: rms,
                                                     bufferPeak: peak,
                                                     maxGain: maxGain,
                                                     noiseFloorRms: noiseFloor)
            self.micAgcGainSum += Double(self.micAgcGain)
            self.micAgcBufferCount &+= 1
            if self.micAgcGain > self.micAgcMaxGainThisCall { self.micAgcMaxGainThisCall = self.micAgcGain }
            // W-DEZIPPER — apply the make-up gain with PER-SAMPLE ramping
            // from the previous frame's end gain, so the gain is
            // CONTINUOUS across the 20 ms frame boundary. A constant
            // per-frame gain that changed frame-to-frame stepped the
            // waveform at each boundary → an audible click every frame
            // (the "scoppiettante" crackle).
            //
            // W-AGCCEIL (2026-07-21) — CORRECTION to the note that used
            // to live here. It claimed "peak safety is now a per-sample
            // SOFT-KNEE applied inline", i.e. it treated the limiter as
            // the peak-safety mechanism. That is precisely the design
            // error: a memoryless waveshaper is a BACKSTOP, not a
            // leveller, and using it as one means it is in circuit
            // continuously (measured: post-gain peaks driven to
            // 1.045–1.251 × full scale on every call) and therefore
            // generating continuous harmonic distortion — the far end's
            // "metallic" report. Peak safety now lives where it belongs,
            // in the gain law (`nextMakeUpAgcGain`, ceiling enforced on
            // the APPLIED gain); the knee below sits ABOVE that ceiling
            // and should essentially never fire. `limiter_pct` telemetry
            // measures whether that is actually true in the field.
            let gStart = self.micAgcRampFrom
            let gTarget = self.micAgcGain
            // W-TXHEADROOM-DEAD (2026-07-21) — this guard used to read
            // `gTarget > 1.001 || gStart > 1.001`, i.e. "only do work
            // when we are BOOSTING". That silently made the entire
            // W-TXHEADROOM attenuation half DEAD CODE in exactly the
            // case it was written for: once the peak clamp settles the
            // gain at `agcPeakHeadroom` (0.70), BOTH gStart and gTarget
            // are ≤ 1.001 forever, the multiply loop below never runs,
            // and 0 dB is applied where −3.1 dB was intended. Caught by
            // adversarial review, then reproduced here: 8 consecutive
            // buffers computed gain 0.7080/0.7071/0.7071… and applied
            // 1.0000 every time.
            //
            // Second-order damage from the same bug: `micAgcRampFrom`
            // is assigned `gTarget` unconditionally after this block, so
            // it recorded 0.707 while the samples had actually been
            // multiplied by 1.0 — the de-zipper's start point desynced
            // from reality and the next buffer that DID engage ramped
            // from a wrong value, producing precisely the click
            // W-DEZIPPER exists to prevent.
            //
            // The predicate is now "does the gain differ from unity in
            // EITHER direction", which is the actual condition for
            // needing to touch the samples.
            if abs(gTarget - 1) > 0.001 || abs(gStart - 1) > 0.001 {
                // W-AGCCEIL — asymmetric ramp. A gain INCREASE is still
                // spread across the whole buffer (slow, inaudible). A
                // gain DECREASE completes in ~1 ms so a level jump is met
                // almost immediately: the old symmetric full-buffer ramp
                // meant a peak arriving early in the buffer was still
                // multiplied by the PREVIOUS (too high) gain, so the
                // limiter ate the whole onset.
                let rampSamples = gTarget < gStart ? min(n, Self.agcAttackRampSamples) : n
                let inv: Float = 1 / Float(rampSamples)
                let limThresh: Float = Self.limiterKnee * fs
                let limCeil: Float = Self.limiterCeiling * fs
                let limRange: Float = limCeil - limThresh
                var limited: Int64 = 0
                for i in 0..<n {
                    let t: Float = i < rampSamples ? Float(i) * inv : 1
                    let gi = gStart + (gTarget - gStart) * t
                    var v = Float(samples[i]) * gi
                    let mag = abs(v)
                    if mag > limThresh {
                        let excess = mag - limThresh
                        let comp = limThresh + limRange * (1 - exp(-excess / limRange))
                        v = (v < 0 ? -1 : 1) * comp
                        limited &+= 1
                    }
                    samples[i] = Int16(clamping: Int(v.rounded()))
                }
                self.limiterSampleCount &+= limited
            }
            self.micAgcRampFrom = gTarget
        }
    }

    /// AGC-DIAG — scan the samples we already have in hand (no extra
    /// decode) for peak amplitude + near-full-scale clip count. `raw` is
    /// exactly the int16 bytes about to be re-chunked next.
    private func recordLevelDiagnostics(rawPcm raw: Data) {
        raw.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let samples = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            let n = raw.count / 2
            var localPeak = self.peakAmplitude
            var localClips = self.clipSampleCount
            var localSumSq = self.sumSqAmplitude
            for i in 0..<n {
                // Int32 magnitude — avoids the abs(Int16.min) overflow trap.
                let mag = Int32(samples[i]).magnitude
                if mag > Int32(localPeak).magnitude { localPeak = Int16(clamping: mag) }
                if mag >= Int32(Self.clipThreshold).magnitude { localClips += 1 }
                // TX-RMS — sum of squares of the same samples (Double avoids
                // Int overflow over a full call); RMS is derived at consume time.
                let sq = Double(samples[i])
                localSumSq += sq * sq
            }
            self.peakAmplitude = localPeak
            self.clipSampleCount = localClips
            self.sumSqAmplitude = localSumSq
            self.rmsSampleCount &+= Int64(n)
        }
    }

    /// TX-LIMITER (2026-07-11) — soft-knee peak limiter on the raw mic
    /// samples before they reach Opus. W-CANONICAL (2026-07-12): runs ONLY
    /// on the raw-mic fallback path (VP-IO off) — caller gates on
    /// `!vpioActiveThisEngine` exactly as the original inline code did. With
    /// VP-IO active the output is already level-managed by Apple's AGC — a
    /// second nonlinear stage on an already-managed signal is pure added
    /// distortion. On the fallback path it stays: no AEC/NS/AGC runs there,
    /// and a loud/close mouth-to-mic can saturate downstream of the ADC
    /// ("scoppiettio").
    private func applyRawMicTxLimiter(rawPcm raw: inout Data) {
        raw.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) in
            guard let samples = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            let n = rawBuf.count / 2
            // W-AGCCEIL — shares the knee/ceiling constants with the
            // inline make-up limiter so the two curves can never drift
            // apart. NOT counted into `limiterSampleCount`: on this
            // (VP-IO-off) path the inline stage has already run over the
            // same samples with the identical curve, so counting here
            // would double-count. The duty-cycle metric is about the
            // VP-IO path, where this block does not run at all.
            let threshold: Float = Self.limiterKnee * Float(Int16.max)
            let ceiling: Float = Self.limiterCeiling * Float(Int16.max)
            let range = ceiling - threshold
            for i in 0..<n {
                let sample = Float(samples[i])
                let mag = abs(sample)
                guard mag > threshold else { continue }
                let excess = mag - threshold
                let compressed = threshold + range * (1 - exp(-excess / range))
                samples[i] = Int16(clamping: Int((sample < 0 ? -1 : 1) * compressed))
            }
        }
    }

    /// W475 — re-chunk into EXACT bytesPerFrame frames. `installTap`'s
    /// bufferSize is only a hint, and VoiceProcessing I/O ties the tap
    /// buffer to the hardware I/O duration — so `buffer.frameLength` is an
    /// arbitrary size, frequently far larger than the 960 samples Opus
    /// requires. A mis-sized frame made OpusCodec.encode return nil;
    /// QAudionEngine.processOutgoingAudio then fell back to encrypting the
    /// RAW PCM, and once that raw buffer exceeded maxPayloadSize (4096 B /
    /// >2048 samples — common) the `payload.count <= maxPayloadSize`
    /// precondition in EncryptedFrame.init trapped (SIGTRAP), crashing the
    /// call the instant capture started on answer. It also killed TX
    /// outright: Opus never once encoded a frame. Re-chunking guarantees
    /// every onFrame delivery is exactly bytesPerFrame.
    private func rechunkAndEmit(rawPcm raw: Data) {
        self.pcmAccumulator.append(raw)
        // W-LONGAUDIO (2026-08-10) — chunk to the LATCHED profile's frame, not to
        // the module constant. The Opus encoder accepts exactly the frame size it
        // was configured for and nothing else, so on a long-profile call every
        // 1920-byte chunk this used to emit would be rejected by `encode` and the
        // whole call would go out silent at a perfectly constant rate.
        let frameBytes = captureProfile.bytesPerFrame
        var consumed = 0
        var emitted = 0
        while self.pcmAccumulator.count - consumed >= frameBytes {
            let chunk = self.pcmAccumulator.subdata(in: consumed ..< consumed + frameBytes)
            consumed += frameBytes
            emitted += 1
            // W-CANONICAL — software NR retired (double-NS over VP-IO's);
            // chunks go straight to Opus.
            self.onFrame?(chunk)
        }
        // W-TXBURST — largest number of 20 ms frames emitted from ONE tap
        // callback. 1 (occasionally 2) is a steady 50 fps stream; a large
        // value means the hardware is clumping our I/O and the peer's
        // jitter buffer sees bursts, not a stream. Counter only.
        // W-LONGAUDIO — `emitted` is a count of frames from one tap callback, so
        // its meaning as a burst indicator scales with the frame duration: at
        // 60 ms the same hardware clumping produces a third of the count. The
        // counter is reported alongside the profile so the two are read together;
        // it is deliberately NOT rescaled here, because rescaling would make the
        // raw number incomparable with the historical series.
        if emitted > self.txBurstMaxThisCall { self.txBurstMaxThisCall = emitted }
        if consumed > 0 {
            self.pcmAccumulator = consumed < self.pcmAccumulator.count
                ? self.pcmAccumulator.subdata(in: consumed ..< self.pcmAccumulator.count)
                : Data()
        }
    }

    /// The in-flight target: how many 20 ms buffers may sit on the player node at
    /// once. Depth beyond this lives in [PlayoutJitterBuffer], where the catch-up
    /// tiers can see it.
    ///
    /// W-IOSAUDIOSTARVE (2026-08-02): raised 2 → 4 (40 ms → 80 ms). Two buffers
    /// assumed the pump is never more than 40 ms late, and the pump runs on the
    /// same queue that — until the companion fix in
    /// `QAudionCallIntegration.processIncomingAudio` — also ran the entire
    /// per-frame analysis stack. Whenever that assumption broke the node ran dry
    /// and rendered literal SILENCE, which is not even counted as a jitter-buffer
    /// underrun because `pop()` is never reached; on device this was audible as
    /// continuous "seghettato" with the handset running hot.
    ///
    /// Four matches [PlayoutJitterBuffer]'s own `nominalWatermark`, so a transient
    /// 40–60 ms hitch is absorbed instead of rendered, while everything above that
    /// still belongs to the tier logic. This is defence in depth for the real fix
    /// (analysis moved off the audio path) — not a substitute for it: a permanently
    /// overloaded consumer will still starve any finite buffer.
    ///
    /// W-LONGAUDIO (2026-08-10) — 80 ms, not "4 frames". Held as a duration it
    /// stays 4 buffers at 20 ms (unchanged) and becomes 1 at 60 ms; held as a
    /// count it would have been 240 ms of standing latency added to every
    /// long-profile call, which is the exact quantity this feature exists to
    /// avoid paying.
    private static let playoutInFlightTargetMs = 80

    /// Floor on ``playoutInFlightTarget``, in BUFFERS rather than milliseconds.
    ///
    /// 2026-08-11, from the first long-profile call on a real iPhone (build
    /// 1.0.958, iOS↔Android): the caller reported interruptions and a metallic
    /// timbre. Both are this line. `framesForMs(80, 60)` is
    /// `max(1, (80 + 30) / 60)` = 1, so the long profile ran with exactly ONE
    /// buffer on the player node — none queued behind the one being rendered.
    /// The next buffer is only scheduled after the completion handler hops back
    /// to main (see `pumpPlayout`'s call site), so any delay at all leaves the
    /// node with nothing to play.
    ///
    /// Both reported symptoms follow from that. The node running dry renders
    /// literal silence, which W-IOSAUDIOSTARVE above records as audible
    /// "seghettato" on device and which is not even counted as a jitter-buffer
    /// underrun because `pop()` is never reached — the interruptions. And when
    /// `pumpPlayout` does conceal, it repeats the last delivered frame at −6 dB;
    /// a repeated 60 ms frame is three times the artefact a repeated 20 ms one
    /// is, and a repeated waveform is what "metallic" sounds like.
    ///
    /// Two is not a tuning choice, it is the pipelining minimum: one buffer
    /// rendering, one already queued. The duration budget above answers "how
    /// much hitch do we absorb" and is still the binding constraint at 20 ms
    /// (4 buffers), where this floor changes nothing. At 60 ms it costs 120 ms
    /// of standing latency instead of 60 — half of the 240 ms the count-based
    /// version would have cost, and the price of the node having anything to
    /// play at all.
    static let playoutInFlightFloorBuffers = 2

    /// The target as a pure function of the inbound frame duration.
    ///
    /// Deliberately not `private`, and deliberately static: the instance
    /// property below needs a live [AudioCapture], which needs an audio session,
    /// so nothing could assert this arithmetic before now — and the defect it
    /// encodes shipped to a device precisely because this junction had no test
    /// at any duration. `@testable import` reaches this; see
    /// `PlayoutInFlightTargetTests`.
    static func playoutInFlightTarget(forFrameDurationMs ms: Int) -> Int {
        max(playoutInFlightFloorBuffers,
            AudioConstants.framesForMs(playoutInFlightTargetMs, frameDurationMs: ms))
    }

    /// 4 at 20 ms — unchanged. 2 at 60 ms, by the floor rather than by the
    /// duration, which alone would say 1.
    private var playoutInFlightTarget: Int {
        Self.playoutInFlightTarget(forFrameDurationMs: inboundFrameDurationMs)
    }

    /// Drain the jitter buffer onto the player node up to the in-flight target.
    ///
    /// Called on every arrival and again from the completion handler, so the rate is
    /// the node's real consumption rate rather than a timer we would have to keep in
    /// sync with the hardware clock.
    /// Main-thread only — see the W-PLAYOUTRACE note at the `playFrame` call site.
    /// One thread owns `playoutInFlight`/`engine`/`playerNode` now, so there is
    /// nothing left to keep in sync across threads.
    private func pumpPlayout() {
        dispatchPrecondition(condition: .onQueue(.main))
        let target = playoutInFlightTarget
        while playoutInFlight < target {
            guard let frame = playoutJitter.popWithDriftCatchup() else {
                // Underrun. Conceal rather than leave a hole: a repeat of the last
                // delivered frame at -6 dB is crude, but the alternative here is
                // literal silence, and a 20 ms silence is far more audible than a
                // 20 ms attenuated repeat. Counted so the concealment shows up in
                // telemetry instead of looking like a healthy call.
                if let last = lastDeliveredPlayoutFrame, playoutConcealBudget > 0 {
                    playoutConcealBudget -= 1
                    playoutConcealed += 1
                    scheduleForPlayout(Self.attenuated(last, by: 0.5))
                }
                return
            }
            // Budget re-arms on every real frame: concealment is for a gap, not a
            // substitute for a stream that has stopped arriving.
            playoutConcealBudget = playoutConcealMax
            lastDeliveredPlayoutFrame = frame
            scheduleForPlayout(frame)
        }
    }

    /// W-LONGAUDIO (2026-08-10) — update the playout geometry from a decoded
    /// frame's own length.
    ///
    /// 48 kHz mono Int16 is 96 bytes per millisecond. Anything that does not
    /// resolve to a duration Opus can actually carry is IGNORED rather than
    /// acted on: a zero-length frame (the silent-frame convention), a partial
    /// buffer, or a corrupt one must not be allowed to resize the buffer that is
    /// currently holding good audio.
    ///
    /// Only a genuine change does any work, so the steady-state cost on a 20 ms
    /// call is one integer division and one comparison per frame.
    private func noteInboundFrameDuration(pcmBytes: Int) {
        let bytesPerMs = AudioConstants.sampleRate / 1000 * (AudioConstants.bitsPerSample / 8) * AudioConstants.channels
        guard bytesPerMs > 0, pcmBytes > 0, pcmBytes % bytesPerMs == 0 else { return }
        let ms = pcmBytes / bytesPerMs
        guard ms > 0, ms <= AudioConstants.maxFrameDurationMs, ms != inboundFrameDurationMs else { return }
        playoutJitter.setInboundFrameDurationMs(ms)
        print("[AudioCapture] W-LONGAUDIO: inbound frame duration now \(ms) ms — playout watermarks re-derived")
    }

    /// Halve every sample. `Int16` stays in range by construction, so no clamping.
    private static func attenuated(_ pcm: Data, by factor: Float) -> Data {
        var out = pcm
        out.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: Int16.self).baseAddress else { return }
            let n = raw.count / 2
            for i in 0..<n { p[i] = Int16(Float(p[i]) * factor) }
        }
        return out
    }

    /// At most this much consecutive concealment before we stop and let the gap be
    /// a gap. Repeating one frame indefinitely turns a dropout into a buzz, which
    /// is worse than the silence it replaced.
    ///
    /// W-LONGAUDIO (2026-08-10) — 120 ms, not "6 frames". The audible limit is how
    /// LONG the same frame is repeated, so as a frame count it would have stretched
    /// to 360 ms of buzz on a long-profile call.
    private static let playoutConcealMaxMs = 120

    /// 6 at 20 ms — unchanged.
    private var playoutConcealMax: Int {
        AudioConstants.framesForMs(Self.playoutConcealMaxMs,
                                   frameDurationMs: inboundFrameDurationMs)
    }

    private func scheduleForPlayout(_ pcmData: Data) {
        // W574j — build the playback buffer in the player node's LIVE output
        // format, not the cached `playFormat`. On iPad, enabling Voice
        // Processing I/O reconfigures the player→mixer bus to the hardware
        // format (typically Float32) AFTER our Int16 `connect(...)`. Scheduling
        // an Int16 buffer onto a Float32 bus fails AVAudioPlayerNode's format
        // precondition → AVAudioEngine throws an Obj-C NSException → SIGABRT.
        // This was invisible until W574i fixed the seal: once relay audio
        // actually decrypts, the receiver finally calls playFrame with real
        // PCM and the latent format mismatch crashed the iPad on answer.
        // Reading the bus format here (and converting the decoded Int16 mono
        // PCM into it) keeps scheduleBuffer valid on every device/route.
        // W-AUDIODEATH (2026-07-24) — count what this guard throws away. A decoded
        // frame reaching here and being binned because the engine is not running is
        // the EXACT signature of "audio decrypts fine but the user hears nothing",
        // and it was previously invisible: the drop is silent, and every counter we
        // shipped (rx_recv/rx_dec) still looked perfect because they are incremented
        // upstream of this point. Non-zero `playout_dropped` next to a healthy
        // `rx_dec` now names the fault instead of leaving it to inference.
        guard isRunning,
              let player = playerNode,
              let engine = engine, engine.isRunning else {
            audioPipeline.notePlayoutDropped()
            return
        }
        let outFmt = player.outputFormat(forBus: 0)
        let frames = pcmData.count / 2  // decoded PCM is Int16 mono
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outFmt,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            // W-IOSPLAYOUT (2026-07-25) — the engine was alive and willing and we threw
            // the frame away anyway. Counted separately from `playoutDropped`, which means
            // "the engine was dead": these two look identical to the user and have
            // completely different causes.
            audioPipeline.notePlayoutSchedFail()
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let ch = Int(outFmt.channelCount)
        let scale: Float = 1.0 / 32768.0
        let filled: Bool = pcmData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return false }
            if outFmt.commonFormat == .pcmFormatInt16, let dst = buffer.int16ChannelData {
                if outFmt.isInterleaved {
                    let d = dst[0]
                    for i in 0..<frames { let v = src[i]; for c in 0..<ch { d[i * ch + c] = v } }
                } else {
                    for c in 0..<ch { let d = dst[c]; for i in 0..<frames { d[i] = src[i] } }
                }
                return true
            } else if outFmt.commonFormat == .pcmFormatFloat32, let dst = buffer.floatChannelData {
                if outFmt.isInterleaved {
                    let d = dst[0]
                    for i in 0..<frames { let v = Float(src[i]) * scale; for c in 0..<ch { d[i * ch + c] = v } }
                } else {
                    for c in 0..<ch { let d = dst[c]; for i in 0..<frames { d[i] = Float(src[i]) * scale } }
                }
                return true
            }
            return false  // unsupported bus format → skip frame (never crash)
        }
        guard filled else {
            // The other silent bail-out: an output bus in a format we do not fill.
            audioPipeline.notePlayoutSchedFail()
            return
        }
        // W-IOSPLAYOUT (2026-07-25) — measure the player node's OWN queue.
        //
        // `AVAudioPlayerNode` is a second elastic store downstream of everything else, and
        // nothing observed it. A queue that grows is standing latency the user hears as
        // delay; a queue that empties is the gap they hear as a dropout. The completion
        // handler slot was sitting unused, and it is the only signal that a buffer was
        // actually consumed.
        //
        // Deliberately a pure LEDGER with no control authority: if a handler never fires,
        // the cost is a wrong number and never a stalled call. Both increment and
        // decrement now happen on main by construction (see W-PLAYOUTRACE) rather
        // than by hopping to reconcile two different calling threads.
        dispatchPrecondition(condition: .onQueue(.main))
        playoutInFlight += 1
        lastPlayoutFrameAtMs = Self.monotonicNowMs()  // W-AUDIOBEACON — a frame really reached the player node
        audioPipeline.notePlayoutScheduled(inFlightAfter: playoutInFlight)
        player.scheduleBuffer(buffer) { [weak self] in
            // W-PLAYOUTRACE — do NOT touch engine/playerNode on this thread. This
            // completion callback fires on an AVFoundation-internal thread, which is
            // exactly the thread that raced `restartEngineForRoute`'s main-queue
            // teardown and froze the app on a real device the first time this pump
            // shipped. Hop to main — the pipeline's one and only owning thread — and
            // do every bit of work there, including the pump call that used to run
            // inline right here.
            DispatchQueue.main.async {
                guard let self else { return }
                if self.playoutInFlight > 0 {
                    self.playoutInFlight -= 1
                } else {
                    // A route flip can fire pending handlers in a burst. Counting that
                    // instead of clamping in silence is what keeps the depth readable: a
                    // non-zero anomaly count means treat the max as a lower bound.
                    self.audioPipeline.notePlayoutLedgerAnomaly()
                }
                // W-PLAYOUTRACE — the pump call that used to run inline in this
                // handler, moved here rather than dropped: a consumed buffer is
                // still the pump's clock (self-clocking off the node's real
                // consumption rate, not off network arrival cadence, is the whole
                // reason this handler exists). After the ledger decrement so
                // `pumpPlayout`'s target check reads the up-to-date count.
                self.pumpPlayout()
            }
        }
    }

    private func registerInterruptionObserver() {
        // W-NOTIFYMAIN (2026-09-02) — all three observers below used to pass
        // `queue: nil`, which per NotificationCenter's own contract delivers
        // the block SYNCHRONOUSLY on whatever thread posts the notification —
        // for AVAudioSession that thread is NOT guaranteed to be main (Apple's
        // own AVAudioSession guidance: these notifications may arrive on a
        // background thread and engine work should be confined to main to
        // avoid races). `handleInterruption`'s `.ended` branch calls `start()`
        // directly (line ~2155) and `handleRouteChange` calls
        // `restartEngineForRoute()` (tears down + nils `engine`/`playerNode`
        // then rebuilds) directly — both unsynchronized against every OTHER
        // caller of `start()`, which (CallKit didActivate, handleCallAnswered,
        // activateIncomingCallAudio, and the renegotiation `call_offer` path
        // via `AppState.handleIncomingWebRtcOffer`, explicitly hopped to main
        // by its own 2026-07-12 fix) all run on main. Two concurrent, ordinary
        // AVAudioEngine/AVAudioPlayerNode `start()` builds racing on two
        // different threads against the same hardware session is exactly what
        // produced a live, reproducible crash: NSException
        // com.apple.coreaudio.avfaudio "player started when in a disconnected
        // state" (CallService.performAudioCaptureStart → AudioCapture.start,
        // seen on an iOS↔Android call while Android handed off Wi-Fi→5G,
        // which drives an ICE-restart `call_offer` on iOS — landing in the
        // exact window this file's own W574p comment already documents as
        // self-provoking MORE route-change notifications). `handleMediaServicesReset`
        // already re-hops internally (its own `DispatchQueue.main.async`), so
        // routing its observer through `.main` too is a harmless no-op there.
        // Delivering all three on `.main` — the SAME serial queue every
        // `start()`/`stop()` caller already uses — makes them mutually
        // exclusive by construction, no new lock needed.
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        // W571 — route change observer. Handles headset plug/unplug and
        // Bluetooth HFP connect/disconnect. On .oldDeviceUnavailable
        // (headset removed) the engine may keep running on the now-removed
        // device route and go silent. Restarting on device unavailability
        // ensures the engine re-opens on the current hardware (earpiece
        // or built-in speaker) with the correct format.
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
        // W-MEDIARESET (2026-09-01) — the media server restarting under a
        // live capture orphans every audio object and wipes the session
        // configuration. It was never observed here (only a comment in
        // VideoCallPipeline mentioned it), so a reset mid-call left a dead
        // engine with `isRunning == true` — the W-AUDIODEATH signature from
        // a cause none of the restart paths could see. Same lifetime as the
        // two observers above (removed by stop()/deinit).
        guard mediaServicesResetObserver == nil else { return }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset()
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        // W-SPKFIX — FIRST, reason-agnostically catch the in-call speaker toggle.
        // The output route flipping speaker<->earpiece (however it was triggered:
        // .categoryChange from setCategory .defaultToSpeaker, .override from
        // overrideOutputAudioPort, or an OS-driven proximity change) requires the
        // engine to rebuild on the new route or the mic input tap dies. Compare
        // the LIVE route against the one the engine was built for; if it flipped
        // and this isn't the echo of our own just-completed restart, debounce a
        // rebuild so the toggle's notification storm coalesces into ONE restart on
        // the settled route.
        if isRunning {
            let nowSpeaker = AudioProcessingPipeline.currentRouteHasBuiltInSpeaker()
            if nowSpeaker != engineBuiltForSpeaker && Date() >= restartSuppressUntil {
                print("[AudioCapture] W-SPKFIX: output route flipped to " +
                      (nowSpeaker ? "speaker" : "earpiece") +
                      " (reason=\(reason.rawValue)) — rebuilding engine on new route")
                scheduleDebouncedRouteRestart()
                return
            }
        }
        switch reason {
        case .oldDeviceUnavailable:
            // A device that was in use (Bluetooth HFP, wired headset) was removed.
            // AVAudioEngine may go silent if it was using the now-missing device.
            // Restart to pick up the new route (built-in mic/speaker) — but throttle
            // so a flapping route doesn't thrash the engine (W574o).
            if shouldSkipRouteRestart() { return }
            print("[AudioCapture] route change: old device unavailable — restarting engine")
            restartEngineForRoute(routeDriven: true)
        case .newDeviceAvailable:
            // New device connected (e.g. Bluetooth HFP). The engine may be using a
            // lower-quality route; restart to prefer the new device. Throttled (W574o).
            if shouldSkipRouteRestart() { return }
            print("[AudioCapture] route change: new device available — restarting engine")
            restartEngineForRoute(routeDriven: true)
        case .override:
            // W574c — the output route was overridden: this is the in-call speaker
            // button (`overrideOutputAudioPort(.speaker)` / `.none`). VP-IO is
            // route-dependent and can only be (un)set BEFORE engine start, so restart
            // to re-evaluate `enableVoiceProcessing` on the new route.
            //
            // W574p — W574o/14a0c7f assumed this notification was "one-shot" per tap
            // and left it unthrottled. Device telemetry (W556 session logs) shows
            // vpio flapping true/false every ~1s with `out=Speaker` UNCHANGED across
            // the flaps — i.e. `.override` itself re-fires (setCategory +
            // overrideOutputAudioPort can each provoke a route-change post, and the
            // restart's own configureForVoIP()→setActive is a further echo) faster
            // than the single restart it triggers can settle. Because this case
            // skipped shouldSkipRouteRestart(), every one of those echoes was
            // honored with a FULL engine teardown/rebuild, thrashing VP-IO and
            // producing the audible crackling — the exact BT-thrash failure mode
            // W574o fixed for the other two cases, just not this one. Apply the same
            // throttle/suppress guard: the first tap still restarts immediately
            // (nothing to skip yet), only the self-provoked echoes are now dropped.
            if shouldSkipRouteRestart() { return }
            print("[AudioCapture] route change: output override (speaker toggle) — restarting engine to re-evaluate VP-IO")
            restartEngineForRoute(routeDriven: true)
        default:
            break
        }
    }

    /// W-SPKFIX — coalesce a burst of route-change notifications (a single
    /// speaker toggle posts several within ~100 ms, and each restart's own
    /// setActive posts more) into ONE engine rebuild ~0.35 s after the LAST one,
    /// when the route has settled. restartEngineForRoute arms restartSuppressUntil
    /// (~0.6 s) so the rebuild's own echoes are ignored by the guard above,
    /// breaking the self-induced loop.
    private func scheduleDebouncedRouteRestart() {
        pendingRouteRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            // W-VPIORETRY — this path is only ever armed by handleRouteChange's
            // speaker<->earpiece detector, i.e. the route really did change.
            self.restartEngineForRoute(routeDriven: true)
        }
        pendingRouteRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// W574o — skip a route-driven engine restart if we just restarted (the route
    /// change is the echo of our own `setActive`) or if we restarted < 1s ago (a
    /// flapping Bluetooth link). Keeps the genuine isolated headset plug/unplug case
    /// (W571) working — those are not rapid repeats.
    private func shouldSkipRouteRestart() -> Bool {
        let now = Date()
        if now < restartSuppressUntil { return true }
        if now.timeIntervalSince(lastEngineRestart) < routeRestartThrottle { return true }
        return false
    }

    /// Tear down and rebuild the engine on the current hardware route. Records the
    /// restart time and arms a short suppress window so the route change this restart
    /// itself provokes is ignored (breaks the self-induced thrash loop).
    ///
    /// W-VPIORETRY (2026-07-21) — `routeDriven` says whether the HARDWARE ROUTE
    /// changed (headset/car-kit/speaker) as opposed to this being the starve
    /// watchdog's own fallback restart. Only a route change may lift a previous
    /// VP-IO bypass; see `shouldRetryVoiceProcessing` for why the latch had to
    /// stop being permanent.
    private func restartEngineForRoute(routeDriven: Bool = false) {
        guard isRunning else { return }
        if audioPipeline.forceDisableVoiceProcessing,
           Self.shouldRetryVoiceProcessing(bypassCount: audioPipeline.voiceProcessingBypassCount,
                                           restartIsRouteDriven: routeDriven) {
            print("[AudioCapture] W-VPIORETRY: route changed after a VP-IO bypass — re-arming Voice-Processing (AEC/NS/AGC) for the new route")
            audioPipeline.forceDisableVoiceProcessing = false
            audioPipeline.noteVoiceProcessingRetry()
        }
        audioPipeline.noteEngineRestart()  // W-CANONICAL — engine_restarts telemetry
        // W-IOSECHO (2026-07-22) — `route_changes` (iOS port of Android's
        // field of the same name) counts only ROUTE-DRIVEN restarts,
        // deliberately excluding the W-AEC-FIX starve-watchdog restart
        // (routeDriven: false), which rebuilds the engine on the SAME
        // hardware route rather than reacting to a real route change.
        if routeDriven { audioPipeline.noteRouteChange() }
        lastEngineRestart = Date()
        restartSuppressUntil = Date().addingTimeInterval(0.6)
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        playoutInFlight = 0  // W-IOSPLAYOUT — stop() discards the queue; the ledger must follow
        if let engine = engine { audioPipeline.disableVoiceProcessing(on: engine) }
        engine?.stop()
        engine = nil; playerNode = nil; playFormat = nil; inputSink = nil; isRunning = false
        restartEngineWithRecovery(attempt: 0)
    }

    /// W-AUDIODEATH (2026-07-24, call db4e5b20) — restart the torn-down engine,
    /// and DO NOT give up silently if it refuses to come back.
    ///
    /// This used to be `do { try start() } catch { print(...) }`. That single
    /// swallowed error is a total, permanent, silent loss of audio for the rest
    /// of the call: the engine has ALREADY been destroyed by the caller and
    /// `isRunning` set to `false`, so once `start()` throws, `playFrame`'s
    /// `guard isRunning, …, engine.isRunning` discards every decrypted frame
    /// forever after. Nothing retried, nothing watched, nothing counted, and
    /// the user's only symptom is "the call went quiet" — which looks
    /// identical to a network fault from every log we ship. The only accidental
    /// way out was an OS interruption ending with `shouldResume`.
    ///
    /// It matches the live report exactly: iOS `rx_recv/rx_dec = 3594/3594`
    /// (every frame arrived AND decrypted, right up to hangup) with nothing
    /// audible — i.e. the loss is strictly downstream of decryption, which is
    /// where this function sits.
    ///
    /// Recovery ladder, cheapest and most likely first:
    ///  1. plain retry — most `AVAudioEngine.start()` failures right after a
    ///     route flip are transient (the route is still settling).
    ///  2. retry WITHOUT voice processing — `setVoiceProcessingEnabled` is the
    ///     single most failure-prone step on iOS (it is what
    ///     `forceDisableVoiceProcessing`/`voiceProcessingBypassCount` already
    ///     exist to work around elsewhere in this file). Degraded audio (no
    ///     AEC/NS/AGC) beats no audio, and the existing VP-IO retry latch
    ///     re-arms it on the next genuine route change.
    ///  3. keep a bounded backoff watchdog running so a route that is still
    ///     mid-flip (or a transient HAL error) still recovers seconds later
    ///     instead of never.
    ///
    /// Every failed attempt increments `engine_restart_fail` so the next
    /// incident is visible in telemetry instead of being a `print` on a device
    /// nobody is attached to.
    private func restartEngineWithRecovery(attempt: Int) {
        // Bound the ladder. 0,1 = plain retries; 2+ = retries with VP-IO forced
        // off; stop after `maxAttempts` so a genuinely dead audio subsystem
        // cannot spin a timer for the whole call.
        let maxAttempts = 5
        guard attempt < maxAttempts else {
            print("[AudioCapture] W-AUDIODEATH: engine restart gave up after \(maxAttempts) attempts — audio is DOWN for this call")
            return
        }
        // From the 3rd attempt on, drop voice processing: it is the most common
        // reason start() keeps failing, and audio without AEC is still audio.
        if attempt >= 2, !audioPipeline.forceDisableVoiceProcessing {
            print("[AudioCapture] W-AUDIODEATH: restart attempt \(attempt) — disabling Voice-Processing and retrying (degraded audio beats no audio)")
            audioPipeline.forceDisableVoiceProcessing = true
        }
        do {
            try start()
            if attempt > 0 {
                print("[AudioCapture] W-AUDIODEATH: engine recovered on attempt \(attempt)")
            }
            return
        } catch {
            audioPipeline.noteEngineRestartFailed()
            print("[AudioCapture] W-AUDIODEATH: engine restart attempt \(attempt) failed: \(error.localizedDescription)")
        }
        // Backoff: 150ms, 300ms, 600ms, 1.2s — bounded by `maxAttempts` above.
        let delay = 0.15 * pow(2.0, Double(attempt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Someone else (interruption resume, a fresh call, teardown) may have
            // already rebuilt or stopped the engine — never fight them.
            guard !self.isRunning else { return }
            self.restartEngineWithRecovery(attempt: attempt + 1)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // OS seized the audio session (phone call / Siri / alarm).
            // Tear down tap + engine and report not-running so the UI
            // reflects dead capture instead of a silent one-sided call.
            // Do NOT deactivate the session — the OS owns it for the
            // duration of the interruption.
            wasInterrupted = true
            cancelPendingResumeRetry()  // W-AUDIORESUME — a new interruption supersedes any armed retry
            engine?.inputNode.removeTap(onBus: 0)
            playerNode?.stop()
            playoutInFlight = 0  // W-IOSPLAYOUT — stop() discards the queue; the ledger must follow
            if let engine = engine {
                audioPipeline.disableVoiceProcessing(on: engine)
            }
            engine?.stop()
            engine = nil
            playerNode = nil
            playFormat = nil
            inputSink = nil
            isRunning = false
        case .ended:
            guard wasInterrupted else { return }
            wasInterrupted = false
            var shouldResume = false
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                shouldResume = opts.contains(.shouldResume)
            }
            // W-AUDIORESUME (2026-09-01) — `.ended` without `.shouldResume`
            // used to `return` here and the engine stayed dead for the rest
            // of the call (audit reference_ios_stability_audit_2026_09_01,
            // P1 (2)). The missing hint is the OS saying "not sure you want
            // it back", not a prohibition: while a voice call owns the
            // session the app DOES want it back, so a bounded 1 s / 3 s
            // retry runs instead. `.passive` captures still return here.
            let endedAction = AudioInterruptionRecoveryPolicy.interruptionEndedAction(
                shouldResumeHint: shouldResume, ownership: sessionOwnership)
            switch endedAction {
            case .ignore:
                return
            case .retryLater:
                print("[AudioCapture] W-AUDIORESUME: interruption ended without shouldResume during a voice call — retrying activation at 1 s / 3 s")
                scheduleResumeRetry(attemptIndex: 0)
                return
            case .resumeNow:
                break
            }
            // start() reconfigures + reactivates the session and rebuilds
            // the engine/tap. The observer is still registered (only
            // stop()/deinit remove it) so start()'s register call no-ops.
            do {
                try start()
            } catch {
                let edesc: String = error.localizedDescription
                let line: String = "[AudioCapture] resume after interruption failed: " + edesc
                print(line)
                // W-AUDIORESUME — the hinted resume threw: the one engine
                // death W-AUDIODEATH's ladder never covered. Same bounded
                // retry, same voice-call gate; a `.passive` owner keeps the
                // print-and-give-up above.
                if AudioInterruptionRecoveryPolicy.hintedResumeFailedAction(ownership: sessionOwnership) == .retryLater {
                    audioPipeline.noteEngineRestartFailed()
                    scheduleResumeRetry(attemptIndex: 0)
                }
            }
        @unknown default:
            break
        }
    }

    // MARK: - W-AUDIORESUME / W-MEDIARESET / W-AUDIOBEACON (2026-09-01)
    //
    // Mechanics only — timers, notification hops, the engine calls. The
    // decisions and their evidence are in `AudioInterruptionRecoveryPolicy`.
    // Every recovery here funnels through the EXISTING `start()` /
    // `restartEngineForRoute` machinery; nothing in this block builds or
    // configures an engine on its own.

    /// Monotonic milliseconds for the frame-age counters — immune to the
    /// wall-clock jumps a backgrounded device sees.
    private static func monotonicNowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// W-AUDIORESUME — arm retry number `attemptIndex` of the bounded resume
    /// ladder (lands 1 s, then 3 s after `.ended`), or declare audio lost
    /// once the schedule is exhausted. Main queue, like every other engine
    /// mutation in this file.
    private func scheduleResumeRetry(attemptIndex: Int) {
        guard let delayMs = AudioInterruptionRecoveryPolicy.resumeRetryDelayMs(attemptIndex: attemptIndex) else {
            // Exhausted: the engine is down for the rest of this call. Say so
            // in a form that survives the remote-log redactor (short numeric
            // tokens, no bracketed prefix — see AudioEngineStateBeacon's
            // kdoc) so the next incident is a fact rather than an inference.
            let lost: String = "audioresume lost=1 attempts=" + String(attemptIndex)
            print(lost)
            print("[AudioCapture] W-AUDIORESUME: resume retries exhausted — audio is DOWN for this call")
            return
        }
        pendingResumeRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResumeRetry = nil
            // Someone else (CallKit didActivate → CallService restart, a new
            // `.began`, teardown) may have moved on — never fight them. A nil
            // interruption observer means stop() ran: the call is over.
            guard !self.isRunning, !self.wasInterrupted, self.interruptionObserver != nil else { return }
            // The category survived the interruption (only deactivateSession
            // clears `isConfigured`); what was lost is ACTIVATION, so ask for
            // it back explicitly before rebuilding — best-effort `try?`, the
            // same call the CallService didActivate fallback makes.
            self.audioPipeline.activateSession()
            let attemptNo: String = String(attemptIndex + 1)
            var failure: String?
            do {
                try self.start()
            } catch {
                failure = error.localizedDescription
            }
            if failure == nil, self.isRunning {
                let ok: String = "audioresume attempt=" + attemptNo + " ok=1"
                print(ok)
                return
            }
            if failure == nil {
                // start() returned without running: the group-call VP-IO gate
                // refused it, i.e. a group call owns audio now. Stop the ladder.
                let gated: String = "audioresume attempt=" + attemptNo + " ok=0 gated=1"
                print(gated)
                return
            }
            self.audioPipeline.noteEngineRestartFailed()  // engine_restart_fail telemetry, no new field
            let failed: String = "audioresume attempt=" + attemptNo + " ok=0"
            print(failed)
            let reason: String = failure ?? ""
            let detail: String = "[AudioCapture] W-AUDIORESUME: resume attempt " + attemptNo + " failed: " + reason
            print(detail)
            self.scheduleResumeRetry(attemptIndex: attemptIndex + 1)
        }
        pendingResumeRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: work)
    }

    private func cancelPendingResumeRetry() {
        pendingResumeRetry?.cancel()
        pendingResumeRetry = nil
    }

    /// W-MEDIARESET — the media server restarted under us: every audio
    /// object is orphaned and the session configuration is gone, so the
    /// engine must be rebuilt from scratch and the session set up again.
    /// Hop to main (engine/playerNode are main-owned — W-PLAYOUTRACE) and
    /// reuse the route-restart machine: `restartEngineForRoute` arms the
    /// same suppress window that already keeps a reconfiguration's own
    /// route-change echoes from thrashing, and its W-AUDIODEATH ladder covers
    /// a `start()` that fails while the server is still coming back.
    private func handleMediaServicesReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let action = AudioInterruptionRecoveryPolicy.mediaServicesResetAction(isRunning: self.isRunning)
            let runFlag: String = self.isRunning ? "1" : "0"
            let actionCode: String = String(Self.mediaResetActionCode(action))
            let line: String = "audioreset run=" + runFlag + " act=" + actionCode
            print(line)
            switch action {
            case .ignore:
                return
            case .invalidateSessionOnly:
                // Not running (mid-interruption or a ladder attempt pending):
                // whichever path calls start() next re-runs configureForVoIP.
                self.audioPipeline.invalidateSessionConfiguration()
            case .rebuildEngine:
                print("[AudioCapture] W-MEDIARESET: media services were reset under a running capture — reconfiguring the session and rebuilding the engine")
                self.audioPipeline.invalidateSessionConfiguration()
                self.restartEngineForRoute(routeDriven: false)
            }
        }
    }

    private static func mediaResetActionCode(_ action: AudioInterruptionRecoveryPolicy.MediaServicesResetAction) -> Int {
        switch action {
        case .ignore: return 0
        case .invalidateSessionOnly: return 1
        case .rebuildEngine: return 2
        }
    }

    /// W-AUDIOBEACON — periodic engine-state line while a voice-call capture
    /// is alive. A dedicated timer on the main queue (the engine's owning
    /// thread), never the tap or render thread — their only contribution is
    /// one timestamp store per delivered buffer. Armed once per call: a
    /// mid-call `start()` from a route restart finds it already running.
    private func armStateBeaconIfNeeded() {
        guard stateBeaconTimer == nil,
              AudioEngineStateBeacon.shouldRun(ownership: sessionOwnership) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.seconds(AudioEngineStateBeacon.intervalSec)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.emitStateBeacon()
        }
        timer.resume()
        stateBeaconTimer = timer
    }

    private func cancelStateBeacon() {
        stateBeaconTimer?.cancel()
        stateBeaconTimer = nil
    }

    private func emitStateBeacon() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let now = Self.monotonicNowMs()
        let snapshot = AudioEngineStateBeacon.Snapshot(
            engineRunning: engine?.isRunning ?? false,
            captureRunning: isRunning,
            voiceProcessingActive: audioPipeline.voiceProcessingIsActive,
            otherAudioPlaying: session.isOtherAudioPlaying,
            outputRouteCode: Self.routeCode(for: route.outputs.first?.portType),
            inputRouteCode: Self.routeCode(for: route.inputs.first?.portType),
            micAgeSeconds: AudioEngineStateBeacon.ageSeconds(lastAtMs: lastMicFrameAtMs, nowMs: now),
            playoutAgeSeconds: AudioEngineStateBeacon.ageSeconds(lastAtMs: lastPlayoutFrameAtMs, nowMs: now),
            interrupted: wasInterrupted,
            engineRestarts: audioPipeline.engineRestartCount)
        let line: String = AudioEngineStateBeacon.line(snapshot)
        print(line)
    }

    /// Numeric route legend for the beacon — see `AudioEngineStateBeacon`
    /// for why the port NAME cannot be shipped.
    private static func routeCode(for port: AVAudioSession.Port?) -> Int {
        guard let port else { return AudioEngineStateBeacon.routeCodeNone }
        switch port {
        case .builtInReceiver: return AudioEngineStateBeacon.routeCodeReceiver
        case .builtInSpeaker: return AudioEngineStateBeacon.routeCodeSpeaker
        case .builtInMic: return AudioEngineStateBeacon.routeCodeBuiltInMic
        case .headphones, .headsetMic, .lineOut, .lineIn: return AudioEngineStateBeacon.routeCodeWired
        case .bluetoothHFP: return AudioEngineStateBeacon.routeCodeBluetoothHFP
        case .bluetoothA2DP: return AudioEngineStateBeacon.routeCodeBluetoothA2DP
        case .bluetoothLE: return AudioEngineStateBeacon.routeCodeBluetoothLE
        case .carAudio: return AudioEngineStateBeacon.routeCodeCarAudio
        case .airPlay: return AudioEngineStateBeacon.routeCodeAirPlay
        case .usbAudio: return AudioEngineStateBeacon.routeCodeUsb
        default: return AudioEngineStateBeacon.routeCodeOther
        }
    }

    public func stop() {
        // W-AUDIODEATH (2026-07-24) — latch whether the engine was still alive at
        // teardown, BEFORE we tear it down ourselves. `false` here on a call that
        // reported healthy rx_dec counts is the fingerprint of a dead-playout call
        // (see `restartEngineWithRecovery`); it is the one fact the live incident
        // could not establish from any log or telemetry record we shipped.
        audioPipeline.noteEngineRunningAtEnd(isRunning && (engine?.isRunning ?? false))
        // W-SPKFIX — cancel any pending debounced route restart so it cannot
        // fire after the call has torn down the engine.
        pendingRouteRestart?.cancel()
        pendingRouteRestart = nil
        // W-AUDIORESUME / W-AUDIOBEACON / W-MEDIARESET — same discipline for
        // the resume ladder, the beacon timer and the reset observer.
        cancelPendingResumeRetry()
        cancelStateBeacon()
        if let obs = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(obs)
            mediaServicesResetObserver = nil
        }
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        playoutInFlight = 0  // W-IOSPLAYOUT — stop() discards the queue; the ledger must follow
        if let engine = engine {
            audioPipeline.disableVoiceProcessing(on: engine)
        }
        engine?.stop()
        engine = nil
        playerNode = nil
        playFormat = nil
        inputSink = nil
        // W-AEC-FIX — clear the watchdog fallback so the NEXT call retries VP-IO
        // AEC fresh (a starve will just re-trigger the fallback if it recurs).
        audioPipeline.forceDisableVoiceProcessing = false
        audioPipeline.deactivateSession()
        isRunning = false
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        stateBeaconTimer?.cancel()
        pendingResumeRetry?.cancel()
    }

    public var isCapturing: Bool { isRunning }

    /// Access the audio processing pipeline for stats or configuration changes.
    public var processingPipeline: AudioProcessingPipeline { audioPipeline }
}
#endif
