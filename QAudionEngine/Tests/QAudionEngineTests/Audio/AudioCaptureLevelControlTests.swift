import XCTest
@testable import QAudionEngine

/// W-AGCCEIL (2026-07-21) — regression tests for the make-up AGC control law
/// (`AudioCapture.nextMakeUpAgcGain`) and for the level-staging invariants it
/// depends on.
///
/// THE BUG THIS LOCKS DOWN. The far end reported iOS audio sounding "metallic",
/// worsening across releases. Server telemetry (`call.audio.diag`, iOS leg) on
/// the four calls after commit dcace27 restored the VP-IO make-up AGC:
///
///     call       ver       peak%   rms%   clip   agc_gain
///     f884668c   1.0.825    97.9    5.6     29     1.94
///     e65013b7   1.0.826    97.8    4.0     29     2.47
///     84c06f73   1.0.826    96.7    4.4      0     1.99
///     076e32f0   1.0.827    98.0    3.8    405     2.74
///
/// Two facts follow from arithmetic on the soft-knee curve, not from taste:
///
///   1. The limiter's output asymptote is exactly `limiterCeiling` × 32767 =
///      32112, i.e. peak_pct 98.0. Every one of those peaks lies ON that curve,
///      and none can reach 100.0 — whereas the same builds BEFORE the make-up
///      AGC was restored logged peak_pct exactly 100.0. So the limiter was in
///      circuit on every call. Working back through the curve, the PRE-limiter
///      peak had been driven to 1.045–1.251 × full scale.
///   2. The gain was therefore sitting +1.3 to +2.8 dB ABOVE its own peak-safe
///      value, because `agcPeakHeadroom` was applied to the one-pole's TARGET
///      rather than to the applied gain, and the downward time constant was
///      ~400 ms. A memoryless soft-knee waveshaper engaged continuously is
///      continuous harmonic distortion — the metallic timbre.
///
/// The law below enforces the ceiling on the RESULT. These tests exist so that a
/// later refactor cannot quietly revert it, which is precisely what happened to
/// the sibling fix (a542727 silently undid 04f82f1 four hours later, unnoticed
/// for eight days — see `AudioCaptureAgcGateTests`).
///
/// Pure arithmetic only: no AVFoundation, no WebRTC, so this runs on the macOS
/// CI runner via `swift test`.
final class AudioCaptureLevelControlTests: XCTestCase {

    private let vpioCeiling: Float = 3.0   // AudioCapture.selectMakeUpAgcMaxGain(vpioActive: true)

    // MARK: - Stage staging invariants

    /// THE STRUCTURAL BUG: the AGC ceiling and the limiter knee used to be the
    /// SAME number (0.90). Two stages sharing a threshold overlap by
    /// construction — the instant the AGC reached its ceiling the limiter was
    /// already at its knee, so the limiter could never act as a backstop. The
    /// knee must sit strictly above the ceiling the AGC aims for.
    func testLimiterKneeSitsAboveAgcCeiling() {
        XCTAssertGreaterThan(AudioCapture.limiterKnee, AudioCapture.agcPeakHeadroom)
    }

    func testLimiterCeilingSitsAboveItsKnee() {
        XCTAssertGreaterThan(AudioCapture.limiterCeiling, AudioCapture.limiterKnee)
    }

    /// THE MEASUREMENT BUG: the clip counter's threshold used to be 31800
    /// (97.05% FS), BELOW the limiter's output ceiling (98.0% FS). Limiter
    /// output therefore landed inside the "clip" band and `clip_samples`
    /// reported limiter activity as clipping. The live data shows it exactly:
    /// the only post-dcace27 call reporting 0 clips (84c06f73) is the only one
    /// whose peak, 96.7%, fell below 97.05%.
    func testClipThresholdIsAboveTheLimiterCeiling() {
        let limiterMaxOutput = AudioCapture.limiterCeiling * Float(Int16.max)
        XCTAssertGreaterThan(Float(AudioCapture.clipThreshold), limiterMaxOutput,
                             "a soft-knee-shaped sample must never be counted as a clip")
    }

    // MARK: - The core invariant

    /// The ceiling must bind the APPLIED gain, not merely the smoothing target.
    /// Swept across the whole plausible peak range so this cannot pass by luck.
    func testPeakCeilingBindsTheAppliedGain() {
        for peakPercent in stride(from: 5, through: 100, by: 5) {
            let peak = Float(peakPercent) / 100
            // Start from the ceiling: the worst case is a gain already wound up.
            let gain = AudioCapture.nextMakeUpAgcGain(previousGain: vpioCeiling,
                                                     bufferRms: 0.02,
                                                     bufferPeak: peak,
                                                     maxGain: vpioCeiling)
            // Either the ceiling is met, or the bounded attack is still working
            // its way down — never anything else.
            let peakSafe = AudioCapture.agcPeakHeadroom / peak
            let attackFloor = vpioCeiling * AudioCapture.agcMaxAttackStep
            let allowed = max(peakSafe, min(attackFloor, vpioCeiling))
            XCTAssertLessThanOrEqual(gain, allowed + 1e-4,
                                     "peak \(peakPercent)% escaped both the ceiling and the attack bound")
        }
    }

    /// Replay of the real overdrive. On a buffer whose peak alone permits ~2.0×,
    /// the OLD law moved the gain only 5% of the way there (one-pole, alpha
    /// 0.05) and kept applying ~2.7× — which is how post-gain peaks reached
    /// 1.045–1.251 × full scale. The new law lands ON the safe value in one
    /// buffer, because that drop (−2.7 dB) is inside the attack bound.
    func testOnsetIsMetInOneBufferWhenWithinTheAttackBound() {
        let previous: Float = 2.74          // the max gain call 076e32f0 reached
        let peak: Float = 0.45
        let gain = AudioCapture.nextMakeUpAgcGain(previousGain: previous,
                                                 bufferRms: 0.02,
                                                 bufferPeak: peak,
                                                 maxGain: vpioCeiling)
        let peakSafe = AudioCapture.agcPeakHeadroom / peak   // 2.0
        XCTAssertEqual(gain, peakSafe, accuracy: 1e-4)
        // And the consequence that actually matters: the limiter stays out of
        // circuit, because the post-gain peak is below its knee.
        XCTAssertLessThan(gain * peak, AudioCapture.limiterKnee)

        // The old behaviour, kept explicit so the contrast is not lost: target
        // clamped, applied gain smoothed toward it at alpha 0.05.
        let oldGain = previous + (peakSafe - previous) * 0.05
        XCTAssertGreaterThan(oldGain * peak, AudioCapture.limiterKnee,
                             "the pre-fix law is expected to overdrive into the limiter")
    }

    // MARK: - Bounded attack

    /// A single full-scale outlier sample (a lip smack — call 4b8cacde logged
    /// exactly one in an entire call) must not duck the whole 20 ms buffer to
    /// unity, which would be ~9 dB and audible as a hole.
    func testSingleFullScaleOutlierCannotPunchAHole() {
        let previous: Float = 2.74
        let gain = AudioCapture.nextMakeUpAgcGain(previousGain: previous,
                                                 bufferRms: 0.02,
                                                 bufferPeak: 1.0,
                                                 maxGain: vpioCeiling)
        XCTAssertEqual(gain, previous * AudioCapture.agcMaxAttackStep, accuracy: 1e-4)
        XCTAssertGreaterThan(gain, 1.0, "must not collapse to unity on one sample")
    }

    /// But a GENUINE sustained level rise must still converge quickly — the old
    /// 400 ms release is what left the limiter engaged across whole onsets.
    func testSustainedLoudLevelConvergesWithinAFewBuffers() {
        var gain: Float = 3.0
        // peak 0.6 ⇒ peakSafe 1.5, i.e. a target the boost-only stage can
        // actually reach. (At peak 1.0 peakSafe is 0.9, below the unity floor,
        // so the signal is simply passed through and there is nothing to
        // converge to — that case is covered by testNeverAttenuates.)
        let peak: Float = 0.6
        var buffers = 0
        while gain * peak > AudioCapture.agcPeakHeadroom + 1e-4 && buffers < 50 {
            gain = AudioCapture.nextMakeUpAgcGain(previousGain: gain,
                                                 bufferRms: 0.02,
                                                 bufferPeak: peak,
                                                 maxGain: vpioCeiling)
            buffers += 1
        }
        // ~20 ms per buffer: converges in 3 (~60 ms), versus the ~400 ms the
        // old one-pole took — which is why the limiter used to eat whole onsets.
        XCTAssertLessThanOrEqual(buffers, 5, "attack too slow — limiter would stay engaged")
        XCTAssertEqual(gain, AudioCapture.agcPeakHeadroom / peak, accuracy: 1e-4)
    }

    // MARK: - Steady state

    /// The end-to-end property the whole change exists for: once settled on
    /// steady speech, the post-gain peak sits at the AGC ceiling, strictly below
    /// the limiter knee, so the waveshaper contributes nothing.
    func testSettledGainKeepsSignalOutOfTheLimiter() {
        for peakPercent in [20, 30, 40, 50, 60, 80] {
            let peak = Float(peakPercent) / 100
            var gain: Float = 1.0
            for _ in 0..<400 {
                gain = AudioCapture.nextMakeUpAgcGain(previousGain: gain,
                                                     bufferRms: peak / 15,   // ~23 dB crest
                                                     bufferPeak: peak,
                                                     maxGain: vpioCeiling)
            }
            XCTAssertLessThanOrEqual(gain * peak, AudioCapture.agcPeakHeadroom + 1e-4)
            XCTAssertLessThan(gain * peak, AudioCapture.limiterKnee)
        }
    }

    /// dcace27's win must not be given back: a quiet mic still gets lifted.
    /// Pre-dcace27 telemetry on this route measured rms 0.7–2.5%; the stage has
    /// to be clearly above unity on that material.
    func testQuietMicIsStillLifted() {
        var gain: Float = 1.0
        for _ in 0..<400 {
            gain = AudioCapture.nextMakeUpAgcGain(previousGain: gain,
                                                 bufferRms: 0.015,
                                                 bufferPeak: 0.30,
                                                 maxGain: vpioCeiling)
        }
        XCTAssertGreaterThan(gain, 2.0, "quiet-mic make-up regressed")
    }

    /// W-AGCCEIL — regression guard WITH REAL POWER over `agcTargetRms`.
    ///
    /// `testQuietMicIsStillLifted` above is, by itself, blind to that constant:
    /// at rms 0.015 / peak 0.30 BOTH the RMS term and the peak term independently
    /// saturate at the 3.0 ceiling, so it passes for any target in roughly
    /// (0.045, 0.12] and cannot catch the target being lowered. Adversarial
    /// review caught that, and caught a first cut of this fix lowering the target
    /// to 0.05 — which strips up to 7.6 dB of make-up gain and re-opens the faint
    /// iOS mic that 04f82f1/dcace27 exist to fix.
    ///
    /// This operating point is chosen so the RMS term is the ONLY thing that
    /// binds: quiet-but-real voiced speech, rms 3%, crest ~4 (peak 12%), so the
    /// peak ceiling permits 7.5x and never clamps. The achieved gain is then a
    /// direct read-out of the target: 0.12 -> 4.0 (capped 3.0), 0.05 -> 1.67.
    /// If anyone lowers the target again, this fails.
    func testTargetRmsStillLiftsQuietVoicedSpeech() {
        let rms: Float = 0.03
        let peak: Float = 0.12
        // Sanity: this point is genuinely peak-unconstrained, so the assertion
        // below really is measuring the RMS term and not the ceiling.
        XCTAssertGreaterThan(AudioCapture.agcPeakHeadroom / peak, vpioCeiling,
                             "test point no longer isolates the RMS term")
        var gain: Float = 1.0
        for _ in 0..<400 {
            gain = AudioCapture.nextMakeUpAgcGain(previousGain: gain,
                                                 bufferRms: rms,
                                                 bufferPeak: peak,
                                                 maxGain: vpioCeiling)
        }
        XCTAssertGreaterThan(gain, 2.5,
                             "agcTargetRms was lowered — quiet voiced speech is under-amplified again")
    }

    // MARK: - Guards

    func testNeverAttenuates() {
        for peak in [Float(0.5), 0.9, 0.99, 1.0] {
            let gain = AudioCapture.nextMakeUpAgcGain(previousGain: 1.0,
                                                     bufferRms: 0.30,
                                                     bufferPeak: peak,
                                                     maxGain: vpioCeiling)
            XCTAssertGreaterThanOrEqual(gain, 1.0)
        }
    }

    func testNeverExceedsTheCeiling() {
        var gain: Float = 1.0
        for _ in 0..<2000 {
            gain = AudioCapture.nextMakeUpAgcGain(previousGain: gain,
                                                 bufferRms: 0.009,   // just above the noise gate
                                                 bufferPeak: 0.01,
                                                 maxGain: vpioCeiling)
        }
        XCTAssertLessThanOrEqual(gain, vpioCeiling + 1e-4)
    }

    /// Below the noise gate the loop holds, so background hiss is never pumped
    /// (VP-IO's noise suppression is off on this route — W556).
    func testSilenceHoldsTheGain() {
        let gain = AudioCapture.nextMakeUpAgcGain(previousGain: 2.5,
                                                 bufferRms: 0.001,
                                                 bufferPeak: 0.0,
                                                 maxGain: vpioCeiling)
        XCTAssertEqual(gain, 2.5, accuracy: 1e-6)
    }

    /// ...but a loud transient arriving during an otherwise sub-gate buffer must
    /// still be capped. The old law skipped the peak term entirely inside the
    /// noise gate, so this case was unprotected.
    func testTransientDuringSubGateBufferIsStillCapped() {
        let gain = AudioCapture.nextMakeUpAgcGain(previousGain: 2.5,
                                                 bufferRms: 0.001,
                                                 bufferPeak: 0.95,
                                                 maxGain: vpioCeiling)
        XCTAssertLessThan(gain, 2.5)
        XCTAssertEqual(gain, 2.5 * AudioCapture.agcMaxAttackStep, accuracy: 1e-4)
    }
}
