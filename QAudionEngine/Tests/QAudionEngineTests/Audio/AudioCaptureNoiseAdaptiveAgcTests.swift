import XCTest
import Foundation
@testable import QAudionEngine

/// W-AGCNOISE / W-VPIORETRY (2026-07-21) — regression tests for the make-up
/// AGC's noise-adaptive ceiling, its SNR gate, and the VP-IO bypass retry.
///
/// THE BUG THESE LOCK DOWN. Two real calls, same pair of devices, ten minutes
/// apart, from `/opt/bcrypto/data/telemetry/2026-07-21.jsonl`:
///
///   call      route      VP-IO      ceiling  agc_gain  rms%  limiter%  verdict
///   d0f84651  earpiece   on         3.0      2.73      6.0   0.005     usable
///   1de9935f  car kit    BYPASSED   6.0      5.89      9.7   0.001     "quasi
///                                                                      incompren-
///                                                                      sibile"
///
/// Three facts follow from those numbers rather than from taste:
///
///  1. Both gains sit at 91 % / 98 % of their ceiling, i.e. the RMS-seeking
///     term was SATURATED in both and the ceiling alone decided the gain.
///  2. The ceiling is chosen by `vpioActive`. VP-IO is the bundle that supplies
///     noise suppression and echo cancellation, so the ceiling was INVERTED:
///     the signal with no NS, no AEC and no Apple AGC — a raw car-kit mic — was
///     allowed twice the blind make-up gain of the clean one.
///  3. `limiter_pct` 0.001 % rules the waveshaper OUT as the distortion source.
///     What is left is the gain MODULATION: the absolute noise gate (0.008,
///     tuned on a quiet room) is wide open on car noise, so the loop wound to
///     the ceiling during every inter-word gap and was ducked ≤3 dB per buffer
///     on every syllable. That is AGC breathing on unsuppressed noise.
///
/// Android is the reference and does neither: `AudioCapture.kt` ships
/// `enableHwAgc = false` ("AGC pumps distant audio undesirably") and
/// `DEFAULT_NOISE_GATE_RMS = 0.0f`, with HW NS + AEC always attached.
/// `agc_ever_active=false` on both calls above.
///
/// Pure arithmetic only — no AVFoundation, no WebRTC — so this runs on the
/// macOS CI runner via `swift test`.
final class AudioCaptureNoiseAdaptiveAgcTests: XCTestCase {

    // Ceilings as `selectMakeUpAgcMaxGain` returns them (fenced separately by
    // AudioCaptureAgcGateTests — deliberately NOT re-derived here).
    private let vpioCeiling: Float = 3.0
    private let rawCeiling: Float = 6.0

    // MARK: - agcNoiseCeilingRms — fenced from BOTH sides

    /// THE CORE CONSTANT. A one-sided assertion here would be worthless: any
    /// value that merely "reduces gain in a car" also destroys the quiet-mic
    /// make-up that `04f82f1`/`dcace27` exist to provide, and any value that
    /// merely "preserves the quiet mic" leaves the car case untouched. Both
    /// anchors below must hold simultaneously, which pins the constant into
    /// roughly [0.018, 0.023]. Shipped: 0.02.
    ///
    /// Anchor A — clean input, deliberately PESSIMISTIC. 0.6 % is a high
    /// estimate of the residual floor left by VP-IO's noise suppressor; using a
    /// high value makes the test HARDER to pass, not easier. On call d0f84651
    /// even the loosest possible reading of the data (treating the entire 6.0 %
    /// post-gain call-average as background at the 2.73 max gain) bounds the raw
    /// floor at 2.2 %, and NS in circuit puts it far below that.
    func testNoiseCeilingDoesNotBindOnANoiseSuppressedInput() {
        let allowed = AudioCapture.noiseLimitedMaxGain(configuredMaxGain: vpioCeiling,
                                                       noiseFloorRms: 0.006)
        XCTAssertEqual(allowed, vpioCeiling, accuracy: 1e-4,
                       "agcNoiseCeilingRms was lowered — the make-up AGC is now "
                       + "restricted on a CLEAN input, which is the faint iOS mic "
                       + "regression 04f82f1/dcace27 exist to fix")
    }

    /// Anchor B — car cabin with VP-IO bypassed (no NS at all). Call 1de9935f's
    /// raw call-average was at least 9.7/5.89 = 1.65 % and the cabin floor is
    /// the dominant part of that average. The make-up must collapse to
    /// essentially nothing here — which is exactly what Android does on the
    /// same acoustics, by running no software AGC at all.
    func testNoiseCeilingCollapsesTheMakeUpOnAnUnsuppressedCarFloor() {
        let allowed = AudioCapture.noiseLimitedMaxGain(configuredMaxGain: rawCeiling,
                                                       noiseFloorRms: 0.02)
        XCTAssertLessThanOrEqual(allowed, 1.15,
                                 "agcNoiseCeilingRms was raised — the loop can wind "
                                 + "up on road noise again (call 1de9935f, agc_gain 5.89)")
    }

    /// The ceiling is a BOUND, never a boost: it must never hand back more than
    /// the configured ceiling however clean the input looks, and never less
    /// than unity however dirty (this stage must not become an attenuator —
    /// the peak/headroom clamp owns that, see `agcPeakHeadroom`).
    func testNoiseLimitIsBoundedAtBothEnds() {
        for floorPercent in stride(from: 0.0, through: 20.0, by: 0.1) {
            let floor = Float(floorPercent) / 100
            for configured in [vpioCeiling, rawCeiling] {
                let allowed = AudioCapture.noiseLimitedMaxGain(configuredMaxGain: configured,
                                                               noiseFloorRms: floor)
                XCTAssertLessThanOrEqual(allowed, configured + 1e-4,
                                         "exceeded the configured ceiling at floor \(floorPercent)%")
                XCTAssertGreaterThanOrEqual(allowed, 1.0 - 1e-4,
                                            "became an attenuator at floor \(floorPercent)%")
            }
        }
    }

    /// An unknown floor (first buffer of a call / engine restart) must be
    /// permissive, not restrictive — otherwise every route change would mute
    /// the make-up stage for the ~100 ms the follower needs to seed.
    func testUnknownFloorLeavesTheConfiguredCeilingIntact() {
        XCTAssertEqual(AudioCapture.noiseLimitedMaxGain(configuredMaxGain: rawCeiling,
                                                        noiseFloorRms: 0),
                       rawCeiling, accuracy: 1e-4)
    }

    // MARK: - agcSnrGateRatio — fenced from BOTH sides

    /// Stationary background must NOT open the gate. This is the anti-pumping
    /// half: with the old absolute-only gate, car noise at 2 % RMS sailed past
    /// the 0.8 % threshold and the loop chased it to the ceiling.
    /// Fails if the ratio is lowered to ≤1.4.
    func testStationaryBackgroundDoesNotOpenTheGate() {
        XCTAssertFalse(AudioCapture.shouldAdaptMakeUpGain(bufferRms: 0.020,
                                                          noiseFloorRms: 0.020),
                       "the loop adapts on its own noise floor — it will pump")
        XCTAssertFalse(AudioCapture.shouldAdaptMakeUpGain(bufferRms: 0.028,
                                                          noiseFloorRms: 0.020),
                       "agcSnrGateRatio was lowered — floor wander re-opens the gate on noise")
    }

    /// ...but speech only 8 dB above the floor must STILL open it. This is the
    /// anti-faint half: a gate that only passes shouted speech would silently
    /// disable `agcTargetRms` in every real room.
    /// Fails if the ratio is raised above 2.5.
    func testQuietSpeechAboveTheFloorStillOpensTheGate() {
        XCTAssertTrue(AudioCapture.shouldAdaptMakeUpGain(bufferRms: 0.050,
                                                         noiseFloorRms: 0.020),
                      "agcSnrGateRatio was raised — genuinely quiet speech no longer "
                      + "qualifies, which re-opens the faint-mic regression")
    }

    /// The ABSOLUTE floor survives alongside the relative one. A buffer under
    /// the silence threshold is silence in any environment, even one whose
    /// tracked floor is an order of magnitude below it — otherwise a very quiet
    /// room would let the loop chase its own hiss (the W556 no-NS case).
    func testAbsoluteSilenceGateStillApplies() {
        XCTAssertFalse(AudioCapture.shouldAdaptMakeUpGain(bufferRms: 0.005,
                                                          noiseFloorRms: 0.0005),
                       "the absolute silence gate was removed — hiss can be pumped again")
    }

    /// With no floor estimate yet, the gate must degrade to exactly the
    /// pre-W-AGCNOISE behaviour (absolute test only). This is what lets the
    /// existing `AudioCaptureLevelControlTests` keep asserting the same law.
    func testUnknownFloorReproducesTheAbsoluteOnlyGate() {
        XCTAssertTrue(AudioCapture.shouldAdaptMakeUpGain(bufferRms: 0.009, noiseFloorRms: 0))
        XCTAssertFalse(AudioCapture.shouldAdaptMakeUpGain(bufferRms: 0.007, noiseFloorRms: 0))
    }

    // MARK: - The noise-floor follower — fenced from BOTH sides

    /// Fast DOWN: moving from a car into a quiet room (or a route change to a
    /// better mic) must be adopted within a few hundred ms, or the stale high
    /// floor would suppress the make-up stage long after the noise is gone.
    /// Fails if alphaDown < ~0.19.
    func testFloorTracksDownIntoAQuieterEnvironment() {
        var floor: Float = 0.05
        var buffers = 0
        while floor > 0.0105 && buffers < 200 {
            floor = AudioCapture.nextNoiseFloor(previous: floor, bufferRms: 0.01)
            buffers += 1
        }
        XCTAssertLessThanOrEqual(buffers, 20,
                                 "noiseFloorAlphaDown too slow — a stale floor keeps the "
                                 + "make-up suppressed after the noise is gone")
        // ...but not SO fast that it tracks the valleys inside speech, which
        // would make "the floor" follow the signal and disable the mechanism.
        // Fails if alphaDown > ~0.45.
        XCTAssertGreaterThan(buffers, 5,
                             "noiseFloorAlphaDown too fast — the floor will follow speech valleys")
    }

    /// Slow UP: a long continuous talk spurt must NOT drag the floor up to
    /// speech level. If it did, `noiseLimitedMaxGain` would see a "noisy" input
    /// whenever someone talks and the whole mechanism would invert again.
    /// 2 s of continuous speech at 3× the floor. Fails if alphaUp > ~0.0013.
    func testTalkSpurtDoesNotDragTheFloorUpToSpeechLevel() {
        let base: Float = 0.02
        var floor = base
        for _ in 0..<100 {   // 100 buffers × 20 ms = 2 s
            floor = AudioCapture.nextNoiseFloor(previous: floor, bufferRms: base * 3)
        }
        XCTAssertLessThan(floor, base * 1.25,
                          "noiseFloorAlphaUp too fast — speech is being absorbed into the "
                          + "background estimate, which re-inverts the ceiling")
    }

    /// ...but a genuinely louder environment must eventually be adopted, or a
    /// call that starts parked and continues at motorway speed would keep
    /// applying the quiet-room ceiling to a loud cabin.
    /// 60 s at 3× the floor. Fails if alphaUp < ~0.00054.
    func testSustainedlyLouderEnvironmentIsEventuallyAdopted() {
        let base: Float = 0.005
        let target = base * 3
        var floor = base
        for _ in 0..<3000 {   // 3000 buffers × 20 ms = 60 s
            floor = AudioCapture.nextNoiseFloor(previous: floor, bufferRms: target)
        }
        let progress = (floor - base) / (target - base)
        XCTAssertGreaterThan(progress, 0.8,
                             "noiseFloorAlphaUp too slow — a sustained environment change is "
                             + "never adopted (only \(progress * 100)% of the way)")
    }

    /// The first buffer seeds the estimate rather than starting from "perfectly
    /// clean", which would leave the ceiling unbounded for the ~25 s the slow-up
    /// path needs to climb — i.e. for most of a call.
    func testFirstBufferSeedsTheFloor() {
        XCTAssertEqual(AudioCapture.nextNoiseFloor(previous: 0, bufferRms: 0.031),
                       0.031, accuracy: 1e-6)
    }

    // MARK: - Ceiling collapse must be rate-limited

    /// `maxGain` is no longer a per-route constant: it moves with the floor. A
    /// collapse from the raw ceiling to unity is −15.6 dB, and the final clamp
    /// used to be unbounded, so it would have applied all of it inside ONE
    /// 20 ms buffer — a step the 1 ms de-zipper ramp turns into a click.
    /// The same −3 dB/buffer bound that governs a peak duck must govern this.
    func testCeilingCollapseIsRateLimitedNotStepped() {
        let one = AudioCapture.nextMakeUpAgcGain(previousGain: 6.0,
                                                 bufferRms: 0.02,
                                                 bufferPeak: 0.08,
                                                 maxGain: 1.0,
                                                 noiseFloorRms: 0.02)
        XCTAssertEqual(one, 6.0 * AudioCapture.agcMaxAttackStep, accuracy: 1e-4,
                       "a ceiling collapse is being applied as a single step — audible click")
    }

    /// ...and it must still CONVERGE, promptly. A rate limit that never
    /// arrives at the new ceiling would be a different bug.
    func testCeilingCollapseConvergesWithinTenBuffers() {
        var gain: Float = 6.0
        var buffers = 0
        while gain > 1.01 && buffers < 50 {
            gain = AudioCapture.nextMakeUpAgcGain(previousGain: gain,
                                                  bufferRms: 0.02,
                                                  bufferPeak: 0.08,
                                                  maxGain: 1.0,
                                                  noiseFloorRms: 0.02)
            buffers += 1
        }
        XCTAssertLessThanOrEqual(buffers, 10, "ceiling collapse takes over 200 ms to settle")
        XCTAssertEqual(gain, 1.0, accuracy: 1e-3)
    }

    // MARK: - End-to-end replay of the two real calls

    private struct ReplayResult {
        let maxGain: Float
        let meanGain: Double
        /// max/min applied gain in steady state — the BREATHING depth. This is
        /// the quantity the far end actually perceives as pumping, and the one
        /// no shipped metric measures today.
        let modulation: Float
    }

    /// Deterministic replay harness: a two-way conversation as a talk/listen
    /// cycle, running the REAL follower + REAL gain law.
    ///
    /// The listen phase is not decoration — it is what reproduces the failure.
    /// With only sub-second inter-word gaps the loop reaches ~3.8×; the real
    /// call reached 5.89, which needs ~3.5 s of continuous background for the
    /// τ ≈ 1 s rise to get that close to the 6.0 ceiling. A two-way call spends
    /// roughly half its time listening, which is exactly that. Calibration
    /// check: the "before" run below produces 5.96 against the measured 5.89.
    ///
    /// Statistics are taken over the SECOND HALF only, so the seeding transient
    /// (the follower starts from the first buffer it sees) cannot contaminate
    /// the steady-state comparison.
    private func replay(speechRms: Float, speechPeak: Float,
                        noiseRms: Float, noisePeak: Float,
                        voicedPercent: Int,
                        configuredCeiling: Float,
                        noiseAdaptive: Bool,
                        seconds: Int = 60) -> ReplayResult {
        var gain: Float = 1.0
        var floor: Float = 0
        var maxGain: Float = 1.0
        var minGain: Float = .greatestFiniteMagnitude
        var sum: Double = 0
        var count = 0
        let buffersPerSecond = 50
        let talkSeconds = 4
        let cycleSeconds = 8          // 4 s talking, 4 s listening
        let steadyStateFrom = seconds / 2
        for second in 0..<seconds {
            let talking = (second % cycleSeconds) < talkSeconds
            for i in 0..<buffersPerSecond {
                let voiced = talking && i < (voicedPercent * buffersPerSecond) / 100
                let rms = voiced ? speechRms : noiseRms
                let peak = voiced ? speechPeak : noisePeak
                floor = AudioCapture.nextNoiseFloor(previous: floor, bufferRms: rms)
                // A zero floor makes BOTH the gate and the ceiling degrade to
                // their pre-W-AGCNOISE forms, so `noiseAdaptive: false` is an
                // exact replay of the shipped behaviour — the A/B below differs
                // in one variable only.
                let effectiveFloor: Float = noiseAdaptive ? floor : 0
                let ceiling = noiseAdaptive
                    ? AudioCapture.noiseLimitedMaxGain(configuredMaxGain: configuredCeiling,
                                                       noiseFloorRms: effectiveFloor)
                    : configuredCeiling
                gain = AudioCapture.nextMakeUpAgcGain(previousGain: gain,
                                                      bufferRms: rms,
                                                      bufferPeak: peak,
                                                      maxGain: ceiling,
                                                      noiseFloorRms: effectiveFloor)
                if second >= steadyStateFrom {
                    if gain > maxGain { maxGain = gain }
                    if gain < minGain { minGain = gain }
                    sum += Double(gain)
                    count += 1
                }
            }
        }
        return ReplayResult(maxGain: maxGain,
                            meanGain: count > 0 ? sum / Double(count) : 1.0,
                            modulation: minGain > 0 ? maxGain / minGain : 1.0)
    }

    /// Call 1de9935f: car cabin, VP-IO bypassed so nothing suppresses the road
    /// noise. Speech well above the floor; the floor itself at 2 % FS.
    private func replayCar(noiseAdaptive: Bool) -> ReplayResult {
        let speechRms: Float = 0.06
        let speechPeak: Float = 0.30
        let noiseRms: Float = 0.02
        let noisePeak: Float = 0.08
        return replay(speechRms: speechRms, speechPeak: speechPeak,
                      noiseRms: noiseRms, noisePeak: noisePeak,
                      voicedPercent: 42,
                      configuredCeiling: rawCeiling, noiseAdaptive: noiseAdaptive)
    }

    /// Call d0f84651: earpiece, VP-IO on, so NS holds the floor down at 0.2 %
    /// FS. Same operating point the existing `testTargetRmsStillLiftsQuietVoiced
    /// Speech` uses for the speech buffers, so the two suites agree on what
    /// "quiet voiced speech" means.
    private func replayEarpiece(noiseAdaptive: Bool) -> ReplayResult {
        let speechRms: Float = 0.030
        let speechPeak: Float = 0.12
        let noiseRms: Float = 0.002
        let noisePeak: Float = 0.010
        return replay(speechRms: speechRms, speechPeak: speechPeak,
                      noiseRms: noiseRms, noisePeak: noisePeak,
                      voicedPercent: 30,
                      configuredCeiling: vpioCeiling, noiseAdaptive: noiseAdaptive)
    }

    /// CALL 1de9935f — car kit, VP-IO bypassed, no NS, no AEC. Reported "quasi
    /// incomprensibile". Measured: agc_gain 5.89 against a 6.0 ceiling.
    ///
    /// The A/B lives in ONE test on ONE signal so the comparison cannot drift.
    func testCarCabinNoLongerWindsTheLoopToTheCeiling() {
        let before = replayCar(noiseAdaptive: false)
        // The harness must REPRODUCE the reported failure, or the "after"
        // numbers prove nothing about the real call. Before: max ≈ 5.96 against
        // the 5.89 the device actually reported.
        XCTAssertGreaterThan(before.maxGain, 4.0,
                             "harness no longer reproduces the wind-up to the ceiling — "
                             + "the 'after' assertions below would be meaningless")
        XCTAssertGreaterThan(before.modulation, 2.0,
                             "harness no longer reproduces the gain breathing (measured ≈2.8×, 8.9 dB)")

        let after = replayCar(noiseAdaptive: true)
        XCTAssertLessThanOrEqual(after.maxGain, 1.2, "the loop still winds up on road noise")
        XCTAssertLessThanOrEqual(after.meanGain, 1.2, "the mean applied gain still lifts the cabin")
        XCTAssertLessThanOrEqual(after.modulation, 1.15,
                                 "the gain still breathes between speech and background — "
                                 + "that modulation IS the unintelligibility")
    }

    /// CALL d0f84651 — earpiece, VP-IO on, NS in circuit. Acceptable call, and
    /// its behaviour must be preserved EXACTLY. This is the guard that stops
    /// the car fix from degenerating into "turn the AGC down", which is the
    /// change that was proposed, reviewed and rejected earlier today (see
    /// `agcTargetRms`'s note on the 0.05 attempt).
    func testQuietEarpieceBehaviourIsUnchanged() {
        let before = replayEarpiece(noiseAdaptive: false)
        let after = replayEarpiece(noiseAdaptive: true)
        XCTAssertEqual(after.meanGain, before.meanGain, accuracy: 0.05,
                       "the noise ceiling is binding on a CLEAN input — this is the faint "
                       + "iOS mic regression 04f82f1/dcace27 exist to fix")
        XCTAssertGreaterThan(after.maxGain, 2.5, "quiet-mic make-up regressed")
        XCTAssertGreaterThan(after.meanGain, 2.0,
                             "the make-up is only reached transiently — the far end still hears it faint")
    }

    /// The two calls must remain DISTINGUISHABLE by this mechanism. If a future
    /// constant change made both behave alike, one of the two requirements has
    /// silently been given up — and which one would depend on which direction
    /// it moved, so neither single-sided test above would necessarily catch it.
    func testTheTwoRealCallsLandOnOppositeSidesOfTheMechanism() {
        let car = replayCar(noiseAdaptive: true)
        let earpiece = replayEarpiece(noiseAdaptive: true)
        XCTAssertGreaterThan(earpiece.meanGain, car.meanGain * 1.8,
                             "the clean and the noisy call now get comparable make-up gain — "
                             + "the ceiling has stopped discriminating on signal cleanliness")
    }

    // MARK: - W-VPIORETRY

    /// THE LATCH. `forceDisableVoiceProcessing` is set by the starve watchdog
    /// and was cleared only in `AudioCapture.stop()`, i.e. at CALL END. One
    /// 1.2 s tap starve during a car-kit route transition therefore condemned
    /// the remaining ~110 s of call 1de9935f to no AEC, no NS and no Apple AGC.
    func testRouteChangeAfterABypassRetriesVoiceProcessing() {
        XCTAssertTrue(AudioCapture.shouldRetryVoiceProcessing(bypassCount: 1,
                                                              restartIsRouteDriven: true),
                      "the VP-IO bypass is a one-way latch again — a transient starve "
                      + "during a route change kills AEC/NS for the whole call")
    }

    /// The watchdog's OWN restart must never retry: that is the iPad W574f case
    /// (VP-IO starves on a STABLE route), and retrying there would loop the
    /// engine between a dead mic and a bypass for the whole call.
    func testWatchdogRestartNeverRetries() {
        XCTAssertFalse(AudioCapture.shouldRetryVoiceProcessing(bypassCount: 1,
                                                               restartIsRouteDriven: false))
    }

    /// Bounded: a route that starves VP-IO every time costs at most
    /// `maxVoiceProcessingRetries` extra 1.2 s windows, never an unbounded loop.
    func testRetriesAreBounded() {
        let limit = AudioCapture.maxVoiceProcessingRetries
        XCTAssertTrue(AudioCapture.shouldRetryVoiceProcessing(bypassCount: limit,
                                                              restartIsRouteDriven: true))
        XCTAssertFalse(AudioCapture.shouldRetryVoiceProcessing(bypassCount: limit + 1,
                                                               restartIsRouteDriven: true),
                       "retries are unbounded — a permanently-starving route will flap forever")
        XCTAssertGreaterThanOrEqual(limit, 1,
                                    "retries disabled entirely — the one-way latch is back")
        XCTAssertLessThanOrEqual(limit, 3,
                                 "too many retries — each costs a 1.2 s dead-mic window")
    }

    /// Nothing to retry when VP-IO was never bypassed.
    func testNoRetryWithoutABypass() {
        XCTAssertFalse(AudioCapture.shouldRetryVoiceProcessing(bypassCount: 0,
                                                               restartIsRouteDriven: true))
    }
}
