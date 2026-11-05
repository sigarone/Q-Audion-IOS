import XCTest

/// Guards the shape of the string catalog: keys are the text the code looks up (no backslash sequences),
/// every entry has all six languages, and a few keys that used to be dead stay gone.
final class CatalogHygieneTests: XCTestCase {

    private static let languages = ["it", "en", "de", "es", "fr", "pt-BR"]

    private func strings() throws -> [String: Any] {
        var dir = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/Localizable.xcstrings")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                return try XCTUnwrap(root["strings"] as? [String: Any])
            }
        }
        throw NSError(domain: "CatalogHygieneTests", code: 1)
    }

    func testNoKeyContainsABackslash() throws {
        let offending = try strings().keys.filter { $0.contains("\\") }
        XCTAssertTrue(offending.isEmpty, "keys with a backslash never match the text in the code: \(offending)")
    }

    /// A localization is complete when it has a non-empty string unit, or when it is made of variations
    /// (plural, device) and every case of every variation is itself complete.
    private func isComplete(_ localization: [String: Any]) -> Bool {
        if let unit = localization["stringUnit"] as? [String: Any] {
            return !((unit["value"] as? String) ?? "").isEmpty
        }
        guard let variations = localization["variations"] as? [String: Any], !variations.isEmpty else { return false }
        for (_, group) in variations {
            guard let cases = group as? [String: Any], !cases.isEmpty else { return false }
            for (_, entry) in cases {
                guard let nested = entry as? [String: Any], isComplete(nested) else { return false }
            }
        }
        return true
    }

    func testEveryEntryHasAllSixLanguages() throws {
        for (key, entry) in try strings() {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for language in Self.languages {
                let localization = localizations[language] as? [String: Any] ?? [:]
                XCTAssertTrue(isComplete(localization), "\(key) has no \(language) text")
            }
        }
    }

    func testRemovedDeadKeysStayGone() throws {
        let strings = try strings()
        for gone in ["MODO", "TX FRAME CIFRATI", "video.diag.codec_cipher", "nfc.peer_name", "Chiudi banner SAS",
                     "account_notice.password_changed.title"] {
            XCTAssertNil(strings[gone], "\(gone) is unused and should not come back")
        }
    }

    func testMovedStringsAreInTheCatalog() throws {
        let strings = try strings()
        for key in ["Build · device · stato · share"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            let unit = try XCTUnwrap((localizations["it"] as? [String: Any])?["stringUnit"] as? [String: Any], key)
            XCTAssertEqual(unit["value"] as? String, key, "the Italian text is the key itself")
        }
    }
}
