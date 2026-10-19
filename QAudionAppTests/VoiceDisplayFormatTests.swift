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
/// is not a reading is a dash of its own.
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
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [[String]] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
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
            check(c.id, "tone", VoiceGauges.pitch(hz: c.f0, voiced: true).value, e["tone"])
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
            let pitchOnly = VoiceBiometricsFormat.pitch(hz: c.f0)
            let toneValue = e["tone"] ?? ""
            check(c.id, "video pitch", pitchOnly, toneValue == VoiceGauges.noValue ? toneValue : toneValue + " Hz")
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
}
