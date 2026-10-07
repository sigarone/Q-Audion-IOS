import XCTest
@testable import QAudionApp

/// W-CONFNEUTRAL (2026-10-07) — no confidence reading is painted neutral, never red or amber.
///
/// Since #208 the in-call "C=" value (`AppState.confidenceScore`) is -1 until Tier 2's first reading (10-16 s
/// into a call, or the whole call if it never reads). `ConfidenceThresholds.category(of:)` clamps first, so the
/// avatar halo (which used it) turned -1 into 0 and painted RED. Views now go through `tone(of:)`, which maps a
/// negative or non-finite value to `.noReading`. On the previous main `tone(of:)` did not exist and the halo's
/// mapping was `category(of: -1) == 2` (high risk), pinned below as the reason the views must not use it.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class ConfidenceToneTests: XCTestCase {

    func testNoReadingIsNeitherGreenNorAmberNorRed() {
        XCTAssertEqual(ConfidenceThresholds.tone(of: -1), .noReading)
        XCTAssertEqual(ConfidenceThresholds.tone(of: -0.0001), .noReading)
        XCTAssertEqual(ConfidenceThresholds.tone(of: .nan), .noReading)
        XCTAssertEqual(ConfidenceThresholds.tone(of: -.infinity), .noReading)
        XCTAssertEqual(ConfidenceThresholds.tone(of: .infinity), .noReading)
    }

    /// The clamping band function maps the sentinel to high risk: the defect when a view used it directly.
    func testCategoryClampsTheSentinelToHighRiskWhichIsWhyViewsUseTone() {
        XCTAssertEqual(ConfidenceThresholds.category(of: -1), 2)
    }

    /// Real readings keep the existing bands (verified >= 0.70, caution >= 0.25, high risk below), edges
    /// included; 0 is a real reading (high risk), only a negative value is "no reading".
    func testRealReadingsKeepTheirBands() {
        XCTAssertEqual(ConfidenceThresholds.tone(of: 1.0), .verified)
        XCTAssertEqual(ConfidenceThresholds.tone(of: 0.70), .verified)
        XCTAssertEqual(ConfidenceThresholds.tone(of: 0.6999), .caution)
        XCTAssertEqual(ConfidenceThresholds.tone(of: 0.25), .caution)
        XCTAssertEqual(ConfidenceThresholds.tone(of: 0.2499), .highRisk)
        XCTAssertEqual(ConfidenceThresholds.tone(of: 0.0), .highRisk)
        XCTAssertEqual(ConfidenceThresholds.tone(of: 1.5), .verified)
    }

    /// "Autenticità": `VoiceAnalysisResult.confidence` is 0 only when no frame of the averaged second was voiced
    /// (a voiced frame scores >= 0.5), so 0 is no reading; any positive value is a reading.
    func testAuthenticityZeroIsNoReading() {
        XCTAssertEqual(ConfidenceThresholds.tone(of: InCallScreen.authenticityReading(0)), .noReading)
        XCTAssertEqual(ConfidenceThresholds.tone(of: InCallScreen.authenticityReading(.nan)), .noReading)
        XCTAssertEqual(InCallScreen.authenticityReading(0.85), Double(Float(0.85)))
        XCTAssertEqual(ConfidenceThresholds.tone(of: InCallScreen.authenticityReading(0.85)), .verified)
        XCTAssertEqual(ConfidenceThresholds.tone(of: InCallScreen.authenticityReading(0.5)), .caution)
    }
}
