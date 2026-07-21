import XCTest
@testable import QAudionEngine

/// Regression fence for W-VOICEZERO (2026-07-21): the Guardian-ribbon
/// STRESS / BREATH·HNR / PITCH gauges read exactly 0 on every 1:1 call
/// because `PitchExtractor` compared an UN-NORMALISED autocorrelation
/// against a threshold (0.3) that only makes sense for a normalised
/// coefficient, so `voiced` was false at every realistic call level and
/// every downstream analyzer early-returned zeros.
///
/// The old unit tests missed it because they only ever fed
/// `amplitude: 0.8` sines (rms 0.566 → raw correlation 0.320, clearing the
/// gate by 6 %). These tests deliberately exercise REAL call levels:
/// live fleet telemetry (`call.audio.diag`, iOS 1.0.826, call e65013b7)
/// measured whole-call RX `rx_rms_pct = 3.8` / `rx_peak_pct = 59.5`.
final class VoicedDecisionPolicyTests: XCTestCase {

    private let sampleRate: Float = 48000
    private let minLag = 80    // 600 Hz
    private let maxLag = 480   // 100 Hz (960-sample frame / 2)

    // MARK: - Helpers

    private func sine(_ frequency: Float, count: Int = 960, amplitude: Float) -> [Float] {
        (0..<count).map { i in
            amplitude * sin(2 * Float.pi * frequency * Float(i) / sampleRate)
        }
    }

    /// Harmonic-rich glottal-ish pulse with a WEAK fundamental — the classic
    /// octave-error trap for plain arg-max autocorrelation.
    private func weakFundamental(_ f0: Float, count: Int = 960, amplitude: Float) -> [Float] {
        (0..<count).map { i in
            let t = Float(i) / sampleRate
            return amplitude * (0.4 * sin(2 * Float.pi * f0 * t)
                                + 1.0 * sin(2 * Float.pi * 2 * f0 * t)
                                + 0.7 * sin(2 * Float.pi * 3 * f0 * t))
        }
    }

    /// Deterministic pseudo-noise (no dependency on system RNG seeding).
    private func whiteNoise(count: Int = 960, amplitude: Float) -> [Float] {
        var state: Int64 = 12345
        return (0..<count).map { _ in
            state = (state &* 1103515245 &+ 12345) & 0x7fff_ffff
            let unit = Float(Double(state) / Double(0x7fff_ffff)) * 2 - 1
            return unit * amplitude
        }
    }

    /// The EXACT pre-fix computation, reproduced so the bug itself is fenced
    /// and not just the fix: mean of products, no energy normalisation.
    private func legacyRawCorrelation(_ samples: [Float], lag: Int) -> Float {
        var corr: Float = 0
        for i in 0..<(samples.count - lag) { corr += samples[i] * samples[i + lag] }
        return corr / Float(samples.count - lag)
    }

    // MARK: - The bug

    func testLegacyRawCorrelationFailsTheGateAtRealCallLevels() {
        // 200 Hz at amplitude 0.05 (rms ≈ 0.035, i.e. the 3.8 % RX RMS the
        // fleet actually reports) — perfectly periodic, obviously voiced.
        let samples = sine(200, amplitude: 0.05)
        let legacy = legacyRawCorrelation(samples, lag: 240)

        XCTAssertLessThan(legacy, VoicedDecisionPolicy.voicedCorrelationThreshold,
                          "Pre-fix formula: a clean 200 Hz tone at real call level scored \(legacy), far under the 0.3 gate — this is why every gauge read 0")
        // And it is the amplitude, not the periodicity, that decides:
        XCTAssertEqual(legacy, 0.00125, accuracy: 0.0002,
                       "Raw mean-of-products at the true period is ≈ rms², not a correlation coefficient")
    }

    func testNormalizedCorrelationClearsTheGateAtTheSameLevel() {
        let samples = sine(200, amplitude: 0.05)
        let r = VoicedDecisionPolicy.normalizedAutocorrelation(samples, lag: 240)
        XCTAssertGreaterThan(r, VoicedDecisionPolicy.voicedCorrelationThreshold)
        XCTAssertEqual(r, 1.0, accuracy: 0.01, "r(T) of a pure tone at its period is ~1")
    }

    // MARK: - Amplitude invariance (the actual property that was missing)

    func testCorrelationIsAmplitudeInvariant() {
        let loud = VoicedDecisionPolicy.normalizedAutocorrelation(sine(200, amplitude: 0.8), lag: 240)
        let quiet = VoicedDecisionPolicy.normalizedAutocorrelation(sine(200, amplitude: 0.02), lag: 240)
        XCTAssertEqual(loud, quiet, accuracy: 0.01,
                       "A normalised coefficient must not depend on level — that dependence WAS the bug")
    }

    func testVoicedAtEveryRealisticCallLevel() {
        for amplitude in [Float(0.8), 0.3, 0.1, 0.05, 0.02] {
            let samples = sine(200, amplitude: amplitude)
            let rms = VoicedDecisionPolicy.rms(samples)
            let estimate = VoicedDecisionPolicy.bestPeriod(samples, minLag: minLag, maxLag: maxLag)
            let f0 = sampleRate / estimate.lag
            XCTAssertTrue(
                VoicedDecisionPolicy.isVoiced(correlation: estimate.correlation, f0Hz: f0,
                                              rms: rms, minF0: 50, maxF0: 600),
                "200 Hz tone at amplitude \(amplitude) (rms \(rms)) must be voiced")
            XCTAssertEqual(f0, 200, accuracy: 5, "F0 must be level-independent too")
        }
    }

    // MARK: - Period selection

    func testOctaveGuardPicksTheFundamentalNotAHarmonicPeriod() {
        for f0 in [Float(120), 150, 200] {
            let samples = weakFundamental(f0, amplitude: 0.05)
            let estimate = VoicedDecisionPolicy.bestPeriod(samples, minLag: minLag, maxLag: maxLag)
            XCTAssertEqual(sampleRate / estimate.lag, f0, accuracy: 3,
                           "Weak-fundamental harmonic stack must still resolve to \(f0) Hz")
        }
    }

    func testCurveAgreesWithStandaloneAutocorrelation() {
        let samples = sine(180, amplitude: 0.1)
        let curve = VoicedDecisionPolicy.correlationCurve(samples, minLag: minLag, maxLag: maxLag)
        XCTAssertEqual(curve.count, maxLag - minLag + 1)
        for lag in [minLag, 137, 267, maxLag] {
            XCTAssertEqual(curve[lag - minLag],
                           VoicedDecisionPolicy.normalizedAutocorrelation(samples, lag: lag),
                           accuracy: 1e-4,
                           "prefix-sum curve must match the direct computation at lag \(lag)")
        }
    }

    func testParabolicPeakOffsetIsClampedAndCentred() {
        XCTAssertEqual(VoicedDecisionPolicy.parabolicPeakOffset(0.5, 1.0, 0.5), 0, accuracy: 1e-6)
        XCTAssertEqual(VoicedDecisionPolicy.parabolicPeakOffset(1, 1, 1), 0, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(abs(VoicedDecisionPolicy.parabolicPeakOffset(0.9, 1.0, 0.1)), 0.5)
    }

    // MARK: - Negative cases must stay negative

    func testWhiteNoiseIsNotVoiced() {
        let samples = whiteNoise(amplitude: 0.3)
        let rms = VoicedDecisionPolicy.rms(samples)
        let estimate = VoicedDecisionPolicy.bestPeriod(samples, minLag: minLag, maxLag: maxLag)
        XCTAssertGreaterThan(rms, VoicedDecisionPolicy.minRms, "noise is loud enough to pass the RMS gate")
        XCTAssertFalse(
            VoicedDecisionPolicy.isVoiced(correlation: estimate.correlation,
                                          f0Hz: sampleRate / max(estimate.lag, 1),
                                          rms: rms, minF0: 50, maxF0: 600),
            "Aperiodic noise must not be voiced (correlation was \(estimate.correlation))")
    }

    func testSilenceIsNotVoiced() {
        let samples = [Float](repeating: 0, count: 960)
        XCTAssertEqual(VoicedDecisionPolicy.rms(samples), 0)
        XCTAssertFalse(VoicedDecisionPolicy.isVoiced(correlation: 1, f0Hz: 200, rms: 0,
                                                     minF0: 50, maxF0: 600),
                       "The RMS floor must still veto a perfect correlation on silence")
    }

    func testOutOfRangeF0IsNotVoiced() {
        XCTAssertFalse(VoicedDecisionPolicy.isVoiced(correlation: 0.99, f0Hz: 40, rms: 0.2,
                                                     minF0: 50, maxF0: 600))
        XCTAssertFalse(VoicedDecisionPolicy.isVoiced(correlation: 0.99, f0Hz: 900, rms: 0.2,
                                                     minF0: 50, maxF0: 600))
    }

    func testEmptyAndDegenerateInputsAreSafe() {
        XCTAssertEqual(VoicedDecisionPolicy.rms([]), 0)
        XCTAssertEqual(VoicedDecisionPolicy.normalizedAutocorrelation([], lag: 10), 0)
        XCTAssertEqual(VoicedDecisionPolicy.normalizedAutocorrelation([1, 2, 3], lag: 0), 0)
        XCTAssertTrue(VoicedDecisionPolicy.correlationCurve([1, 2, 3], minLag: 10, maxLag: 20).isEmpty)
        let degenerate = VoicedDecisionPolicy.bestPeriod([1, 2, 3], minLag: 10, maxLag: 20)
        XCTAssertEqual(degenerate.lag, 0)
        XCTAssertEqual(degenerate.correlation, 0)
    }

    // MARK: - End-to-end through PitchExtractor

    func testPitchExtractorDetectsRealCallLevelSpeechTone() {
        let extractor = PitchExtractor()
        // amplitude 0.05 ≈ the RX level the fleet actually reports; the old
        // implementation returned voiced=false / f0=0 for exactly this input.
        let pcm = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960, amplitude: 0.05)
        let result = extractor.extract(pcmFrame: pcm)
        XCTAssertTrue(result.voiced, "Real-call-level tone must be voiced")
        XCTAssertEqual(result.f0Hz, 200, accuracy: 6)
        XCTAssertGreaterThan(result.rms, VoicedDecisionPolicy.minRms)
    }

    func testPitchExtractorStillRejectsSilenceAndNearSilence() {
        let extractor = PitchExtractor()
        XCTAssertFalse(extractor.extract(pcmFrame: TestAudioHelpers.makeSilentPCM(sampleCount: 960)).voiced)
        let tiny = TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: 960, amplitude: 0.001)
        XCTAssertFalse(extractor.extract(pcmFrame: tiny).voiced)
    }
}
