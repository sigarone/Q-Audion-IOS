import XCTest
import SwiftUI
import UIKit
@testable import QAudionApp

/// Design system and the accessibility settings of the user:
///  - the text follows the text size chosen in Settings (Dynamic Type), up to one declared cap, and does not change
///    at the default size;
///  - the risk pill labels are translated;
///  - floating surfaces drop the translucent material for an opaque color when "Reduce Transparency" is on.
///
/// The cases are pure (no view is rendered); the last ones read the sources by path, like the other wiring tests, to
/// pin that the views really go through these pieces. Wired into CI: on the include list of
/// `QAudionApp/project-apptests.yml` and in the `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class DesignSystemAccessibilityTests: XCTestCase {

    // MARK: - Roles: default metrics and text style family

    private struct RoleSpec {
        let name: String
        let size: CGFloat
        let weight: Font.Weight
        let lineHeight: CGFloat
        let tracking: CGFloat
        let family: QAudionTypography.Family
    }

    /// The table at the default text size. Pinned in full: scaling must not change a single value of it.
    private let expectedRoles: [RoleSpec] = [
        RoleSpec(name: "displayLarge", size: 57, weight: .regular, lineHeight: 64, tracking: -0.25, family: .display),
        RoleSpec(name: "displayMedium", size: 45, weight: .regular, lineHeight: 52, tracking: 0.0, family: .display),
        RoleSpec(name: "displaySmall", size: 36, weight: .regular, lineHeight: 44, tracking: 0.0, family: .display),
        RoleSpec(name: "headlineLarge", size: 32, weight: .bold, lineHeight: 40, tracking: 0.0, family: .headline),
        RoleSpec(name: "headlineMedium", size: 28, weight: .bold, lineHeight: 36, tracking: 0.0, family: .headline),
        RoleSpec(name: "headlineSmall", size: 24, weight: .medium, lineHeight: 32, tracking: 0.0, family: .headline),
        RoleSpec(name: "titleLarge", size: 22, weight: .medium, lineHeight: 28, tracking: 0.0, family: .title),
        RoleSpec(name: "titleMedium", size: 16, weight: .medium, lineHeight: 24, tracking: 0.15, family: .title),
        RoleSpec(name: "titleSmall", size: 14, weight: .medium, lineHeight: 20, tracking: 0.10, family: .title),
        RoleSpec(name: "bodyLarge", size: 16, weight: .regular, lineHeight: 24, tracking: 0.50, family: .body),
        RoleSpec(name: "bodyMedium", size: 14, weight: .regular, lineHeight: 20, tracking: 0.25, family: .body),
        RoleSpec(name: "bodySmall", size: 12, weight: .regular, lineHeight: 16, tracking: 0.40, family: .body),
        RoleSpec(name: "labelLarge", size: 14, weight: .medium, lineHeight: 20, tracking: 0.10, family: .label),
        RoleSpec(name: "labelMedium", size: 12, weight: .medium, lineHeight: 16, tracking: 0.50, family: .label),
        RoleSpec(name: "labelSmall", size: 11, weight: .medium, lineHeight: 16, tracking: 0.50, family: .label)
    ]

    func testEveryRoleKeepsItsDefaultMetricsAndItsTextStyleFamily() {
        let actual = QAudionTypography.standard.roles
        XCTAssertEqual(actual.map { $0.name }, expectedRoles.map { $0.name })
        for (spec, role) in zip(expectedRoles, actual) {
            XCTAssertEqual(role.style.size, spec.size, spec.name)
            XCTAssertEqual(role.style.weight, spec.weight, spec.name)
            XCTAssertEqual(role.style.lineHeight, spec.lineHeight, spec.name)
            XCTAssertEqual(role.style.tracking, spec.tracking, spec.name)
            XCTAssertEqual(role.style.family, spec.family, spec.name)
        }
    }

    /// display -> largeTitle, headline -> title, title -> headline, body -> body, label -> caption.
    func testTheFamiliesFollowTheSystemTextStylesOfTheirKind() {
        XCTAssertEqual(QAudionTypography.Family.display.textStyle, UIFont.TextStyle.largeTitle)
        XCTAssertEqual(QAudionTypography.Family.headline.textStyle, UIFont.TextStyle.title1)
        XCTAssertEqual(QAudionTypography.Family.title.textStyle, UIFont.TextStyle.headline)
        XCTAssertEqual(QAudionTypography.Family.body.textStyle, UIFont.TextStyle.body)
        XCTAssertEqual(QAudionTypography.Family.label.textStyle, UIFont.TextStyle.caption1)
    }

    /// The cap is declared once, here and in `QAudionTypography.maxDynamicTypeSize` only.
    func testTheCapIsAccessibility3() {
        XCTAssertEqual(QAudionTypography.maxDynamicTypeSize, DynamicTypeSize.accessibility3)
    }

    // MARK: - Scaling

    /// At the default size ("Large") nothing changes: the factor is exactly 1 and the whole table is the same value.
    func testTheDefaultSizeLeavesEveryRoleExactlyAsItIs() {
        for family in QAudionTypography.Family.allCases {
            XCTAssertEqual(QAudionTypography.scaleFactor(for: family, at: .large), 1, "\(family)")
        }
        XCTAssertEqual(QAudionTypography.standard.scaled(for: .large), QAudionTypography.standard)
        XCTAssertEqual(QAudionTypography.scaledSize(11, family: .label, at: .large), 11)
    }

    /// Smaller text size -> smaller text; a larger one never makes it smaller; the biggest accessibility sizes up to
    /// the cap make it clearly bigger.
    func testTextFollowsTheSizeTheUserPicks() {
        let sizes = DynamicTypeSize.allCases.sorted()
        for family in QAudionTypography.Family.allCases {
            XCTAssertLessThan(QAudionTypography.scaleFactor(for: family, at: .xSmall), 1, "\(family)")
            XCTAssertGreaterThan(QAudionTypography.scaleFactor(for: family, at: .accessibility3), 1, "\(family)")
            var previous: CGFloat = 0
            for size in sizes {
                let factor = QAudionTypography.scaleFactor(for: family, at: size)
                XCTAssertGreaterThanOrEqual(factor, previous, "\(family) at \(size)")
                previous = factor
            }
        }
    }

    /// Above the cap text stops growing.
    func testSizesAboveTheCapAreTheCap() {
        let cap = QAudionTypography.maxDynamicTypeSize
        for family in QAudionTypography.Family.allCases {
            let atCap = QAudionTypography.scaleFactor(for: family, at: cap)
            XCTAssertLessThanOrEqual(QAudionTypography.scaleFactor(for: family, at: .accessibility2), atCap, "\(family)")
            XCTAssertEqual(QAudionTypography.scaleFactor(for: family, at: .accessibility4), atCap, "\(family)")
            XCTAssertEqual(QAudionTypography.scaleFactor(for: family, at: .accessibility5), atCap, "\(family)")
        }
        // Body text is still growing right below the cap: the cap is where it stops, not an earlier plateau.
        XCTAssertLessThan(QAudionTypography.scaleFactor(for: .body, at: .accessibility2),
                          QAudionTypography.scaleFactor(for: .body, at: cap))
        XCTAssertEqual(QAudionTypography.standard.scaled(for: .accessibility5),
                       QAudionTypography.standard.scaled(for: cap))
    }

    /// A scaled role keeps its proportions: size, line height and tracking grow by the same factor, the weight and the
    /// family stay.
    func testAScaledRoleKeepsItsProportions() {
        let base = QAudionTypography.standard.labelLarge
        let factor = QAudionTypography.scaleFactor(for: base.family, at: .xxxLarge)
        XCTAssertGreaterThan(factor, 1)
        let scaled = base.scaled(for: .xxxLarge)
        XCTAssertEqual(scaled.size, base.size * factor, accuracy: 0.0001)
        XCTAssertEqual(scaled.lineHeight, base.lineHeight * factor, accuracy: 0.0001)
        XCTAssertEqual(scaled.tracking, base.tracking * factor, accuracy: 0.0001)
        XCTAssertEqual(scaled.lineSpacing, base.lineSpacing * factor, accuracy: 0.0001)
        XCTAssertEqual(scaled.weight, base.weight)
        XCTAssertEqual(scaled.family, base.family)
    }

    /// The helper for fixed point sizes (icons, cells of digits) uses the same curve as the roles.
    func testFixedPointSizesUseTheSameCurveAsTheRoles() {
        let factor = QAudionTypography.scaleFactor(for: .body, at: .accessibility1)
        XCTAssertEqual(QAudionTypography.scaledSize(16, family: .body, at: .accessibility1), 16 * factor, accuracy: 0.0001)
        XCTAssertEqual(QAudionTypography.scaledSize(16, family: .body, at: .accessibility5),
                       QAudionTypography.scaledSize(16, family: .body, at: QAudionTypography.maxDynamicTypeSize))
    }

    // MARK: - Risk pill labels

    private let riskKeys = ["risk_pill.low", "risk_pill.medium", "risk_pill.high"]
    private let appLanguages = ["it", "en", "es", "fr", "de", "pt-BR"]

    private func catalogValue(_ strings: [String: Any], _ key: String, _ language: String) -> String? {
        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let localization = localizations[language] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    private func catalogStrings() throws -> [String: Any] {
        let catalog = try sourceText("QAudionApp/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: Any])
    }

    /// The three labels exist in the six languages, none empty, and in the five languages other than Italian none is
    /// the key or the Italian text.
    func testTheRiskLabelsAreInTheCatalogInAllSixLanguages() throws {
        let strings = try catalogStrings()
        for key in riskKeys {
            let italian = catalogValue(strings, key, "it")
            XCTAssertNotNil(italian, "\(key) it")
            for language in appLanguages {
                let value = catalogValue(strings, key, language)
                XCTAssertNotNil(value, "\(key) is translated into \(language)")
                guard let text = value else { continue }
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) \(language) is empty")
                XCTAssertEqual(text, text.uppercased(), "\(key) \(language) is uppercase like the label it replaces")
                if language != "it" {
                    XCTAssertNotEqual(text, key, "\(key) \(language) is the key")
                    XCTAssertNotEqual(text, italian, "\(key) \(language) is the Italian text")
                }
            }
        }
        for language in appLanguages {
            let texts = riskKeys.compactMap { catalogValue(strings, $0, language) }
            XCTAssertEqual(Set(texts).count, 3, "the three levels read differently in \(language)")
        }
    }

    /// Italian is what the pill showed before the keys existed.
    func testItalianKeepsTheTextOfTheOldPill() throws {
        let strings = try catalogStrings()
        XCTAssertEqual(catalogValue(strings, "risk_pill.low", "it"), "RISCHIO BASSO")
        XCTAssertEqual(catalogValue(strings, "risk_pill.medium", "it"), "RISCHIO MEDIO")
        XCTAssertEqual(catalogValue(strings, "risk_pill.high", "it"), "RISCHIO ALTO")
    }

    /// The pill draws its labels from those keys and has no fixed Italian text left.
    func testTheRiskPillReadsItsLabelsFromTheCatalog() throws {
        let source = try sourceText("QAudionApp/DesignSystem/Components/RiskPill.swift")
        // Comment lines (the header still describes the three levels in words) are not code.
        let pill = source.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
        for key in riskKeys {
            XCTAssertTrue(pill.contains("Text(\"\(key)\")"), "RiskPill does not use \(key)")
        }
        XCTAssertFalse(pill.contains("\"RISCHIO"), "a fixed Italian label is left in RiskPill")
    }

    // MARK: - Reduce Transparency

    func testReduceTransparencyPicksTheOpaqueBackdrop() {
        XCTAssertEqual(QAudionBackdrop.resolve(reduceTransparency: true), .opaque)
        XCTAssertEqual(QAudionBackdrop.resolve(reduceTransparency: false), .material)
    }

    /// The four places that drew `.ultraThinMaterial` go through the modifier, one line each.
    func testTheMaterialBackgroundsGoThroughTheModifier() throws {
        let expectedCalls: [(path: String, calls: Int)] = [
            ("QAudionApp/Views/CallSecurityBadge.swift", 2),
            ("QAudionApp/Views/WaveformView.swift", 1),
            ("QAudionApp/Views/Settings/BackupSettingsScreen.swift", 1)
        ]
        for expected in expectedCalls {
            let text = try sourceText(expected.path)
            XCTAssertFalse(text.contains("ultraThinMaterial"), "\(expected.path) still draws a bare material")
            XCTAssertEqual(text.components(separatedBy: ".qaudionMaterialBackground(").count - 1, expected.calls,
                           expected.path)
        }
    }

    // MARK: - Wiring of the text size

    /// The theme publishes the typography for the size the user picked, and reads that size from the environment.
    func testTheThemePublishesTheTypographyForTheUsersTextSize() throws {
        let theme = try sourceText("QAudionApp/DesignSystem/QAudionTheme.swift")
        XCTAssertTrue(theme.contains("@Environment(\\.dynamicTypeSize)"))
        XCTAssertTrue(theme.contains(".environment(\\.qaudionType, QAudionTypography.standard.scaled(for: dynamicTypeSize))"))
    }

    /// No component of the design system draws a font of fixed size: icons and digits use `qaudionScaledFont`. The
    /// avatar is the exception, its letters are a fraction of the circle whose size the caller fixes.
    func testDesignSystemComponentsHaveNoFixedPointFonts() throws {
        let root = try sourceDirectory("QAudionApp/DesignSystem")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            if name == "QAudionAvatar.swift" || name == "QAudionTypography.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(".font(.system(size:"),
                           "\(name) draws a font of fixed size: use qaudionScaledFont or a typography role")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10, "the design system sources were not found")
    }

    // MARK: - Source lookup

    private struct SourceNotFound: Error {}

    private func sourceDirectory(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("\(relativePath) not found from \(file)")
        throw SourceNotFound()
    }

    private func sourceText(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let url = try sourceDirectory(relativePath, file: file)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
