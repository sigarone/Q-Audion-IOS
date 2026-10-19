import XCTest
@testable import QAudionApp
import QAudionEngine

/// The tone row and the technical-data block against the validity flags of the voice analysis, and the
/// words they print in the six languages of the app.
///
/// What this pins:
///  - every value the screens print follows the validity flag of its own measurement, and a value that
///    is not a reading right now reaches them as NaN (a dash), never as a zero;
///  - the details of the tone row are one line, "F1 520 · F2 1480 · 4,2 sill/s · HNR 18 dB", with the
///    syllables-per-second abbreviation and the decimal separator of the language;
///  - the abbreviation and the word a screen reader says in place of a dash exist in all six languages.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing`
/// list of `.github/workflows/ios-app-tests.yml`.
final class VoiceToneRowTests: XCTestCase {

    // MARK: - From a display value to the screens

    private func result(f0: Float? = 142, voiced: Bool = true,
                        f1: Float? = 524, f2: Float? = 1478,
                        hnr: Float? = 18.4, rate: Float? = 4.24,
                        jitter: Float? = 0.012, shimmer: Float = 0.031) -> VoiceAnalysisResult {
        VoiceAnalysisResult(
            pitch: .init(f0Hz: f0 ?? 0, voiced: voiced, rms: 0.1, f0Valid: f0 != nil),
            stress: .init(score: 0.2, jitter: jitter ?? 0, shimmer: jitter == nil ? 0 : shimmer, valid: jitter != nil),
            voiceHealth: .init(hnr: hnr ?? 0, breathiness: 0.2, hnrValid: hnr != nil),
            speechRate: .init(syllablesPerSec: rate ?? 0, pauseRatio: 0.2, isSpeaking: true, valid: rate != nil),
            formants: .init(f1: f1 ?? 0, f2: f2 ?? 0, f3: 0, f4: 0,
                            f1Found: f1 != nil, f2Found: f2 != nil, f3Found: false, f4Found: false),
            confidence: 0.8)
    }

    func testValidMeasurementsReachTheScreensAsTheyAre() {
        let bio = InCallScreen.VoiceBiometrics(result())
        XCTAssertEqual(bio.pitchHz, 142)
        XCTAssertEqual(bio.f1, 524)
        XCTAssertEqual(bio.f2, 1478)
        XCTAssertEqual(bio.hnr, 18.4, accuracy: 1e-5)
        XCTAssertEqual(bio.syllablesPerSec, 4.24, accuracy: 1e-5)
        XCTAssertEqual(bio.jitter, 0.012, accuracy: 1e-6)
        XCTAssertEqual(bio.shimmer, 0.031, accuracy: 1e-6)
        XCTAssertTrue(bio.pitchVoiced)
    }

    func testEveryMeasurementThatIsNotValidReachesTheScreensAsNoValue() {
        let bio = InCallScreen.VoiceBiometrics(result(f0: nil, voiced: false, f1: nil, f2: nil,
                                                      hnr: nil, rate: nil, jitter: nil))
        XCTAssertTrue(bio.pitchHz.isNaN, "f0 that is not valid")
        XCTAssertTrue(bio.f1.isNaN, "F1 that was not found")
        XCTAssertTrue(bio.f2.isNaN, "F2 that was not found")
        XCTAssertTrue(bio.hnr.isNaN, "HNR that is not valid")
        XCTAssertTrue(bio.syllablesPerSec.isNaN, "speech rate that is not valid")
        XCTAssertTrue(bio.jitter.isNaN, "jitter that is not valid")
        XCTAssertTrue(bio.shimmer.isNaN, "shimmer that is not valid")
        XCTAssertFalse(bio.pitchVoiced)
    }

    func testEachMeasurementFollowsItsOwnFlagNotTheOthers() {
        // Only the rate is missing: the others are shown.
        let noRate = InCallScreen.VoiceBiometrics(result(rate: nil))
        XCTAssertTrue(noRate.syllablesPerSec.isNaN)
        XCTAssertFalse(noRate.pitchHz.isNaN)
        XCTAssertFalse(noRate.hnr.isNaN)
        XCTAssertFalse(noRate.f1.isNaN)
        // Only F2 is missing.
        let noF2 = InCallScreen.VoiceBiometrics(result(f2: nil))
        XCTAssertTrue(noF2.f2.isNaN)
        XCTAssertFalse(noF2.f1.isNaN)
    }

    /// The voiced flag chooses a word and a tint, not whether a number exists: a display value whose
    /// pitch is a reading shows it even when the majority of the last second was not voiced.
    func testAPitchThatIsAReadingIsShownWhateverTheVoicedMajority() {
        let bio = InCallScreen.VoiceBiometrics(result(f0: 131, voiced: false))
        XCTAssertEqual(bio.pitchHz, 131)
        XCTAssertFalse(bio.pitchVoiced)
        XCTAssertEqual(VoiceGauges.pitch(hz: bio.pitchHz, voiced: bio.pitchVoiced).value, "131")
    }

    func testTheTechnicalBlockPrintsADashForEveryMissingValueAndNeverAZero() {
        let bio = InCallScreen.VoiceBiometrics(result(f0: nil, voiced: false, f1: nil, f2: nil,
                                                      hnr: nil, rate: nil, jitter: nil))
        let english = Locale(identifier: "en")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitterPercent: bio.jitter * 100,
                                                           shimmerPercent: bio.shimmer * 100,
                                                           locale: english), "—")
        XCTAssertEqual(VoiceBiometricsFormat.pitchRate(hz: bio.pitchHz, syllablesPerSecond: bio.syllablesPerSec,
                                                       syllableUnit: "u", locale: english), "— · —")
        XCTAssertEqual(VoiceBiometricsFormat.hnr(bio.hnr), "—")
        XCTAssertEqual(VoiceBiometricsFormat.pitch(hz: bio.pitchHz), "—")
        let row = VoiceGauges.pitch(hz: bio.pitchHz, voiced: bio.pitchVoiced)
        XCTAssertEqual(row.value, "—")
        XCTAssertEqual(VoiceSpectralDetails.text(formant1Hz: bio.f1, formant2Hz: bio.f2,
                                                 syllablesPerSecond: bio.syllablesPerSec,
                                                 hnrDecibels: bio.hnr, rateUnit: "u",
                                                 locale: Locale(identifier: "en_US")),
                       "F1 — · F2 — · — u · HNR —")
    }

    func testTheTechnicalBlockPrintsValidValues() {
        let bio = InCallScreen.VoiceBiometrics(result())
        let english = Locale(identifier: "en")
        let italian = Locale(identifier: "it")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitterPercent: bio.jitter * 100,
                                                           shimmerPercent: bio.shimmer * 100,
                                                           locale: english), "1.2% / 3.1%")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitterPercent: bio.jitter * 100,
                                                           shimmerPercent: bio.shimmer * 100,
                                                           locale: italian), "1,2% / 3,1%")
        XCTAssertEqual(VoiceBiometricsFormat.pitchRate(hz: bio.pitchHz, syllablesPerSecond: bio.syllablesPerSec,
                                                       syllableUnit: "u", locale: english), "142 Hz · 4.2 u")
        XCTAssertEqual(VoiceBiometricsFormat.pitchRate(hz: bio.pitchHz, syllablesPerSecond: bio.syllablesPerSec,
                                                       syllableUnit: "u", locale: italian), "142 Hz · 4,2 u")
        XCTAssertEqual(VoiceBiometricsFormat.hnr(bio.hnr), "18 dB")
    }

    // MARK: - The tone row in the six languages

    private struct Language {
        let catalogKey: String
        let locale: String
        let unit: String
        let decimalSeparator: String
    }

    private let languages: [Language] = [
        Language(catalogKey: "it", locale: "it_IT", unit: "sill/s", decimalSeparator: ","),
        Language(catalogKey: "en", locale: "en_US", unit: "syl/s", decimalSeparator: "."),
        Language(catalogKey: "de", locale: "de_DE", unit: "Silb./s", decimalSeparator: ","),
        Language(catalogKey: "es", locale: "es_ES", unit: "síl/s", decimalSeparator: ","),
        Language(catalogKey: "fr", locale: "fr_FR", unit: "syll/s", decimalSeparator: ","),
        Language(catalogKey: "pt-BR", locale: "pt_BR", unit: "síl/s", decimalSeparator: ","),
    ]

    func testTheRateUnitIsTheSameWordsInTheCatalogForAllSixLanguages() throws {
        let entry = try catalogEntry("in_call.bio.syllables_unit")
        for language in languages {
            XCTAssertEqual(try catalogValue(entry, language.catalogKey), language.unit, language.catalogKey)
        }
    }

    func testTheDetailsLineIsOneLineWithTheLocalDecimalSeparatorAndUnit() throws {
        let entry = try catalogEntry("in_call.bio.syllables_unit")
        for language in languages {
            let unit = try catalogValue(entry, language.catalogKey)
            let text = VoiceSpectralDetails.text(formant1Hz: 524, formant2Hz: 1478, syllablesPerSecond: 4.24,
                                                 hnrDecibels: 18.4, rateUnit: unit,
                                                 locale: Locale(identifier: language.locale))
            XCTAssertEqual(text, "F1 520 · F2 1480 · 4\(language.decimalSeparator)2 \(unit) · HNR 18 dB", language.catalogKey)
        }
    }

    func testTheWordForAnUnavailableValueExistsInAllSixLanguagesAndDiffersFromTheUnits() throws {
        let entry = try catalogEntry("in_call.gauge.a11y_unavailable")
        var seen = Set<String>()
        for language in languages {
            let word = try catalogValue(entry, language.catalogKey)
            XCTAssertFalse(word.isEmpty, language.catalogKey)
            XCTAssertFalse(word.contains("—"), "a word, not the dash: \(language.catalogKey)")
            seen.insert(word)
        }
        XCTAssertEqual(seen.count, 6, "six different translations")
    }

    // MARK: - Catalog and source access

    private func sourceURL(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw NSError(domain: "VoiceToneRowTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(relativePath) not found from \(file)"])
    }

    private func catalogEntry(_ key: String) throws -> [String: Any] {
        let data = try Data(contentsOf: sourceURL("QAudionApp/Localizable.xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        return try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
    }

    private func catalogValue(_ entry: [String: Any], _ language: String) throws -> String {
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let one = try XCTUnwrap(localizations[language] as? [String: Any], "missing language: \(language)")
        let unit = try XCTUnwrap(one["stringUnit"] as? [String: Any], language)
        return try XCTUnwrap(unit["value"] as? String, language)
    }
}
