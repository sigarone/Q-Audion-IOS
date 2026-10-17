import XCTest
@testable import QAudionApp
import QAudionEngine

/// The voice analysis of the call screen: pitch reading of the ribbon, "voice
/// check" card and technical-data rows. The decisions live in
/// `VoiceGuardModel.swift` as pure functions (value in, word / colour role /
/// text out), so the thresholds, the wording and the number formats are pinned
/// here without any UI. Stress, breath and authenticity readings are gone on
/// purpose: they are not validated for phone-quality speech.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in
/// the `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class VoiceGuardModelTests: XCTestCase {

    // MARK: - Pitch reading

    func testPitchHasNoStatusWordWhileVoicedAndADashWhenNot() {
        XCTAssertEqual(VoiceGauges.pitch(hz: 142.7, voiced: true).status, .none)
        XCTAssertEqual(VoiceGauges.pitch(hz: 0, voiced: false).status, .dash)
        XCTAssertEqual(VoiceGauges.pitch(hz: 142.7, voiced: true).value, "142")
        XCTAssertEqual(VoiceGauges.pitch(hz: 142.7, voiced: true).unit, "Hz")
    }

    func testPitchIsNeverColoured() {
        XCTAssertEqual(VoiceGauges.pitch(hz: 142, voiced: true).tone, .neutral)
        XCTAssertEqual(VoiceGauges.pitch(hz: 0, voiced: false).tone, .neutral)
    }

    func testPitchHasOnlyTheTwoStates() {
        XCTAssertEqual(VoiceGauges.pitch(hz: 120, voiced: true).status, .none)
        XCTAssertEqual(VoiceGauges.pitch(hz: 120, voiced: false).status, .dash)
    }

    /// The dash printed for a missing value or an unvoiced pitch is the only
    /// status text that is not a word, so it needs no translation.
    func testTheDashIsNotLanguage() {
        XCTAssertEqual(VoiceGaugeStatus.dash.localizedText, "—")
        XCTAssertEqual(VoiceGaugeStatus.none.localizedText, "")
    }

    /// The pitch reading has no status word beyond the dash: the two states it
    /// can have print nothing and a dash, never a word about the speaker.
    func testPitchStatusHasNoWordsOfItsOwn() {
        let all: [VoiceGaugeStatus] = [.none, .dash]
        XCTAssertEqual(all.map { $0.localizedText }, ["", "—"])
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

    /// Before the first sample there is nothing to compare: the card then shows
    /// the same "Dati insufficienti" word as a verdict without a level.
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
