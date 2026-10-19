import XCTest
@testable import QAudionApp
import QAudionEngine

/// The voice analysis of the call screen: tone row of the ribbon, "voice
/// check" card with its wave, and technical-data rows. The decisions live in
/// `VoiceGuardModel.swift` as pure functions (value in, word / colour role /
/// text out), so the thresholds, the wording and the number formats are pinned
/// here without any UI. Stress, breath and authenticity readings are gone on
/// purpose: they are not validated for phone-quality speech.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in
/// the `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class VoiceGuardModelTests: XCTestCase {

    // MARK: - Tone row

    func testToneReadingIsTheWholeNumberInHertzAndTheVoicedFlag() {
        let voiced = VoiceGauges.pitch(hz: 142.7, voiced: true)
        XCTAssertEqual(voiced.value, "142", "cut towards zero, not rounded")
        XCTAssertEqual(voiced.unit, "Hz")
        XCTAssertTrue(voiced.voiced)
        let silent = VoiceGauges.pitch(hz: 0, voiced: false)
        XCTAssertEqual(silent.value, "0")
        XCTAssertFalse(silent.voiced)
    }

    func testToneValueWithoutANumberReadsAsTheDash() {
        XCTAssertEqual(VoiceGauges.pitch(hz: .nan, voiced: true).value, "—")
        XCTAssertEqual(VoiceGauges.pitch(hz: .infinity, voiced: false).value, "—")
    }

    /// The dash printed for a missing value is not a word, so it needs no translation.
    func testTheDashIsNotLanguage() {
        XCTAssertEqual(VoiceGauges.noValue, "—")
    }

    /// The row says what was heard in two words, "voice" and "silence", and they
    /// must not be the same word nor empty (a missing catalog entry falls back to
    /// the Italian default, never to an empty string).
    func testTheTwoVoiceWordsDiffer() {
        let voice = VoiceToneCopy.voiceWord(voiced: true)
        let silence = VoiceToneCopy.voiceWord(voiced: false)
        XCTAssertFalse(voice.isEmpty)
        XCTAssertFalse(silence.isEmpty)
        XCTAssertNotEqual(voice, silence)
    }

    func testTheSpokenToneReadsLabelValueUnitAndWord() {
        let reading = VoiceGauges.pitch(hz: 142.7, voiced: true)
        XCTAssertEqual(VoiceGauges.spokenTone(label: "Tono", reading: reading, voiceWord: "voce", details: nil),
                       "Tono, 142 Hz, voce")
        XCTAssertEqual(VoiceGauges.spokenTone(label: "Tono", reading: reading, voiceWord: "voce", details: ""),
                       "Tono, 142 Hz, voce")
    }

    /// The details are read as pauses, not as the middle dot of the screen.
    func testTheSpokenToneReadsTheDetailsWithPauses() {
        let reading = VoiceGauges.pitch(hz: 120, voiced: true)
        let spoken = VoiceGauges.spokenTone(label: "Tono",
                                            reading: reading,
                                            voiceWord: "voce",
                                            details: "F1 520 · F2 1480 · 4,2 sill/s · HNR 18 dB")
        XCTAssertEqual(spoken, "Tono, 120 Hz, voce, F1 520, F2 1480, 4,2 sill/s, HNR 18 dB")
        XCTAssertFalse(spoken.contains("·"))
    }

    // MARK: - Spectral details of the tone row

    private let allDetails = Set(VoiceSpectralDetails.Field.allCases)
    private let italian = Locale(identifier: "it_IT")
    private let english = Locale(identifier: "en_US")

    private func details(f1: Float = 524,
                         f2: Float = 1478,
                         rate: Float = 4.24,
                         hnr: Float = 18.4,
                         voiced: Bool = true,
                         fields: Set<VoiceSpectralDetails.Field>? = nil,
                         locale: Locale) -> String? {
        VoiceSpectralDetails.text(formant1Hz: f1,
                                  formant2Hz: f2,
                                  syllablesPerSecond: rate,
                                  hnrDecibels: hnr,
                                  voiced: voiced,
                                  rateUnit: "sill/s",
                                  fields: fields ?? allDetails,
                                  locale: locale)
    }

    func testDetailsHaveTheFixedFormat() {
        XCTAssertEqual(details(locale: italian), "F1 520 · F2 1480 · 4,2 sill/s · HNR 18 dB")
        XCTAssertEqual(VoiceSpectralDetails.separator, " · ")
    }

    func testFormantsAreRoundedToTheNearestTenHertz() {
        XCTAssertEqual(VoiceSpectralDetails.formant(524, voiced: true), "520")
        XCTAssertEqual(VoiceSpectralDetails.formant(525, voiced: true), "530")
        XCTAssertEqual(VoiceSpectralDetails.formant(1474.9, voiced: true), "1470")
        XCTAssertEqual(VoiceSpectralDetails.formant(1475, voiced: true), "1480")
        XCTAssertEqual(VoiceSpectralDetails.formant(3004, voiced: true), "3000", "no thousands separator")
    }

    func testHnrIsAWholeNumberOfDecibels() {
        XCTAssertEqual(VoiceSpectralDetails.hnr(18.4, voiced: true), "18 dB")
        XCTAssertEqual(VoiceSpectralDetails.hnr(17.5, voiced: true), "18 dB")
        XCTAssertEqual(VoiceSpectralDetails.hnr(0.2, voiced: true), "0 dB")
        XCTAssertEqual(VoiceSpectralDetails.hnr(-3.6, voiced: true), "-4 dB", "a noisy segment can be below zero")
    }

    /// Without a voice, F1, F2 and HNR do not exist and print the dash; the rate
    /// still prints, because a window without speech has a rate.
    func testWithoutAVoiceTheDashReplacesF1F2AndHnrButNotTheRate() {
        XCTAssertEqual(details(voiced: false, locale: italian), "F1 — · F2 — · 4,2 sill/s · HNR —")
    }

    func testAFormantThatWasNotFoundPrintsTheDash() {
        XCTAssertEqual(VoiceSpectralDetails.formant(0, voiced: true), "—")
        XCTAssertEqual(VoiceSpectralDetails.formant(-5, voiced: true), "—")
        XCTAssertEqual(VoiceSpectralDetails.formant(.nan, voiced: true), "—")
        XCTAssertEqual(VoiceSpectralDetails.formant(.infinity, voiced: true), "—")
        XCTAssertEqual(VoiceSpectralDetails.hnr(.nan, voiced: true), "—")
    }

    func testTheRateUsesTheDecimalSeparatorOfTheLocale() {
        XCTAssertEqual(VoiceSpectralDetails.rate(4.24, unit: "sill/s", locale: italian), "4,2 sill/s")
        XCTAssertEqual(VoiceSpectralDetails.rate(4.24, unit: "syl/s", locale: english), "4.2 syl/s")
        XCTAssertEqual(details(locale: english), "F1 520 · F2 1480 · 4.2 sill/s · HNR 18 dB")
    }

    func testTheRateHasOneDecimalAndIsRoundedNotCut() {
        XCTAssertEqual(VoiceSpectralDetails.rate(4.26, unit: "u", locale: english), "4.3 u")
        XCTAssertEqual(VoiceSpectralDetails.rate(4, unit: "u", locale: english), "4.0 u")
        XCTAssertEqual(VoiceSpectralDetails.rate(0, unit: "u", locale: italian), "0,0 u")
        XCTAssertEqual(VoiceSpectralDetails.rate(.nan, unit: "u", locale: english), "— u")
    }

    func testOnlyTheSelectedDetailsArePrintedInTheFixedOrder() {
        XCTAssertEqual(details(fields: [.hnr, .formant1], locale: italian), "F1 520 · HNR 18 dB")
        XCTAssertEqual(details(fields: [.speechRate], locale: italian), "4,2 sill/s")
        XCTAssertNil(details(fields: [], locale: italian), "nothing selected, nothing printed")
    }

    /// Printed details are listed here once their extractor returns the quantity
    /// its label names (see the doc of `VoiceSpectralDetails.measured`). Until
    /// then the tone row shows the tone alone; this test is the place to change
    /// when a field is switched on.
    func testNoDetailIsPrintedUntilItsExtractorIsTrusted() {
        XCTAssertTrue(VoiceSpectralDetails.measured.isEmpty)
        XCTAssertNil(VoiceSpectralDetails.text(formant1Hz: 524,
                                               formant2Hz: 1478,
                                               syllablesPerSecond: 4.2,
                                               hnrDecibels: 18,
                                               voiced: true,
                                               rateUnit: "sill/s"))
    }

    // MARK: - Technical-data rows

    func testJitterAndShimmerAreShownAsPercentages() {
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitter: 0.25, shimmer: 0.5), "25.0% / 50.0%")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitter: 0, shimmer: 0), "0.0% / 0.0%")
    }

    func testHnrRowIsWholeDecibels() {
        XCTAssertEqual(VoiceBiometricsFormat.hnr(21.4), "21 dB")
        XCTAssertEqual(VoiceBiometricsFormat.hnr(0), "0 dB")
        XCTAssertEqual(VoiceBiometricsFormat.hnr(.nan), "—")
        XCTAssertEqual(VoiceBiometricsFormat.hnr(.infinity), "—")
    }

    /// The Guardian confidence is a plain "C=0.NN" with no colour or band; "C=—" while
    /// there is no score (the negative sentinel, or a NaN).
    func testConfidenceRowIsAPlainNumber() {
        XCTAssertEqual(VoiceBiometricsFormat.confidence(0.5), "C=0.50")
        XCTAssertEqual(VoiceBiometricsFormat.confidence(0), "C=0.00")
        XCTAssertEqual(VoiceBiometricsFormat.confidence(1.4), "C=1.00", "never above 1")
        XCTAssertEqual(VoiceBiometricsFormat.confidence(-1), "C=—")
        XCTAssertEqual(VoiceBiometricsFormat.confidence(.nan), "C=—")
    }

    /// The block that holds the raw measures says up front that they are not
    /// validated, whatever the language of the device.
    func testTechnicalDataBlockHasATitleAndANote() {
        XCTAssertFalse(VoiceTechnicalCopy.title.isEmpty)
        XCTAssertFalse(VoiceTechnicalCopy.note.isEmpty)
        XCTAssertNotEqual(VoiceTechnicalCopy.title, VoiceTechnicalCopy.note)
    }

    func testPitchAndRateRow() {
        XCTAssertEqual(VoiceBiometricsFormat.pitchRate(hz: 142, syllablesPerSecond: 4.5, syllableUnit: "u/s"),
                       "142 Hz · 4.5 u/s")
        XCTAssertEqual(VoiceBiometricsFormat.pitchRate(hz: .nan, syllablesPerSecond: 4.5, syllableUnit: "u/s"), "—")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitter: .nan, shimmer: 0.1), "—")
    }

    // MARK: - Voice check card: verdict

    func testVerdictLevelFollowsTheSpeakerChangeVerdict() {
        XCTAssertNil(VoiceGuard.level(of: .unknown))
        XCTAssertEqual(VoiceGuard.level(of: .steady), .verified)
        XCTAssertEqual(VoiceGuard.level(of: .suspect), .caution)
        XCTAssertEqual(VoiceGuard.level(of: .changed), .highRisk)
    }

    func testVerdictColourRoles() {
        XCTAssertEqual(VoiceGuard.tone(of: .verified), .success)
        XCTAssertEqual(VoiceGuard.tone(of: .caution), .warning)
        XCTAssertEqual(VoiceGuard.tone(of: .highRisk), .riskHigh)
        XCTAssertEqual(VoiceGuard.tone(of: nil), .neutral)
    }

    /// Fail-open guard: "Voce coerente" must never be shown for a missing
    /// verdict, which is what the card has during the first seconds of a call
    /// (it reads "Dati insufficienti" then).
    func testNoVerdictYetNeverReadsAsRecognised() {
        let none: VoiceGuardLevel? = nil
        XCTAssertEqual(VoiceGuard.word(for: none), .pending)
        XCTAssertEqual(VoiceGuard.word(for: VoiceGuardLevel.verified), .verified)
        XCTAssertEqual(VoiceGuard.word(for: VoiceGuardLevel.caution), .caution)
        XCTAssertEqual(VoiceGuard.word(for: VoiceGuardLevel.highRisk), .highRisk)
        XCTAssertEqual(VoiceGuard.word(for: VoiceGuard.level(of: .unknown)), .pending)
        XCTAssertEqual(VoiceGuard.word(for: VoiceGuard.level(of: .steady)), .verified)
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

    /// With no level and no sample there is nothing to compare: the card then
    /// shows just the "Dati insufficienti" word, whatever a finished or idle
    /// learning session says.
    func testWaitsForVoiceDataUntilThereIsALevelOrASample() {
        let states: [VoiceLearningSession.State?] = [nil, .idle, .failed, .completed(contactId: "c1")]
        for state in states {
            XCTAssertEqual(VoiceGuard.content(banner: nil, learning: state, hasHistory: false, level: nil),
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
        XCTAssertEqual(VoiceGuard.bannerTone(of: .learned), .success)
        XCTAssertEqual(VoiceGuard.bannerTone(of: .failed), .riskHigh)
        XCTAssertNil(VoiceGuard.bannerTone(of: nil))
        XCTAssertEqual(VoiceGuard.bannerSeconds, 3.5)
    }

    func testLearningProgressIsKeptInsideTheBar() {
        XCTAssertEqual(VoiceGuard.clampedProgress(-0.2), 0)
        XCTAssertEqual(VoiceGuard.clampedProgress(1.7), 1)
        XCTAssertEqual(VoiceGuard.clampedProgress(.nan), 0)
        XCTAssertEqual(VoiceGuard.percentText(0.5), "50%")
        XCTAssertEqual(VoiceGuard.percentText(2), "100%")
    }

    // MARK: - Custody of the voice card

    func testPostQuantumCellNamesTheAlgorithmOnlyWhileActive() {
        XCTAssertEqual(VoiceCustody.postQuantumValue(active: true), "ML-KEM")
        let inactive = VoiceCustody.postQuantumValue(active: false)
        XCTAssertEqual(inactive, VoiceCustodyCopy.postQuantumOff)
        XCTAssertFalse(inactive.isEmpty)
        XCTAssertFalse(inactive.contains("ML-KEM"))
    }

    func testIdentityCellShowsTheCheckOnlyOnceVerified() {
        XCTAssertEqual(VoiceCustody.identityValue(verified: true), "SAS ✓")
        let pending = VoiceCustody.identityValue(verified: false)
        XCTAssertEqual(pending, VoiceCustodyCopy.identityUnverified)
        XCTAssertFalse(pending.contains("✓"))
    }

    /// No label of the custody card is left empty (a missing catalog entry would
    /// fall back to the Italian default, never to an empty string).
    func testCustodyLabelsAreAllPresent() {
        let labels = [VoiceCustodyCopy.title, VoiceCustodyCopy.sealedBySoftware, VoiceCustodyCopy.boundary,
                      VoiceCustodyCopy.microphone, VoiceCustodyCopy.exposed, VoiceCustodyCopy.ciphertext,
                      VoiceCustodyCopy.sealedOnPhone, VoiceCustodyCopy.identity, VoiceCustodyCopy.postQuantum,
                      VoiceCustodyCopy.cipher, VoiceCustodyCopy.sealPoint, VoiceCustodyCopy.phone]
        for label in labels {
            XCTAssertFalse(label.isEmpty)
        }
    }

    /// The box may say which cipher and key exchange protect the call only when
    /// the post-quantum exchange is really active; the microphone statement stays.
    func testCustodyVerdictNamesTheExchangeOnlyWhenActive() {
        let active = VoiceCustody.verdictText(pqcActive: true)
        let inactive = VoiceCustody.verdictText(pqcActive: false)
        XCTAssertTrue(active.contains("ML-KEM-1024"))
        XCTAssertTrue(active.contains("AES-256"))
        XCTAssertTrue(active.contains("Keychain"))
        XCTAssertFalse(inactive.contains("ML-KEM"))
        XCTAssertFalse(inactive.contains("AES"))
        XCTAssertFalse(inactive.contains("Keychain"))
        XCTAssertFalse(inactive.isEmpty)
        XCTAssertNotEqual(active, inactive)
    }

    func testCustodyVerdictNeverClaimsTheSecureEnclave() {
        for pqc in [true, false] {
            XCTAssertFalse(VoiceCustody.verdictText(pqcActive: pqc).contains("Secure Enclave"))
            XCTAssertFalse(VoiceCustody.verdictText(pqcActive: pqc).contains("TrustZone"))
        }
    }

    // MARK: - Wave: the trend

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

    // MARK: - Wave: which picture it draws

    /// The 40 log-spaced bands of the analyser. A literal on purpose: this bundle keeps to pure value tests
    /// (see project-apptests.yml).
    private let bands = 40

    private func spectrum(_ value: Float, count: Int? = nil) -> [Float] {
        [Float](repeating: value, count: count ?? bands)
    }

    /// The wave overlays the live spectrum on the reference of the call only
    /// when it has both, with the same number of bands.
    func testTheWaveOverlaysOnlyWithBothSpectraOfTheSameSize() {
        XCTAssertTrue(VoiceGuardWave.overlaysReference(live: spectrum(0.5), reference: spectrum(0.4)))
        XCTAssertFalse(VoiceGuardWave.overlaysReference(live: nil, reference: spectrum(0.4)))
        XCTAssertFalse(VoiceGuardWave.overlaysReference(live: spectrum(0.5), reference: nil))
        XCTAssertFalse(VoiceGuardWave.overlaysReference(live: nil, reference: nil))
        XCTAssertFalse(VoiceGuardWave.overlaysReference(live: spectrum(0.5, count: 39), reference: spectrum(0.4)))
        XCTAssertFalse(VoiceGuardWave.overlaysReference(live: spectrum(0.5), reference: spectrum(0.4, count: 41)))
    }

    func testThePictureFollowsTheSameTest() {
        XCTAssertEqual(VoiceGuardWave.picture(live: spectrum(0.5), reference: spectrum(0.4)), .overlay)
        XCTAssertEqual(VoiceGuardWave.picture(live: spectrum(0.5), reference: nil), .trend, "opening seconds of a call")
        XCTAssertEqual(VoiceGuardWave.picture(live: nil, reference: nil), .trend)
        XCTAssertEqual(VoiceGuardWave.picture(live: spectrum(0.5, count: 10), reference: spectrum(0.4)), .trend)
    }

    /// The words read aloud must describe the picture on screen: the two
    /// pictures have two different labels, and swapping them would fail here.
    func testEachPictureHasItsOwnSpokenLabel() {
        let overlay = VoiceWaveCopy.accessibilityLabel(for: .overlay)
        let trend = VoiceWaveCopy.accessibilityLabel(for: .trend)
        XCTAssertFalse(overlay.isEmpty)
        XCTAssertFalse(trend.isEmpty)
        XCTAssertNotEqual(overlay, trend)
        let picture = VoiceGuardWave.picture(live: spectrum(0.5), reference: spectrum(0.4))
        XCTAssertEqual(VoiceWaveCopy.accessibilityLabel(for: picture), overlay)
        let opening = VoiceGuardWave.picture(live: spectrum(0.5), reference: nil)
        XCTAssertEqual(VoiceWaveCopy.accessibilityLabel(for: opening), trend)
    }

    // MARK: - Wave: the overlay

    /// A louder band is shown at once; a quieter one falls by steps, keeping
    /// 78 % of the old height each time.
    func testTheLiveOutlineRisesAtOnceAndFallsBySteps() {
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 0.2, target: 0.9), 0.9)
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 0.5, target: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 1.0, target: 0.0), 0.78, accuracy: 1e-6)
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 0.5, target: 0.1),
                       0.5 * 0.78 + 0.1 * 0.22, accuracy: 1e-6)
        var shown: Float = 1
        for _ in 0..<40 {
            shown = VoiceGuardWave.nextDisplay(previous: shown, target: 0)
        }
        XCTAssertLessThan(shown, 0.001, "silence lets the outline settle")
    }

    /// The fall is counted in spectrum frames and measured on the clock: a frame
    /// is 1/15 s, and a stretch of time that is not positive is worth nothing.
    func testTimeIsCountedInSpectrumFrames() {
        XCTAssertEqual(VoiceGuardWave.framesPerSecond, 15)
        XCTAssertEqual(VoiceGuardWave.frameSteps(elapsed: 1.0 / 15.0), 1, accuracy: 1e-5)
        XCTAssertEqual(VoiceGuardWave.frameSteps(elapsed: 1), 15, accuracy: 1e-5)
        XCTAssertEqual(VoiceGuardWave.frameSteps(elapsed: 0.5 / 15.0), 0.5, accuracy: 1e-5)
        XCTAssertEqual(VoiceGuardWave.frameSteps(elapsed: 0), 0)
        XCTAssertEqual(VoiceGuardWave.frameSteps(elapsed: -0.2), 0, "a clock that ran backwards changes nothing")
        XCTAssertEqual(VoiceGuardWave.frameSteps(elapsed: .nan), 0)
        XCTAssertEqual(VoiceGuardWave.frameSteps(elapsed: .infinity), 0)
    }

    /// One whole frame is the old fixed step; no time leaves the height as it
    /// was; a rise is never slowed down by the time that passed.
    func testTheFallFollowsTheNumberOfFramesThatPassed() {
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 1, target: 0, steps: 1), 0.78, accuracy: 1e-6)
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 1, target: 0, steps: 2), 0.78 * 0.78, accuracy: 1e-6)
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 0.6, target: 0.2, steps: 0), 0.6, "a draw in the same instant steps nothing")
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 0.6, target: 0.2, steps: .nan), 0.6)
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 0.2, target: 0.9, steps: 0), 0.9, "a louder band is shown at once")
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 0.2, target: 0.9, steps: 5), 0.9)
        XCTAssertEqual(VoiceGuardWave.nextDisplay(previous: 0.8, target: 0.2, steps: 1_000_000), 0.2, accuracy: 1e-6,
                       "a long gap settles on the target")
    }

    /// The point of the clock: the same second of silence leaves the same height
    /// whether the wave was redrawn 15 times, 60 times or twice in it. The old
    /// step per draw made the outline fall four times as fast at 60 draws a
    /// second as at 15.
    func testTheFallDoesNotDependOnHowOftenTheWaveIsDrawn() {
        func height(afterDrawsPerSecond draws: Int) -> Float {
            var shown: Float = 1
            for _ in 0..<draws {
                let steps = VoiceGuardWave.frameSteps(elapsed: 1.0 / Double(draws))
                shown = VoiceGuardWave.nextDisplay(previous: shown, target: 0, steps: steps)
            }
            return shown
        }
        let atFrameRate = height(afterDrawsPerSecond: 15)
        XCTAssertEqual(atFrameRate, Float(pow(0.78, 15.0)), accuracy: 1e-5)
        XCTAssertEqual(height(afterDrawsPerSecond: 60), atFrameRate, accuracy: 1e-5)
        XCTAssertEqual(height(afterDrawsPerSecond: 120), atFrameRate, accuracy: 1e-5)
        XCTAssertEqual(height(afterDrawsPerSecond: 2), atFrameRate, accuracy: 1e-5)
    }

    /// Both curves share ONE scale, the peak of either of them: scaling each on
    /// its own would make them agree even when they do not.
    func testBothCurvesAreScaledByTheSamePeak() {
        let reference: [Float] = [0.2, 0.4, 0.1]
        let live: [Float] = [0.1, 0.8, 0.1]
        guard let overlay = VoiceGuardWave.overlay(display: live, reference: reference) else {
            return XCTFail("two non-zero curves can be overlaid")
        }
        let expectedLive: [Float] = [0.125, 1.0, 0.125]
        let expectedReference: [Float] = [0.25, 0.5, 0.125]
        XCTAssertEqual(overlay.live.count, 3)
        XCTAssertEqual(overlay.reference.count, 3)
        for index in 0..<3 {
            XCTAssertEqual(overlay.live[index], expectedLive[index], accuracy: 1e-6)
            XCTAssertEqual(overlay.reference[index], expectedReference[index], accuracy: 1e-6)
        }
    }

    func testAnIdenticalPairOfCurvesCoincidesExactly() {
        let curve: [Float] = [0.1, 0.6, 0.3, 0.05]
        guard let overlay = VoiceGuardWave.overlay(display: curve, reference: curve) else {
            return XCTFail("a non-zero curve can be overlaid")
        }
        XCTAssertEqual(overlay.live, overlay.reference)
        XCTAssertEqual(overlay.live.max() ?? 0, 1, accuracy: 1e-6, "the larger curve fills the box")
    }

    /// Digital silence in the opening seconds, together with live bands that
    /// have decayed to zero, leaves nothing to scale by: the wave falls back to
    /// the trend instead of dividing by zero.
    func testAllZeroCurvesFallBackToTheTrend() {
        XCTAssertNil(VoiceGuardWave.overlay(display: spectrum(0), reference: spectrum(0)))
        XCTAssertNil(VoiceGuardWave.overlay(display: [], reference: []))
        XCTAssertNil(VoiceGuardWave.overlay(display: [.nan, .nan], reference: [0, 0]))
    }

    func testAQuietReferenceStillOverlaysWithALoudLiveVoice() {
        guard let overlay = VoiceGuardWave.overlay(display: [0.9, 0.9], reference: [0, 0]) else {
            return XCTFail("a flat reference can still be overlaid")
        }
        XCTAssertEqual(overlay.reference, [0, 0])
        XCTAssertEqual(overlay.live.count, 2)
        XCTAssertEqual(overlay.live[0], 1, accuracy: 1e-6)
        XCTAssertEqual(overlay.live[1], 1, accuracy: 1e-6)
    }

    func testTheOverlayNeverExceedsTheBox() {
        guard let overlay = VoiceGuardWave.overlay(display: [3, 0.2, 7], reference: [5, 9, 0.1]) else {
            return XCTFail("non-zero curves can be overlaid")
        }
        for value in overlay.live + overlay.reference {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    // MARK: - Voice check card: when the wave is shown

    /// The level, when known, always wins: it is shown even while the confidence
    /// history is still empty (the wave then has a spectrum overlay or a flat
    /// trace to draw). "Dati insufficienti" alone is for no level and no sample.
    func testALevelIsShownEvenBeforeTheFirstConfidenceSample() {
        XCTAssertEqual(VoiceGuard.content(banner: nil, learning: nil, hasHistory: false, level: .verified),
                       .verdict(level: .verified))
        XCTAssertEqual(VoiceGuard.content(banner: nil, learning: nil, hasHistory: false, level: .highRisk),
                       .verdict(level: .highRisk))
    }

    func testNoLevelAndNoSampleIsTheBareInsufficientDataLine() {
        XCTAssertEqual(VoiceGuard.content(banner: nil, learning: nil, hasHistory: false, level: nil), .waiting)
    }
}
