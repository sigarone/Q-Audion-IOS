import XCTest
@testable import QAudionEngine

/// Fence for the STRESS gauge calibration (W-VOICEZERO follow-on).
///
/// Fixing the voicing gate alone would have swapped "always 0" for "always
/// agitated": the pre-fix composite was `min(1, (jitter*10 + shimmer*5)/2)`
/// on RATIO inputs, and Android's field-calibrated *normal* values for phone
/// audio (jitter 6 %, shimmer 12 %) put that formula at exactly 0.60 — the
/// threshold `InCallScreen.stressStatusWord` calls "agitated". The composite
/// is now the Android one (normalise against [normal, high], same weights,
/// same EMA), so the number a user sees means the same thing on both
/// platforms.
final class StressScorePolicyTests: XCTestCase {

    /// The exact pre-fix formula, kept so the regression is fenced by
    /// construction rather than by comment.
    private func legacyComposite(jitter: Float, shimmer: Float) -> Float {
        min(1.0, (jitter * 10 + shimmer * 5) / 2.0)
    }

    func testLegacyCompositeCalledCalmSpeechAgitated() {
        // Android's measured *normal* conversational values for a phone mic
        // with hardware AEC/NS/AGC (StressDetector.kt JITTER_NORMAL/SHIMMER_NORMAL).
        let legacy = legacyComposite(jitter: 0.06, shimmer: 0.12)
        XCTAssertEqual(legacy, 0.60, accuracy: 0.001)
        // Lands ON the "agitated" threshold. Asserted with a tolerance rather
        // than `>= 60`: in Float32 this evaluates to 59.999996, so an exact
        // comparison fails on a rounding artifact — CI caught precisely that.
        // The point being fenced is that calibrated-NORMAL speech scored at the
        // threshold under the old formula, which a 4e-6 gap does not change.
        XCTAssertEqual(legacy * 100, 60, accuracy: 0.001,
                       "Pre-fix formula classified calibrated-normal speech as 'agitated'")
    }

    func testCalibratedNormalSpeechScoresCalm() {
        let score = StressScorePolicy.compositeScore(jitter: 0.06, shimmer: 0.12,
                                                     f0StdDev: 35, tremor: 0.5)
        XCTAssertLessThan(score * 100, 35, "Normal speech must land in the 'calm' band")
        // Only the tremor term contributes at exactly-normal inputs.
        XCTAssertEqual(score, StressScorePolicy.weightTremor * 0.5, accuracy: 1e-5)
    }

    func testHighStressInputsSaturate() {
        let score = StressScorePolicy.compositeScore(jitter: 0.30, shimmer: 0.40,
                                                     f0StdDev: 200, tremor: 1)
        XCTAssertEqual(score, 1.0, accuracy: 1e-5)
    }

    func testScoreIsMonotonicInJitter() {
        let low = StressScorePolicy.compositeScore(jitter: 0.06, shimmer: 0.12, f0StdDev: 35, tremor: 0)
        let mid = StressScorePolicy.compositeScore(jitter: 0.10, shimmer: 0.12, f0StdDev: 35, tremor: 0)
        let high = StressScorePolicy.compositeScore(jitter: 0.15, shimmer: 0.12, f0StdDev: 35, tremor: 0)
        XCTAssertLessThan(low, mid)
        XCTAssertLessThan(mid, high)
    }

    func testNormalizeClampsBothEnds() {
        XCTAssertEqual(StressScorePolicy.normalize(1, normal: 6, high: 15), 0)
        XCTAssertEqual(StressScorePolicy.normalize(6, normal: 6, high: 15), 0)
        XCTAssertEqual(StressScorePolicy.normalize(10.5, normal: 6, high: 15), 0.5, accuracy: 1e-5)
        XCTAssertEqual(StressScorePolicy.normalize(99, normal: 6, high: 15), 1)
        // Degenerate range must not divide by zero.
        XCTAssertEqual(StressScorePolicy.normalize(7, normal: 6, high: 6), 1)
        XCTAssertEqual(StressScorePolicy.normalize(5, normal: 6, high: 6), 0)
    }

    func testRelativeMeanAbsDiff() {
        XCTAssertEqual(StressScorePolicy.relativeMeanAbsDiff([]), 0)
        XCTAssertEqual(StressScorePolicy.relativeMeanAbsDiff([120]), 0)
        XCTAssertEqual(StressScorePolicy.relativeMeanAbsDiff([120, 120, 120]), 0)
        // mean |Δ| = 100, mean value = 150 → 0.6667
        XCTAssertEqual(StressScorePolicy.relativeMeanAbsDiff([100, 200, 100, 200]),
                       0.6667, accuracy: 0.001)
        // All-zero history must not divide by zero.
        XCTAssertEqual(StressScorePolicy.relativeMeanAbsDiff([0, 0, 0]), 0)
    }

    func testStdDev() {
        XCTAssertEqual(StressScorePolicy.stdDev([]), 0)
        XCTAssertEqual(StressScorePolicy.stdDev([5]), 0)
        XCTAssertEqual(StressScorePolicy.stdDev([10, 10, 10, 10]), 0)
        // sample stddev of [2,4,4,4,5,5,7,9] with n-1 = 2.138
        XCTAssertEqual(StressScorePolicy.stdDev([2, 4, 4, 4, 5, 5, 7, 9]), 2.138, accuracy: 0.01)
    }

    func testTremor() {
        XCTAssertEqual(StressScorePolicy.tremor([1, 2, 3]), 0, "needs >= 4 points")
        XCTAssertEqual(StressScorePolicy.tremor([100, 110, 120, 130, 140]), 0,
                       "monotonic contour = no tremor")
        XCTAssertEqual(StressScorePolicy.tremor([100, 200, 100, 200, 100, 200]), 1,
                       "every step reverses = maximal tremor")
    }

    func testSmoothIsAnEmaStepAndStaysBounded() {
        XCTAssertEqual(StressScorePolicy.smooth(previous: 0, raw: 1),
                       StressScorePolicy.emaAlpha, accuracy: 1e-6)
        XCTAssertEqual(StressScorePolicy.smooth(previous: 0.5, raw: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(StressScorePolicy.smooth(previous: 1, raw: 1), 1)
        XCTAssertGreaterThanOrEqual(StressScorePolicy.smooth(previous: 0, raw: 0), 0)
    }

    // MARK: - Through StressDetector

    func testDetectorConvergesTowardsCalmForSteadyVoicedSpeech() {
        let detector = StressDetector()
        var last: Float = 0
        // Mildly varying F0/RMS — a calm speaker.
        for i in 0..<200 {
            let f0: Float = 120 + Float(i % 5)
            let rms: Float = 0.05 + Float(i % 3) * 0.001
            last = detector.analyze(pitch: .init(f0Hz: f0, voiced: true, rms: rms)).score
        }
        XCTAssertLessThan(last * 100, 35, "Steady voiced speech must read 'calm', not 'agitated'")
    }

    func testDetectorDecaysWhileUnvoicedInsteadOfSnappingToZero() {
        let detector = StressDetector()
        // Push the score up with a wildly unstable contour.
        for i in 0..<80 {
            let f0: Float = i % 2 == 0 ? 90 : 320
            let rms: Float = i % 2 == 0 ? 0.02 : 0.20
            _ = detector.analyze(pitch: .init(f0Hz: f0, voiced: true, rms: rms))
        }
        let stressed = detector.analyze(pitch: .init(f0Hz: 90, voiced: true, rms: 0.02)).score
        XCTAssertGreaterThan(stressed, 0.2, "Unstable contour must actually register as stress")

        let afterOneSilentFrame = detector.analyze(pitch: .init(f0Hz: 0, voiced: false, rms: 0)).score
        XCTAssertEqual(afterOneSilentFrame, stressed * StressScorePolicy.unvoicedDecay, accuracy: 1e-5)

        var score = afterOneSilentFrame
        for _ in 0..<200 { score = detector.analyze(pitch: .init(f0Hz: 0, voiced: false, rms: 0)).score }
        XCTAssertLessThan(score, 0.01, "Sustained silence must still drain the gauge")
    }

    func testDetectorResetClearsState() {
        let detector = StressDetector()
        for i in 0..<40 {
            _ = detector.analyze(pitch: .init(f0Hz: i % 2 == 0 ? 100 : 300, voiced: true, rms: 0.1))
        }
        detector.reset()
        let afterReset = detector.analyze(pitch: .init(f0Hz: 120, voiced: true, rms: 0.05))
        XCTAssertEqual(afterReset.score, 0, accuracy: 1e-6)
        XCTAssertEqual(afterReset.jitter, 0, accuracy: 1e-6)
    }
}
