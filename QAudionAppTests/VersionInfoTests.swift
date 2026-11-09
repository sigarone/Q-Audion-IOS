import XCTest
@testable import QAudionApp

/// The version the interface shows is the bundle's own, formatted in one place,
/// and "What's new" comes from generated data.
final class VersionInfoTests: XCTestCase {

    func testDisplayedVersionEqualsBundleValues() {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        XCTAssertEqual(AppVersionInfo.marketing(), short ?? "?")
        XCTAssertEqual(AppVersionInfo.build(), build ?? "?")
        let suffix = AppVersionInfo.isTestFlight() ? " · TestFlight" : ""
        XCTAssertEqual(AppVersionInfo.display(), "\(short ?? "?") (build \(build ?? "?"))" + suffix)
    }

    func testFormat() {
        XCTAssertEqual(AppVersionInfo.format(version: "1.0.1279", build: "345"), "1.0.1279 (build 345)")
    }

    func testChannelDetectionAndFormatting() {
        let testFlight = URL(fileURLWithPath: "/private/var/mobile/StoreKit/sandboxReceipt")
        let store = URL(fileURLWithPath: "/private/var/mobile/StoreKit/receipt")
        XCTAssertTrue(AppVersionInfo.isTestFlight(receiptURL: testFlight))
        XCTAssertFalse(AppVersionInfo.isTestFlight(receiptURL: store))
        XCTAssertFalse(AppVersionInfo.isTestFlight(receiptURL: nil))
        XCTAssertEqual(AppVersionInfo.format(version: "1.0.1279", build: "345", testFlight: true),
                       "1.0.1279 (build 345) · TestFlight")
        XCTAssertEqual(AppVersionInfo.format(version: "1.0.1279", build: "345", testFlight: false),
                       "1.0.1279 (build 345)")
    }

    func testAboutModelUsesTheBundle() {
        let model = AboutSettingsContainer.running
        XCTAssertEqual(model.appVersion, AppVersionInfo.marketing())
        XCTAssertEqual(model.buildNumber, AppVersionInfo.build())
    }

    func testNoVersionLiteralInUiCode() throws {
        var dir = URL(fileURLWithPath: "\(#filePath)")
        var views: URL?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/Views")
            if FileManager.default.fileExists(atPath: candidate.path) { views = candidate; break }
        }
        let root = try XCTUnwrap(views)
        let literal = try NSRegularExpression(pattern: #""[^"\n]*(?<![\d.])1\.0\.\d+(?![\d.])"#)
        var offending: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if literal.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    offending.append("\(url.lastPathComponent):\(n + 1)")
                }
            }
        }
        XCTAssertTrue(offending.isEmpty, "hardcoded version literal in UI code: \(offending)")
    }

    private static let sample = #"[{"version":"1.0.1279","date":"2026-11-09","notes":{"it":["Uno"],"en":["One"]}},{"version":"1.0.1278","date":"2026-11-08","notes":{"en":["Two","Three"]}}]"#

    func testChangelogParsesAndKeepsOrder() {
        let notes = ChangelogStore.notes(from: Data(Self.sample.utf8), currentVersion: "1.0.1279", languages: ["en"])
        XCTAssertEqual(notes.map(\.id), ["v1.0.1279", "v1.0.1278"])
        XCTAssertEqual(notes[1].bullets, ["Two", "Three"])
    }

    func testLanguageSelectionFallsBackToEnglish() {
        XCTAssertEqual(ChangelogStore.notes(from: Data(Self.sample.utf8), currentVersion: "1.0.1279", languages: ["it"])[0].bullets, ["Uno"])
        XCTAssertEqual(ChangelogStore.notes(from: Data(Self.sample.utf8), currentVersion: "1.0.1279", languages: ["fr"])[0].bullets, ["One"])
        XCTAssertEqual(ChangelogStore.notes(from: Data(Self.sample.utf8), currentVersion: "1.0.1279", languages: ["pt-BR", "en"])[0].bullets, ["One"])
    }

    func testRunningVersionLeadsWhenNewerThanTheData() {
        let notes = ChangelogStore.notes(from: Data(Self.sample.utf8), currentVersion: "1.0.1300", languages: ["en"])
        XCTAssertEqual(notes.first?.id, "v1.0.1300")
        XCTAssertEqual(notes.first?.bullets, ["Quality and reliability improvements"])
        XCTAssertEqual(notes.count, 3)
    }

    func testMissingDataStillShowsTheRunningVersion() {
        let notes = ChangelogStore.notes(from: nil, currentVersion: "1.0.1279", languages: ["en"])
        XCTAssertEqual(notes.map(\.id), ["v1.0.1279"])
        XCTAssertEqual(notes.first?.bullets, ["Quality and reliability improvements"])
    }

    func testGenericLineExistsInEveryLanguage() {
        for code in ["it", "en", "de", "es", "fr", "pt-BR"] {
            XCTAssertFalse(ChangelogStore.generic[code]?.isEmpty ?? true, code)
        }
    }

    func testVersionComparisonIsNumeric() {
        XCTAssertEqual(ChangelogStore.compare("1.0.1279", "1.0.998"), .orderedDescending)
        XCTAssertEqual(ChangelogStore.compare("1.0.5", "1.0.5"), .orderedSame)
    }
}
