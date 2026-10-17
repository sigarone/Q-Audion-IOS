import XCTest
@testable import QAudionApp
import QAudionEngine

/// The voice analysis of the call screen: ribbon gauges, "voice check" card and
/// voice-biometrics rows. The decisions live in `VoiceGuardModel.swift` as pure
/// functions (value in, word / colour role / text out), so the thresholds, the
/// wording and the number formats are pinned here without any UI.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in
/// the `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class VoiceGuardModelTests: XCTestCase {

    // MARK: - Stress gauge

    func testStressBandsAndTheirBoundaries() {
        XCTAssertEqual(VoiceGauges.stress(points: 0).status, "calm")
        XCTAssertEqual(VoiceGauges.stress(points: 35).status, "calm", "35 is still calm")
        XCTAssertEqual(VoiceGauges.stress(points: 35.5).status, "elevated")
        XCTAssertEqual(VoiceGauges.stress(points: 60).status, "elevated", "60 is still elevated")
        XCTAssertEqual(VoiceGauges.stress(points: 60.5).status, "high")
        XCTAssertEqual(VoiceGauges.stress(points: 100).status, "high")
    }

    func testStressColourRoles() {
        XCTAssertEqual(VoiceGauges.stress(points: 12).tone, .success)
        XCTAssertEqual(VoiceGauges.stress(points: 48).tone, .warning)
        XCTAssertEqual(VoiceGauges.stress(points: 83).tone, .riskHigh)
    }

    func testStressValueIsCutNotRounded() {
        XCTAssertEqual(VoiceGauges.stress(points: 44.9).value, "44")
        XCTAssertEqual(VoiceGauges.stress(points: 44.9).unit, "/100")
        XCTAssertEqual(VoiceGauges.stress(points: 0.99).value, "0")
    }

    func testStressWithoutANumberMakesNoClaim() {
        let reading = VoiceGauges.stress(points: .nan)
        XCTAssertEqual(reading.value, "—")
        XCTAssertEqual(reading.status, "")
        XCTAssertEqual(reading.tone, .neutral)
    }

    // MARK: - Breath gauge

    func testBreathBandsAndTheirBoundaries() {
        XCTAssertEqual(VoiceGauges.breath(hnr: 22).status, "clear")
        XCTAssertEqual(VoiceGauges.breath(hnr: 15).status, "clear", "15 dB is clear")
        XCTAssertEqual(VoiceGauges.breath(hnr: 14.9).status, "mild")
        XCTAssertEqual(VoiceGauges.breath(hnr: 10).status, "mild", "10 dB is mild")
        XCTAssertEqual(VoiceGauges.breath(hnr: 9.9).status, "hoarse")
        XCTAssertEqual(VoiceGauges.breath(hnr: -3).status, "hoarse")
    }

    func testBreathColourRoles() {
        XCTAssertEqual(VoiceGauges.breath(hnr: 18).tone, .success)
        XCTAssertEqual(VoiceGauges.breath(hnr: 12).tone, .warning)
        XCTAssertEqual(VoiceGauges.breath(hnr: 4).tone, .riskHigh, "a hoarse voice is red, not amber")
    }

    func testBreathValueAndUnit() {
        let reading = VoiceGauges.breath(hnr: 20.8)
        XCTAssertEqual(reading.value, "20")
        XCTAssertEqual(reading.unit, "dB")
        XCTAssertEqual(VoiceGauges.breath(hnr: .infinity).value, "—")
    }

    // MARK: - Pitch gauge

    func testPitchHasNoStatusWordWhileVoicedAndADashWhenNot() {
        XCTAssertEqual(VoiceGauges.pitch(hz: 142.7, voiced: true).status, "")
        XCTAssertEqual(VoiceGauges.pitch(hz: 0, voiced: false).status, "—")
        XCTAssertEqual(VoiceGauges.pitch(hz: 142.7, voiced: true).value, "142")
        XCTAssertEqual(VoiceGauges.pitch(hz: 142.7, voiced: true).unit, "Hz")
    }

    func testPitchIsNeverColoured() {
        XCTAssertEqual(VoiceGauges.pitch(hz: 142, voiced: true).tone, .neutral)
        XCTAssertEqual(VoiceGauges.pitch(hz: 0, voiced: false).tone, .neutral)
    }

    func testPitchWordsNeverUseTheOldInventedOnes() {
        for voiced in [true, false] {
            let status = VoiceGauges.pitch(hz: 120, voiced: voiced).status
            XCTAssertNotEqual(status, "steady")
            XCTAssertNotEqual(status, "silent")
            XCTAssertNotEqual(status, "n/d")
        }
    }

    // MARK: - Voice-biometrics rows

    func testAuthenticityBands() {
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(0.95).tone, .success)
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(0.801).tone, .success)
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(0.80).tone, .warning, "above 0.80 is genuine, 0.80 itself is not")
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(0.50).tone, .warning, "0.50 still asks for a check")
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(0.499).tone, .riskHigh)
    }

    func testAuthenticityIsJustTheNumber() {
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(0.87).text, "0.87")
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(1.0).text, "1.00")
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(1.4).text, "1.00", "never above 1")
    }

    func testAuthenticityOfZeroIsNoReadingNotRed() {
        let line = VoiceBiometricsFormat.authenticity(0)
        XCTAssertEqual(line.text, "—")
        XCTAssertEqual(line.tone, .neutral)
        XCTAssertEqual(VoiceBiometricsFormat.authenticity(.nan).tone, .neutral)
    }

    func testStressRowIsPointsOutOfOneHundredWithTheGaugeColour() {
        let line = VoiceBiometricsFormat.stress(points: 44.9)
        XCTAssertEqual(line.text, "44/100")
        XCTAssertEqual(line.tone, .warning)
        XCTAssertEqual(VoiceBiometricsFormat.stress(points: .nan).text, "—")
    }

    func testJitterAndShimmerAreShownAsPercentages() {
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitter: 0.25, shimmer: 0.5), "25.0% / 50.0%")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitter: 0, shimmer: 0), "0.0% / 0.0%")
    }

    func testBreathRowIsWholeDecibelsThenBreathiness() {
        let clear = VoiceBiometricsFormat.breath(hnr: 21.4, breathiness: 0.5)
        XCTAssertEqual(clear.text, "21 dB / 0.50")
        XCTAssertEqual(clear.tone, .success)
        let mild = VoiceBiometricsFormat.breath(hnr: 12.2, breathiness: 0.4)
        XCTAssertEqual(mild.text, "12 dB / 0.40")
        XCTAssertEqual(mild.tone, .warning)
        XCTAssertEqual(VoiceBiometricsFormat.breath(hnr: 3, breathiness: 1).tone, .riskHigh)
        XCTAssertEqual(VoiceBiometricsFormat.breath(hnr: .nan, breathiness: 1).text, "—")
    }

    func testPitchAndRateRow() {
        XCTAssertEqual(VoiceBiometricsFormat.pitchRate(hz: 142, syllablesPerSecond: 4.5), "142 Hz · 4.5 syl/s")
    }

    // MARK: - Voice check card: verdict

    func testVerdictLevelFollowsTheSpeakerChangeVerdict() {
        XCTAssertNil(VoiceGuard.level(of: .unknown))
        XCTAssertEqual(VoiceGuard.level(of: .steady), .verified)
        XCTAssertEqual(VoiceGuard.level(of: .suspect), .caution)
        XCTAssertEqual(VoiceGuard.level(of: .changed), .highRisk)
    }

    func testVerdictColourRoles() {
        XCTAssertEqual(VoiceGuard.tone(of: VoiceGuardLevel.verified), .success)
        XCTAssertEqual(VoiceGuard.tone(of: VoiceGuardLevel.caution), .warning)
        XCTAssertEqual(VoiceGuard.tone(of: VoiceGuardLevel.highRisk), .riskHigh)
        let unknown: VoiceGuardLevel? = nil
        XCTAssertEqual(VoiceGuard.tone(of: unknown), .neutral)
    }

    func testIconFollowsBannerAndVerdict() {
        XCTAssertEqual(VoiceGuard.icon(banner: .learned, level: nil), .check)
        XCTAssertEqual(VoiceGuard.icon(banner: nil, level: .verified), .check)
        XCTAssertEqual(VoiceGuard.icon(banner: nil, level: .highRisk), .warning)
        XCTAssertEqual(VoiceGuard.icon(banner: nil, level: .caution), .microphone)
        XCTAssertEqual(VoiceGuard.icon(banner: nil, level: nil), .microphone)
        XCTAssertEqual(VoiceGuard.icon(banner: .failed, level: nil), .microphone)
        XCTAssertEqual(VoiceGuard.icon(banner: .failed, level: .highRisk), .warning)
    }

    // MARK: - Voice check card: what it shows

    func testBannerBeatsEverythingElse() {
        let content = VoiceGuard.content(banner: .learned,
                                         learning: .inProgress(progress: 0.5),
                                         hasHistory: true,
                                         level: .highRisk)
        XCTAssertEqual(content, .banner(.learned))
    }

    func testLearningProgressBeatsWaitingAndVerdict() {
        XCTAssertEqual(VoiceGuard.content(banner: nil, learning: .inProgress(progress: 0.4),
                                          hasHistory: false, level: nil),
                       .learning(progress: 0.4))
        XCTAssertEqual(VoiceGuard.content(banner: nil, learning: .inProgress(progress: 0.4),
                                          hasHistory: true, level: .verified),
                       .learning(progress: 0.4))
    }

    func testWaitsForVoiceDataUntilTheFirstSample() {
        let states: [VoiceLearningSession.State?] = [nil, .idle, .failed, .completed(contactId: "c1")]
        for state in states {
            XCTAssertEqual(VoiceGuard.content(banner: nil, learning: state, hasHistory: false, level: .verified),
                           .waiting)
        }
    }

    func testVerdictOnceThereIsHistory() {
        XCTAssertEqual(VoiceGuard.content(banner: nil, learning: nil, hasHistory: true, level: nil),
                       .verdict(level: nil))
        XCTAssertEqual(VoiceGuard.content(banner: nil, learning: .completed(contactId: "c1"),
                                          hasHistory: true, level: .caution),
                       .verdict(level: .caution))
    }

    func testBannerOnlyForTheTwoFinalLearningStates() {
        XCTAssertEqual(VoiceGuard.banner(for: .completed(contactId: "c1")), .learned)
        XCTAssertEqual(VoiceGuard.banner(for: .failed), .failed)
        XCTAssertNil(VoiceGuard.banner(for: .idle))
        XCTAssertNil(VoiceGuard.banner(for: .inProgress(progress: 0.9)))
        XCTAssertNil(VoiceGuard.banner(for: nil))
    }

    func testBannerColourRoles() {
        XCTAssertEqual(VoiceGuard.tone(of: VoiceGuardBanner.learned), .success)
        XCTAssertEqual(VoiceGuard.tone(of: VoiceGuardBanner.failed), .riskHigh)
        let none: VoiceGuardBanner? = nil
        XCTAssertNil(VoiceGuard.tone(of: none))
        XCTAssertEqual(VoiceGuard.bannerSeconds, 3.5)
    }

    func testLearningProgressIsKeptInsideTheBar() {
        XCTAssertEqual(VoiceGuard.clampedProgress(-0.2), 0)
        XCTAssertEqual(VoiceGuard.clampedProgress(1.7), 1)
        XCTAssertEqual(VoiceGuard.clampedProgress(.nan), 0)
        XCTAssertEqual(VoiceGuard.percentText(0.5), "50%")
        XCTAssertEqual(VoiceGuard.percentText(2), "100%")
    }

    // MARK: - Single-trace wave

    func testWaveHasNothingToDrawBelowTwoSamples() {
        XCTAssertTrue(VoiceGuardWave.deviations(of: []).isEmpty)
        XCTAssertTrue(VoiceGuardWave.deviations(of: [0.8]).isEmpty)
        XCTAssertTrue(VoiceGuardWave.deviations(of: [0.8, .nan]).isEmpty, "a non-finite sample is not a sample")
    }

    func testAPerfectlySteadyWindowStaysOnTheCentreLine() {
        let flat = VoiceGuardWave.deviations(of: [0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(flat, [0, 0, 0, 0])
    }

    func testTinyNoiseIsNotBlownUpIntoMovement() {
        // A swing of 0.001 against the 0.02 floor reaches only 5 % of the height.
        let noise = VoiceGuardWave.deviations(of: [0.900, 0.901, 0.900, 0.901])
        XCTAssertLessThan(noise.map { abs($0) }.max() ?? 1, 0.06)
    }

    func testARealSwingFillsTheHeightAndStaysWithinBounds() {
        let swing = VoiceGuardWave.deviations(of: [0.2, 0.9, 0.2, 0.9])
        XCTAssertEqual(swing.count, 4)
        XCTAssertEqual(swing[0], -1, accuracy: 1e-5)
        XCTAssertEqual(swing[1], 1, accuracy: 1e-5)
        for value in VoiceGuardWave.deviations(of: [0, 5, -3, 40]) {
            XCTAssertLessThanOrEqual(abs(value), 1)
        }
    }
}
