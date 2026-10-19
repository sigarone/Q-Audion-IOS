import XCTest
@testable import QAudionEngine

final class VoiceHealthMonitorTests: XCTestCase {
    private var monitor: VoiceHealthMonitor!

    override func setUp() {
        super.setUp()
        monitor = VoiceHealthMonitor()
    }

    private func analyze(_ x: [Double], f0: Double = 120, voiced: Bool = true, end: Int? = nil)
        -> VoiceAnalysisResult.VoiceHealth {
        monitor.analyze(window: SyntheticVoice.window(of: x, endingAt: end), voiced: voiced, f0Hz: voiced ? f0 : 0)
    }

    private func instant(_ x: [Double], f0: Double = 120) -> Double {
        monitor.instantHnr(SyntheticVoice.window(of: x).linear, f0Hz: f0).hnr
    }

    func testUnvoicedStepBeforeAnyVoiceIsNotAReading() {
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.3)
        let h = analyze(x, voiced: false)
        XCTAssertEqual(h.hnr, 0)
        XCTAssertEqual(h.breathiness, 0, "breathiness is 0 while there is no reading, not 1")
        XCTAssertFalse(h.hnrValid)
    }

    func testNotValidUntilThreeVoicedReadings() {
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.5)
        XCTAssertFalse(analyze(x, end: 4_000).hnrValid)
        XCTAssertFalse(analyze(x, end: 5_000).hnrValid)
        let third = analyze(x, end: 6_000)
        XCTAssertTrue(third.hnrValid)
        XCTAssertGreaterThan(third.hnr, 20)
        XCTAssertLessThanOrEqual(third.hnr, 40, "capped at 40 dB")
        XCTAssertGreaterThanOrEqual(third.breathiness, 0)
        XCTAssertLessThanOrEqual(third.breathiness, 1.0)
    }

    func testTheValueIsHeldForOneSecondAfterTheLastVoicedStep() {
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.5)
        var last = VoiceAnalysisResult.VoiceHealth()
        for end in [4_000, 5_000, 6_000, 7_000] { last = analyze(x, end: end) }
        XCTAssertTrue(last.hnrValid)
        // Ten unvoiced steps: still the value of the last voiced readings...
        for step in 1...10 {
            let h = analyze(x, voiced: false, end: 8_000)
            XCTAssertTrue(h.hnrValid, "unvoiced step \(step) of 10 is inside the hold")
            XCTAssertEqual(h.hnr, last.hnr, "the held value, not a made-up one")
        }
        // ...and the eleventh blanks it.
        let expired = analyze(x, voiced: false, end: 8_000)
        XCTAssertFalse(expired.hnrValid)
        XCTAssertEqual(expired.hnr, 0)
        XCTAssertEqual(expired.breathiness, 0)
    }

    func testAVoicedStepAfterTheHoldHasExpiredIsValidAgainAtOnce() {
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.5)
        for end in [4_000, 5_000, 6_000] { _ = analyze(x, end: end) }
        for _ in 0..<12 { _ = analyze(x, voiced: false, end: 8_000) }
        XCTAssertTrue(analyze(x, end: 7_000).hnrValid, "three voiced readings were already counted")
    }

    func testInstantHnrFallsWithNoiseAndTracksTheSnr() {
        let clean = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.3)
        let hc = instant(clean)
        XCTAssertGreaterThan(hc, 20)
        for snr in [20.0, 10.0, 0.0] {
            let h = instant(SyntheticVoice.addNoise(clean, snrDb: snr))
            XCTAssertEqual(h, snr, accuracy: 2.0, "white noise at \(snr) dB SNR reads about that in a 48 kHz window")
        }
    }

    func testInstantHnrIsIndependentOfAmplitude() {
        let loud = SyntheticVoice.addNoise(SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.3, rms: 0.2), snrDb: 10)
        let quiet = loud.map { $0 * 0.1 }
        XCTAssertEqual(instant(loud), instant(quiet), accuracy: 0.5)
    }

    func testNoiseHasAVeryLowHnr() {
        let h = instant(SyntheticVoice.whiteNoise(seconds: 0.3, rms: 0.1))
        XCTAssertLessThan(h, 3)
    }

    func testBreathinessIsTheMeanOfOneMinusRAndStaysInRange() {
        let clean = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.5)
        let noisy = SyntheticVoice.addNoise(clean, snrDb: -5)
        var noisyHealth = VoiceAnalysisResult.VoiceHealth()
        for end in [4_000, 5_000, 6_000, 7_000] { noisyHealth = analyze(noisy, end: end) }
        XCTAssertTrue(noisyHealth.hnrValid)
        XCTAssertGreaterThanOrEqual(noisyHealth.breathiness, 0)
        XCTAssertLessThanOrEqual(noisyHealth.breathiness, 1.0)
        let cleanMonitor = VoiceHealthMonitor()
        var cleanHealth = VoiceAnalysisResult.VoiceHealth()
        for end in [4_000, 5_000, 6_000, 7_000] {
            cleanHealth = cleanMonitor.analyze(window: SyntheticVoice.window(of: clean, endingAt: end),
                                               voiced: true, f0Hz: 120)
        }
        XCTAssertLessThan(cleanHealth.breathiness, noisyHealth.breathiness, "a clean vowel is less breathy than a noisy one")
        XCTAssertLessThan(cleanHealth.breathiness, 0.01)
    }

    func testResetForgetsTheReadings() {
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.5)
        for end in [4_000, 5_000, 6_000] { _ = analyze(x, end: end) }
        monitor.reset()
        XCTAssertFalse(analyze(x, end: 7_000).hnrValid)
    }
}
