import XCTest
@testable import QAudionEngine

/// The extractor works on the 60 ms window (16 kHz view), not on a single
/// buffer. See `PitchExtractor` for the method; the numbers below are the ones of
/// the specification in docs/voice-analysis-spec.md (digital-silence floor 1e-4,
/// periodicity 0.45, range 60-400 Hz).
final class PitchExtractorTests: XCTestCase {
    private var extractor: PitchExtractor!

    override func setUp() {
        super.setUp()
        extractor = PitchExtractor()
    }

    private func estimate(_ x: [Double]) -> PitchExtractor.Estimate {
        extractor.extract(window: SyntheticVoice.window(of: x))
    }

    func testSine300HzDetectsVoiced() {
        let r = estimate(SyntheticVoice.sine(frequency: 300, seconds: 0.2, amplitude: 0.8))
        XCTAssertTrue(r.voiced, "A 300 Hz sine wave should be detected as voiced")
        XCTAssertEqual(r.f0Hz, 300, accuracy: 9)
        XCTAssertGreaterThan(r.rms, 0.5)
        XCTAssertGreaterThan(r.periodicity, 0.9)
    }

    func testSine200HzDetectsVoiced() {
        let r = estimate(SyntheticVoice.sine(frequency: 200, seconds: 0.2, amplitude: 0.8))
        XCTAssertTrue(r.voiced)
        XCTAssertEqual(r.f0Hz, 200, accuracy: 6)
    }

    func testLowVoicesAreFoundOnThe60msWindow() {
        // The buffer-at-a-time extractor could not search below ~200 Hz on 10 ms.
        for f0 in [70.0, 85.0, 100.0, 130.0] {
            let r = estimate(SyntheticVoice.sine(frequency: f0, seconds: 0.2, amplitude: 0.5))
            XCTAssertTrue(r.voiced, "\(f0) Hz")
            XCTAssertEqual(r.f0Hz, f0, accuracy: f0 * 0.03, "\(f0) Hz")
        }
    }

    func testNoOctaveErrorOnVowels() {
        for f0 in [100.0, 220.0] {
            for vowel in [SyntheticVoice.a, SyntheticVoice.i, SyntheticVoice.u] {
                let x = SyntheticVoice.vowel(f0: f0, vowel, seconds: 0.3)
                for end in [4_000, 6_500, 9_000, 12_000] {
                    let r = extractor.extract(window: SyntheticVoice.window(of: x, endingAt: end))
                    XCTAssertTrue(r.voiced)
                    XCTAssertEqual(r.f0Hz, f0, accuracy: f0 * 0.03, "f0 \(f0), window ending at \(end)")
                }
            }
        }
    }

    func testTheEdgesOfTheRangeAreFound() {
        // 390 Hz is a period of 41 samples at 16 kHz, close to the lower lag bound; 62 Hz is
        // close to the upper one. Both must be found, because the search runs beyond 60-400 Hz.
        for f in [62.0, 390.0] {
            let r = estimate(SyntheticVoice.sine(frequency: f, seconds: 0.2, amplitude: 0.5))
            XCTAssertTrue(r.voiced, "\(f) Hz")
            XCTAssertEqual(r.f0Hz, f, accuracy: f * 0.03, "\(f) Hz")
        }
    }

    func testNeverReportsAnOutOfRangePitch() {
        // Outside 60-400 Hz the window is unvoiced, or a pitch inside the range, but never a number
        // outside it. A 50 Hz hum and a 420 Hz tone are on the unvoiced side of that.
        for f in [50.0, 420.0, 450.0, 520.0, 700.0] {
            let r = estimate(SyntheticVoice.sine(frequency: f, seconds: 0.2, amplitude: 0.5))
            XCTAssertTrue(!r.voiced || (r.f0Hz >= VoiceDsp.minF0Hz && r.f0Hz <= VoiceDsp.maxF0Hz), "\(f) Hz")
        }
        XCTAssertFalse(estimate(SyntheticVoice.sine(frequency: 50, seconds: 0.2, amplitude: 0.5)).voiced, "50 Hz hum")
        XCTAssertFalse(estimate(SyntheticVoice.sine(frequency: 420, seconds: 0.2, amplitude: 0.5)).voiced, "420 Hz tone")
    }

    func testSilentWindowReturnsUnvoicedWithNoPeriodicity() {
        let r = estimate([Double](repeating: 0, count: 4_000))
        XCTAssertFalse(r.voiced, "Silent audio should not be voiced")
        XCTAssertEqual(r.f0Hz, 0, "Pitch should be zero for silence")
        XCTAssertEqual(r.periodicity, 0)
    }

    func testRmsIsMeasuredOnTheWindow() {
        let r = estimate(SyntheticVoice.sine(frequency: 300, seconds: 0.2, amplitude: 0.5))
        XCTAssertEqual(r.rms, 0.5 / 2.0.squareRoot(), accuracy: 0.01)
    }

    func testTheSilenceFloorIsTheDigitalSilenceFloorNotALoudnessGate() {
        // Below 1e-4 (about 3 LSB) there is nothing to measure; a quiet voice above it is measured.
        let below = estimate(SyntheticVoice.sine(frequency: 300, seconds: 0.2, amplitude: 1.0e-4))
        XCTAssertFalse(below.voiced, "rms 7e-5 is under the floor")
        XCTAssertEqual(below.periodicity, 0)
        let above = estimate(SyntheticVoice.sine(frequency: 300, seconds: 0.2, amplitude: 4.0e-4))
        XCTAssertTrue(above.voiced, "rms 3e-4 is a quiet voice, not silence")
        let quietVowel = estimate(SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.3, rms: 0.005))
        XCTAssertTrue(quietVowel.voiced)
        XCTAssertEqual(quietVowel.f0Hz, 120, accuracy: 3.6)
    }

    func testWhiteNoiseIsUnvoicedButStillHasAPeriodicity() {
        let r = estimate(SyntheticVoice.whiteNoise(seconds: 0.2, rms: 0.1))
        XCTAssertFalse(r.voiced)
        XCTAssertEqual(r.f0Hz, 0)
        XCTAssertLessThan(r.periodicity, VoiceDsp.voicedPeriodicity)
        XCTAssertGreaterThan(r.periodicity, 0, "reported for an unvoiced window too")
    }

    func testPeriodicityOfACleanVowelIsNearOne() {
        let r = estimate(SyntheticVoice.vowel(f0: 130, SyntheticVoice.a, seconds: 0.3))
        XCTAssertGreaterThan(r.periodicity, 0.95)
        XCTAssertLessThanOrEqual(r.periodicity, 1.0)
    }
}
