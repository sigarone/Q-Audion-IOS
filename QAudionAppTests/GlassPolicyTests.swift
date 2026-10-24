import XCTest
@testable import QAudionApp

/// When a floating control is drawn as Liquid Glass and when it keeps its solid fill. Glass needs a system that has it and
/// a user who has not asked for less transparency or more contrast; in every other case the control is solid, so it never
/// depends on what is behind it to be legible.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class GlassPolicyTests: XCTestCase {

    func testGlassNeedsASystemWithGlassAndNoAccessibilityRequest() {
        XCTAssertEqual(
            QAudionGlassStyle.resolve(osSupportsGlass: true, reduceTransparency: false, increaseContrast: false),
            .glass)
    }

    func testAnOlderSystemKeepsTheSolidFill() {
        XCTAssertEqual(
            QAudionGlassStyle.resolve(osSupportsGlass: false, reduceTransparency: false, increaseContrast: false),
            .solid)
    }

    func testReduceTransparencyKeepsTheSolidFill() {
        XCTAssertEqual(
            QAudionGlassStyle.resolve(osSupportsGlass: true, reduceTransparency: true, increaseContrast: false),
            .solid)
    }

    func testIncreaseContrastKeepsTheSolidFill() {
        XCTAssertEqual(
            QAudionGlassStyle.resolve(osSupportsGlass: true, reduceTransparency: false, increaseContrast: true),
            .solid)
    }

    func testEveryCombinationWithoutGlassSupportIsSolid() {
        for reduce in [false, true] {
            for contrast in [false, true] {
                XCTAssertEqual(
                    QAudionGlassStyle.resolve(
                        osSupportsGlass: false, reduceTransparency: reduce, increaseContrast: contrast),
                    .solid)
            }
        }
    }

    func testTheRunningSystemAnswersConsistentlyWithItsVersion() {
        if #available(iOS 26.0, *) {
            XCTAssertTrue(QAudionGlassStyle.osSupportsGlass)
        } else {
            XCTAssertFalse(QAudionGlassStyle.osSupportsGlass)
        }
    }
}
