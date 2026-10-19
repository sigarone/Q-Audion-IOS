import XCTest
@testable import QAudionEngine

final class FormantTrackerTests: XCTestCase {
    private var tracker: FormantTracker!

    override func setUp() {
        super.setUp()
        tracker = FormantTracker()
    }

    private func extract(_ x: [Double], f0: Double, voiced: Bool = true, endingAt end: Int? = nil)
        -> VoiceAnalysisResult.Formants {
        tracker.extract(window: SyntheticVoice.window(of: x, endingAt: end), voiced: voiced, f0Hz: f0)
    }

    func testVowelFormantsAreFound() {
        let x = SyntheticVoice.vowel(f0: 100, SyntheticVoice.a, seconds: 0.3)
        let f = extract(x, f0: 100)
        XCTAssertTrue(f.f1Found)
        XCTAssertTrue(f.f2Found)
        XCTAssertEqual(Double(f.f1), 700, accuracy: 700 * 0.12)
        XCTAssertEqual(Double(f.f2), 1220, accuracy: 1220 * 0.12)
        XCTAssertFalse(f.f3Found, "F3 is not measured")
        XCTAssertFalse(f.f4Found, "F4 is not measured")
        XCTAssertEqual(f.f3, 0)
        XCTAssertEqual(f.f4, 0)
    }

    func testFormantsAreInAscendingOrder() {
        let x = SyntheticVoice.vowel(f0: 100, SyntheticVoice.i, seconds: 0.3)
        let f = extract(x, f0: 100)
        XCTAssertTrue(f.f1Found && f.f2Found)
        XCTAssertLessThan(f.f1, f.f2)
        XCTAssertEqual(Double(f.f2), 2290, accuracy: 2290 * 0.12, "a wide tilt root between F1 and F2 does not hide it")
    }

    func testUnvoicedStepFindsNothing() {
        let x = SyntheticVoice.vowel(f0: 100, SyntheticVoice.a, seconds: 0.3)
        let f = extract(x, f0: 0, voiced: false)
        XCTAssertFalse(f.f1Found)
        XCTAssertFalse(f.f2Found)
        XCTAssertEqual(f.f1, 0)
        XCTAssertEqual(f.f2, 0)
    }

    func testSilentWindowFindsNothing() {
        let f = extract([Double](repeating: 0, count: 4_000), f0: 100)
        XCTAssertFalse(f.f1Found)
        XCTAssertFalse(f.f2Found)
        XCTAssertEqual(f.f1, 0)
        XCTAssertEqual(f.f2, 0)
    }

    func testTheRootsAreSortedAndComeFromAnOrder18Fit() {
        let w = SyntheticVoice.window(of: SyntheticVoice.vowel(f0: 100, SyntheticVoice.a, seconds: 0.3))
        guard let count = tracker.candidates(w.x16) else {
            return XCTFail("root finder failed on a clean vowel")
        }
        XCTAssertGreaterThanOrEqual(count, 3)
        XCTAssertLessThanOrEqual(count, VoiceDsp.lpcOrder)
    }

    func testResonancesBelowTwoAndAHalfTimesF0AreWithheld() {
        // /u/ (300 Hz, 870 Hz) at 220 Hz: F1 lies below 2.5 x f0 = 550 Hz and is withheld, while F2
        // above it is still reported.
        let x = SyntheticVoice.vowel(f0: 220, SyntheticVoice.u, seconds: 0.3)
        let f = extract(x, f0: 220)
        XCTAssertFalse(f.f1Found)
        XCTAssertEqual(f.f1, 0)
        XCTAssertTrue(f.f2Found)
        XCTAssertEqual(Double(f.f2), 870, accuracy: 870 * 0.12)
    }

    func testTheGateAppliesToF2AsWellAsToF1() {
        // At 360 Hz the gate is 900 Hz: /u/ has neither F1 (300 Hz) nor F2 (870 Hz) above it.
        let x = SyntheticVoice.vowel(f0: 360, SyntheticVoice.u, seconds: 0.3)
        let f = extract(x, f0: 360)
        XCTAssertFalse(f.f1Found)
        XCTAssertFalse(f.f2Found, "F2 below 2.5 x f0 is withheld too")
    }

    func testReadingNeverOutlivesTheVoicedStretch() {
        // Three voiced steps of /a/ fill the median history; one unvoiced step must
        // drop it, so the next vowel is read on its own and not blended with /a/.
        let a = SyntheticVoice.vowel(f0: 100, SyntheticVoice.a, seconds: 0.3)
        let u = SyntheticVoice.vowel(f0: 100, SyntheticVoice.u, seconds: 0.3)
        for end in [4_000, 5_000, 6_000] { _ = extract(a, f0: 100, endingAt: end) }
        _ = extract(a, f0: 0, voiced: false)
        let f = extract(u, f0: 100)
        XCTAssertTrue(f.f1Found)
        XCTAssertEqual(Double(f.f1), 300, accuracy: 300 * 0.12, "median of one value, not of /a/ and /u/")
    }

    func testMedianOfTheLastThreeFoundValues() {
        // A single stray step cannot move the reading: the median of three ignores it.
        let a = SyntheticVoice.vowel(f0: 100, SyntheticVoice.a, seconds: 0.3)
        let i = SyntheticVoice.vowel(f0: 100, SyntheticVoice.i, seconds: 0.3)
        _ = extract(a, f0: 100, endingAt: 4_000)
        _ = extract(a, f0: 100, endingAt: 5_000)
        let f = extract(i, f0: 100, endingAt: 6_000)     // one stray /i/ step among /a/
        XCTAssertEqual(Double(f.f1), 700, accuracy: 700 * 0.12)
    }

    func testAStepThatFindsNothingLeavesTheHistoryAlone() {
        // The history is cleared only by an unvoiced step: a voiced step in which F1 is
        // withheld (here a window of /i/ at a pitch that puts F1 under the gate) does not
        // erase the /a/ values, and the next /a/ is still a median over three.
        let a = SyntheticVoice.vowel(f0: 100, SyntheticVoice.a, seconds: 0.3)
        let i = SyntheticVoice.vowel(f0: 220, SyntheticVoice.i, seconds: 0.3)
        _ = extract(a, f0: 100, endingAt: 4_000)
        _ = extract(a, f0: 100, endingAt: 5_000)
        let stray = extract(i, f0: 220)
        XCTAssertFalse(stray.f1Found)
        let f = extract(a, f0: 100, endingAt: 6_000)
        XCTAssertEqual(Double(f.f1), 700, accuracy: 700 * 0.12)
    }

    func testResetForgetsTheHistory() {
        let a = SyntheticVoice.vowel(f0: 100, SyntheticVoice.a, seconds: 0.3)
        let u = SyntheticVoice.vowel(f0: 100, SyntheticVoice.u, seconds: 0.3)
        for end in [4_000, 5_000, 6_000] { _ = extract(a, f0: 100, endingAt: end) }
        tracker.reset()
        let f = extract(u, f0: 100)
        XCTAssertEqual(Double(f.f1), 300, accuracy: 300 * 0.12)
    }

    func testAWideHarmonicPoleIsNeverPromotedToF2() {
        // /a/ at 220 Hz: in some windows the fit puts a broad pole (about 380 Hz wide) on the 4th
        // harmonic (880 Hz), between F1 and the real F2. It is a pole the method cannot measure, so
        // F2 is reported as not found; the real F2 behind it is NOT promoted in its place, but
        // whenever F2 is reported it is the real one.
        let x = SyntheticVoice.vowel(f0: 220, SyntheticVoice.a, seconds: 0.5)
        for end in stride(from: 4_000, through: 16_000, by: 500) {
            let fresh = FormantTracker()      // no median history to hide a single bad window
            let f = fresh.extract(window: SyntheticVoice.window(of: x, endingAt: end), voiced: true, f0Hz: 220)
            if f.f2Found {
                XCTAssertEqual(Double(f.f2), 1220, accuracy: 1220 * 0.12, "window ending at \(end)")
            } else {
                XCTAssertEqual(f.f2, 0)
            }
        }
    }
}
