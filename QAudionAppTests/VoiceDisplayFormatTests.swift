import XCTest
@testable import QAudionApp
import QAudionEngine

/// The display formatting of the voice analysis against the shared acceptance table of
/// `docs/voice-analysis-spec.md`, section 12: the tone row of the ribbon, the technical-data block and the video
/// diagnostics print exactly these strings for exactly these inputs, in Italian and in English.
///
/// The table is `QAudionAppTests/voice-analysis/display-format-cases.tsv`, a byte-for-byte copy of the file the
/// Android app runs too, so the two apps print the same text for the same values. Its inputs are decimal text read
/// as binary32 (a dash is a measurement whose flag is not set, which the screens hand over as NaN), with jitter and
/// shimmer as percentages.
///
/// What it pins: every displayed number is rounded half away from zero by an explicit rule (the exact binary ties
/// 142.5, 4.25, -2.5 and 1475 included, and the values just under a tie that binary32 stores below it), the
/// decimal separator comes from the language of the app, f0 is the rounded value everywhere, and each part that
/// is not a reading is a dash of its own. Also pinned: the tone is "143 Hz" or the dash alone, never "— Hz"; the
/// widest line of the details (the line the tone row is sized on) is at least as long as every line of the
/// table; the separator follows the same choice of language as the text of the screen, for any language the
/// device prefers (it-CH, de-CH and en-ZA included); and the table reads the same with CRLF line endings.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class VoiceDisplayFormatTests: XCTestCase {

    // MARK: - The shared table

    private struct Case {
        let id: String
        let f0: Float
        let f1: Float
        let f2: Float
        let rate: Float
        let hnr: Float
        let jitter: Float
        let shimmer: Float
        let expected: [String: String]
    }

    private static let inputColumns: Set<String> = ["id", "f0", "f1", "f2", "rate", "hnr", "jitter", "shimmer"]

    private static let columns = ["id", "f0", "f1", "f2", "rate", "hnr", "jitter", "shimmer", "tone",
                                  "details_it", "details_en", "pitch_rate_it", "pitch_rate_en",
                                  "jitter_shimmer_it", "jitter_shimmer_en", "hnr_row"]

    private func sourceURL(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw NSError(domain: "VoiceDisplayFormatTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(relativePath) not found from \(file)"])
    }

    /// A number of the table: decimal text read as binary32, or NaN for a dash (a field that is not a reading).
    private func number(_ text: String, row: String) throws -> Float {
        if text == "-" { return .nan }
        return try XCTUnwrap(Float(text), "\(row): \(text) is not a number")
    }

    private func loadCases() throws -> [Case] {
        let url = try sourceURL("QAudionAppTests/voice-analysis/display-format-cases.tsv")
        return try parseCases(try String(contentsOf: url, encoding: .utf8))
    }

    /// The cases of the text of the table. The lines end with LF or with CRLF (a checkout on Windows may convert the
    /// file), and `\r\n` is ONE Character in Swift: splitting on "\n" would not split a CRLF file at all, while
    /// `isNewline` is true for both.
    private func parseCases(_ text: String) throws -> [Case] {
        var rows: [[String]] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("#") { continue }
            rows.append(line.components(separatedBy: "\t"))
        }
        let header = try XCTUnwrap(rows.first, "the table has no header")
        XCTAssertEqual(header, Self.columns, "the columns of the table changed")
        var cases: [Case] = []
        for row in rows.dropFirst() {
            XCTAssertEqual(row.count, header.count, "a row with the wrong number of columns: \(row.first ?? "")")
            guard row.count == header.count else { continue }
            let id = row[0]
            var expected: [String: String] = [:]
            for (name, value) in zip(header, row) where !Self.inputColumns.contains(name) {
                expected[name] = value
            }
            cases.append(Case(id: id,
                              f0: try number(row[1], row: id), f1: try number(row[2], row: id),
                              f2: try number(row[3], row: id), rate: try number(row[4], row: id),
                              hnr: try number(row[5], row: id), jitter: try number(row[6], row: id),
                              shimmer: try number(row[7], row: id), expected: expected))
        }
        return cases
    }

    private let italian = Locale(identifier: "it")
    private let english = Locale(identifier: "en")

    /// Every row of the table through the formatters of the three screens, in both languages.
    func testEveryRowOfTheSharedTable() throws {
        let cases = try loadCases()
        XCTAssertGreaterThan(cases.count, 50, "the table was not read in full")
        var failures: [String] = []
        func check(_ id: String, _ column: String, _ actual: String?, _ expected: String?) {
            if actual != expected {
                failures.append("\(id) \(column): got \(actual ?? "nil"), expected \(expected ?? "nil")")
            }
        }
        for c in cases {
            let e = c.expected
            check(c.id, "tone", VoiceGauges.pitch(hz: c.f0).value, e["tone"])
            check(c.id, "details_it",
                  VoiceSpectralDetails.text(formant1Hz: c.f1, formant2Hz: c.f2, syllablesPerSecond: c.rate,
                                            hnrDecibels: c.hnr, rateUnit: "sill/s", locale: italian),
                  e["details_it"])
            check(c.id, "details_en",
                  VoiceSpectralDetails.text(formant1Hz: c.f1, formant2Hz: c.f2, syllablesPerSecond: c.rate,
                                            hnrDecibels: c.hnr, rateUnit: "syl/s", locale: english),
                  e["details_en"])
            check(c.id, "pitch_rate_it",
                  VoiceBiometricsFormat.pitchRate(hz: c.f0, syllablesPerSecond: c.rate, syllableUnit: "sill/s",
                                                  locale: italian),
                  e["pitch_rate_it"])
            check(c.id, "pitch_rate_en",
                  VoiceBiometricsFormat.pitchRate(hz: c.f0, syllablesPerSecond: c.rate, syllableUnit: "syl/s",
                                                  locale: english),
                  e["pitch_rate_en"])
            check(c.id, "jitter_shimmer_it",
                  VoiceBiometricsFormat.jitterShimmer(jitterPercent: c.jitter, shimmerPercent: c.shimmer,
                                                      locale: italian),
                  e["jitter_shimmer_it"])
            check(c.id, "jitter_shimmer_en",
                  VoiceBiometricsFormat.jitterShimmer(jitterPercent: c.jitter, shimmerPercent: c.shimmer,
                                                      locale: english),
                  e["jitter_shimmer_en"])
            check(c.id, "hnr_row", VoiceBiometricsFormat.hnr(c.hnr), e["hnr_row"])
            // The HNR of the tone row is the same number as the row of the technical block, and the f0 of the
            // video diagnostics is the f0 of the technical block (spec section 12.3).
            check(c.id, "hnr (tone row)", VoiceSpectralDetails.hnr(c.hnr), e["hnr_row"])
            // The tone is the number and " Hz", or the dash alone (12.5): the same text on the tone row and in the
            // video diagnostics.
            let toneValue = e["tone"] ?? ""
            let toneText = toneValue == VoiceGauges.noValue ? toneValue : toneValue + " Hz"
            check(c.id, "tone row text", VoiceGauges.pitch(hz: c.f0).text, toneText)
            check(c.id, "tone row unit", VoiceGauges.pitch(hz: c.f0).unit,
                  toneValue == VoiceGauges.noValue ? "" : "Hz")
            check(c.id, "video pitch", VoiceBiometricsFormat.pitch(hz: c.f0), toneText)
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) differences from the table, first ones:\n"
                                        + failures.prefix(20).joined(separator: "\n"))
    }

    /// The table has the rows the specification names: the ties, the values just under a tie, the guards, and
    /// every kind of missing field. A table that lost them would pass the test above for nothing.
    func testTheSharedTableHasTheNamedCases() throws {
        let ids = Set(try loadCases().map { $0.id })
        for name in ["f0_tie_half", "formant_tie_up", "rate_tie_4_25", "rate_binary32_below_4_35",
                     "hnr_tie_neg", "hnr_no_negative_zero", "all_missing", "f0_missing", "rate_missing",
                     "hnr_missing", "jitter_missing", "guard_f0_zero", "guard_rate_negative"] {
            XCTAssertTrue(ids.contains(name), name)
        }
    }

    // MARK: - The rounding rule itself

    /// Half away from zero, explicitly: ties go outward on both sides of zero, and a value just under a tie
    /// does not (the classic `floor(x + 0.5)` gets 0.49999999999999994 wrong).
    func testRoundHalfAwayFromZero() {
        let rows: [(Double, Double)] = [
            (0.5, 1), (1.5, 2), (2.5, 3), (142.5, 143), (-0.5, -1), (-1.5, -2), (-2.5, -3), (-142.5, -143),
            (0.49999999999999994, 0), (-0.49999999999999994, 0), (2.4999999999999996, 2), (0, 0), (4.25 * 10, 43),
        ]
        for (value, expected) in rows {
            XCTAssertEqual(VoiceNumberFormat.roundHalfAwayFromZero(value), expected, "\(value)")
        }
    }

    /// A value that rounds to zero never carries a minus sign.
    func testNeverANegativeZero() {
        XCTAssertEqual(VoiceNumberFormat.whole(-0.4), "0")
        XCTAssertEqual(VoiceNumberFormat.oneDecimal(-0.04, locale: english), "0.0")
        XCTAssertEqual(VoiceNumberFormat.nearestTen(-4), "0")
        XCTAssertEqual(VoiceNumberFormat.oneDecimal(-0.25, locale: italian), "-0,3")
    }

    /// Anything that is not a finite number of a sane size is not a reading.
    func testWhatIsNotANumberIsNotAReading() {
        XCTAssertNil(VoiceNumberFormat.whole(.nan))
        XCTAssertNil(VoiceNumberFormat.whole(.infinity))
        XCTAssertNil(VoiceNumberFormat.whole(-.infinity))
        XCTAssertNil(VoiceNumberFormat.whole(1e12))
        XCTAssertNil(VoiceNumberFormat.nearestTen(.nan))
        XCTAssertNil(VoiceNumberFormat.oneDecimal(.nan, locale: english))
        XCTAssertNil(VoiceNumberFormat.oneDecimal(1e12, locale: english))
        XCTAssertEqual(VoiceGauges.wholeNumber(.infinity), "—")
        XCTAssertEqual(VoiceGauges.wholeNumber(-3), "—", "a negative pitch is not a reading")
        XCTAssertEqual(VoiceSpectralDetails.formant(-5), "—")
        XCTAssertEqual(VoiceSpectralDetails.rate(-1, unit: "u", locale: english), "— u")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitterPercent: -10, shimmerPercent: 10, locale: english),
                       "—")
    }

    /// The six languages of the app: a comma, except in English. Digits are always the ASCII ones.
    func testTheDecimalSeparatorOfTheSixLanguagesOfTheApp() {
        let expected: [(String, String)] = [("it", ","), ("en", "."), ("es", ","), ("fr", ","), ("de", ","),
                                            ("pt-BR", ",")]
        for (code, separator) in expected {
            let locale = Locale(identifier: code)
            XCTAssertEqual(VoiceNumberFormat.decimalSeparator(of: locale), separator, code)
            XCTAssertEqual(VoiceNumberFormat.oneDecimal(4.25, locale: locale), "4\(separator)3", code)
        }
    }

    /// The table reads the same with Unix and with Windows line endings (and with the last line unterminated).
    func testTheTableReadsTheSameWithWindowsLineEndings() throws {
        let url = try sourceURL("QAudionAppTests/voice-analysis/display-format-cases.tsv")
        let unix = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertTrue(windows.contains("\r\n"), "the copy under test has CRLF line endings")
        let fromUnix = try parseCases(unix)
        let fromWindows = try parseCases(windows)
        let fromUnterminated = try parseCases(String(unix.dropLast()))
        XCTAssertGreaterThan(fromUnix.count, 50)
        for other in [fromWindows, fromUnterminated] {
            XCTAssertEqual(other.map { $0.id }, fromUnix.map { $0.id })
            XCTAssertEqual(other.map { $0.expected }, fromUnix.map { $0.expected })
            XCTAssertEqual(other.map { $0.f0.bitPattern }, fromUnix.map { $0.f0.bitPattern })
        }
    }

    // MARK: - The widest line (12.5)

    /// "F1 1100 · F2 3200 · 12,0 sill/s · HNR -40 dB" in the language of the app, and no line of the table, in either
    /// language, is longer than it. (The font of the tone row is monospaced, so the number of characters stands for
    /// the width, and a line that is not longer than the widest one fits where it fits.)
    func testNoLineOfTheTableIsLongerThanTheWidestLine() throws {
        let widestItalian = VoiceSpectralDetails.widestLine(rateUnit: "sill/s", locale: italian)
        let widestEnglish = VoiceSpectralDetails.widestLine(rateUnit: "syl/s", locale: english)
        XCTAssertEqual(widestItalian, "F1 1100 · F2 3200 · 12,0 sill/s · HNR -40 dB")
        XCTAssertEqual(widestEnglish, "F1 1100 · F2 3200 · 12.0 syl/s · HNR -40 dB")
        for c in try loadCases() {
            XCTAssertLessThanOrEqual(try XCTUnwrap(c.expected["details_it"]).count, widestItalian.count, c.id)
            XCTAssertLessThanOrEqual(try XCTUnwrap(c.expected["details_en"]).count, widestEnglish.count, c.id)
        }
    }

    // MARK: - The separator comes from the language of the app (12.2)

    /// A preferred language of the device goes through the same choice as the text of the screen
    /// (`AppLanguageManager.languageCode`, behind `effectiveLanguageCode`), and the locale of that code decides the
    /// separator: it-CH and de-CH are Italian and German, so a comma, although the region prints a point; en-ZA is
    /// English, so a point; a language the app does not have falls back to Italian, as the text does.
    func testTheSeparatorFollowsTheLanguageOfTheAppWhateverTheRegionOfTheDevice() {
        let rows: [(preferred: String, language: String, separator: String)] = [
            ("it-CH", "it", ","), ("de-CH", "de", ","), ("en-ZA", "en", "."), ("en-GB", "en", "."),
            ("pt-BR", "pt-BR", ","), ("pt-PT", "pt-BR", ","), ("fr-CA", "fr", ","), ("es-419", "es", ","),
            ("ja", "it", ","), ("zh-Hans-CN", "it", ","),
        ]
        for row in rows {
            XCTAssertEqual(AppLanguageManager.languageCode(override: nil, preferredLanguage: row.preferred),
                           row.language, row.preferred)
            let locale = VoiceDisplayLocale.locale(override: nil, preferredLanguage: row.preferred)
            XCTAssertEqual(VoiceNumberFormat.decimalSeparator(of: locale), row.separator, row.preferred)
            XCTAssertEqual(VoiceNumberFormat.oneDecimal(4.25, locale: locale), "4\(row.separator)3", row.preferred)
        }
    }

    /// What the regions above would print if the device locale were used: a point for it-CH and de-CH. This is
    /// the trap the specification names; the test above is not vacuous because of it.
    func testTheRegionsOfTheTrapReallyPrintAPoint() {
        XCTAssertEqual(Locale(identifier: "it_CH").decimalSeparator, ".")
        XCTAssertEqual(Locale(identifier: "de_CH").decimalSeparator, ".")
    }

    /// The override of the app wins over the device language when it is a language the app has, and is ignored
    /// when it is not; with no language at all the Italian text, and the Italian comma, are shown.
    func testTheOverrideAndTheFallbackDecideTheSeparatorLikeTheText() {
        func separator(_ override: String?, _ preferred: String?) -> String {
            VoiceNumberFormat.decimalSeparator(of: VoiceDisplayLocale.locale(override: override,
                                                                              preferredLanguage: preferred))
        }
        XCTAssertEqual(separator("en", "it-CH"), ".", "English set in the app, Italian (Switzerland) on the device")
        XCTAssertEqual(separator("it", "en-US"), ",", "Italian set in the app, English on the device")
        XCTAssertEqual(separator("ja", "en-GB"), ".", "an override the app does not have is ignored")
        XCTAssertEqual(separator("ja", "ko"), ",", "nothing the app has: Italian")
        XCTAssertEqual(separator(nil, nil), ",", "no language at all: Italian")
        XCTAssertEqual(AppLanguageManager.languageCode(override: "ja", preferredLanguage: nil), "it")
    }

    /// With several device languages the text is in the first one the app has, and so is the separator:
    /// [ja-JP, en-US] shows English, not Italian.
    func testTheSeparatorFollowsTheFirstDeviceLanguageTheAppHas() {
        XCTAssertEqual(AppLanguageManager.languageCode(override: nil, preferredLanguages: ["ja-JP", "en-US"]), "en")
        XCTAssertEqual(AppLanguageManager.languageCode(override: nil, preferredLanguages: ["ko", "de-CH", "en-US"]), "de")
        XCTAssertEqual(AppLanguageManager.languageCode(override: nil, preferredLanguages: ["ja", "ko"]), "it")
        XCTAssertEqual(AppLanguageManager.languageCode(override: "fr", preferredLanguages: ["ja-JP", "en-US"]), "fr")
        XCTAssertEqual(VoiceNumberFormat.decimalSeparator(of: VoiceDisplayLocale.locale(override: nil,
                                                                                         preferredLanguages: ["ja-JP", "en-US"])),
                       ".")
        XCTAssertEqual(VoiceNumberFormat.decimalSeparator(of: VoiceDisplayLocale.locale(override: nil,
                                                                                         preferredLanguages: ["ja-JP", "it-CH"])),
                       ",")
    }

    /// The formatters print the separator of the app language for Swiss and South African devices.
    func testEveryFormatterUsesTheSeparatorOfTheAppLanguageOnASwissDevice() {
        let swissItalian = VoiceDisplayLocale.locale(override: nil, preferredLanguage: "it-CH")
        let swissGerman = VoiceDisplayLocale.locale(override: nil, preferredLanguage: "de-CH")
        let southAfricanEnglish = VoiceDisplayLocale.locale(override: nil, preferredLanguage: "en-ZA")
        XCTAssertEqual(VoiceSpectralDetails.text(formant1Hz: 524, formant2Hz: 1478, syllablesPerSecond: 4.24,
                                                 hnrDecibels: 18.4, rateUnit: "sill/s", locale: swissItalian),
                       "F1 520 · F2 1480 · 4,2 sill/s · HNR 18 dB")
        XCTAssertEqual(VoiceBiometricsFormat.pitchRate(hz: 142, syllablesPerSecond: 4.24, syllableUnit: "Silb./s",
                                                       locale: swissGerman), "142 Hz · 4,2 Silb./s")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitterPercent: 1.2, shimmerPercent: 3.1,
                                                           locale: swissGerman), "1,2% / 3,1%")
        XCTAssertEqual(VoiceBiometricsFormat.jitterShimmer(jitterPercent: 1.2, shimmerPercent: 3.1,
                                                           locale: southAfricanEnglish), "1.2% / 3.1%")
    }

    // MARK: - Needs the app (not part of the model check that runs without Xcode)

    /// The numbers follow the language of the app, not the region of the device: the locale the screens use
    /// is the one of `AppLanguageManager.effectiveLanguageCode`.
    func testTheScreensUseTheLocaleOfTheLanguageOfTheApp() {
        let previous = AppLanguageManager.currentOverride
        defer { AppLanguageManager.currentOverride = previous }
        AppLanguageManager.currentOverride = "en"
        XCTAssertEqual(VoiceNumberFormat.decimalSeparator(of: VoiceDisplayLocale.app), ".")
        AppLanguageManager.currentOverride = "it"
        XCTAssertEqual(VoiceNumberFormat.decimalSeparator(of: VoiceDisplayLocale.app), ",")
        AppLanguageManager.currentOverride = "pt-BR"
        XCTAssertEqual(VoiceNumberFormat.decimalSeparator(of: VoiceDisplayLocale.app), ",")
    }

    /// With no override, the locale of the screens is what the choice gives for the real language settings of the
    /// device the tests run on (the system's localization of the app, then every preferred language), whichever
    /// they are.
    func testTheScreensAgreeWithTheChoiceForTheRealLanguageOfTheDevice() {
        let previous = AppLanguageManager.currentOverride
        defer { AppLanguageManager.currentOverride = previous }
        AppLanguageManager.currentOverride = nil
        let languages = Bundle.main.preferredLocalizations + Locale.preferredLanguages
        let expected = VoiceDisplayLocale.locale(override: nil, preferredLanguages: languages)
        XCTAssertEqual(VoiceDisplayLocale.app.identifier, expected.identifier)
        XCTAssertEqual(AppLanguageManager.effectiveLanguageCode,
                       AppLanguageManager.languageCode(override: nil, preferredLanguages: languages))
    }
}
