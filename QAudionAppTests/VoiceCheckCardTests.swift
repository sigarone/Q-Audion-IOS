import XCTest
@testable import QAudionApp
import QAudionEngine

/// The card of the contact-voice check: one state of the engine, one line (and, for two states, one popup text), tones without
/// red, and a catalog that has every string in the six languages of the app in the register of that language.
final class VoiceCheckCardTests: XCTestCase {
    private let all: [VoiceCheckDisplay] = [
        .matches, .checking, .checkingDifferentSetup, .differs, .differsNewDevice, .off, .cannotVerify, .learning, .changed
    ]
    private let keys = [
        "in_call.voice_check.matches", "in_call.voice_check.checking", "in_call.voice_check.checking_setup_detail",
        "in_call.voice_check.differs", "in_call.voice_check.differs_new_device", "in_call.voice_check.differs_detail",
        "in_call.voice_check.off", "in_call.voice_check.cannot_verify", "in_call.voice_check.learning", "in_call.voice_check.changed"
    ]
    private let languages = ["it", "en", "de", "es", "fr", "pt-BR"]

    private func catalog() throws -> [String: Any] {
        var dir = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/Localizable.xcstrings")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                return try XCTUnwrap(root["strings"] as? [String: Any])
            }
        }
        throw NSError(domain: "VoiceCheckCardTests", code: 1)
    }

    private func value(_ key: String, _ language: String, in strings: [String: Any]) throws -> String {
        let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
        let unit = try XCTUnwrap((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any], "\(key) \(language)")
        return try XCTUnwrap(unit["value"] as? String, "\(key) \(language)")
    }

    func testEveryStringIsInTheCatalogInEveryLanguage() throws {
        let strings = try catalog()
        for key in keys {
            for language in languages {
                XCTAssertFalse(try value(key, language, in: strings).isEmpty, "\(key) \(language)")
            }
        }
    }

    func testTheNameIsAPlaceholderInTheTwoLinesThatSpeakOfTheContact() throws {
        let strings = try catalog()
        for language in languages {
            XCTAssertTrue(try value("in_call.voice_check.differs_new_device", language, in: strings).contains("%@"), language)
            XCTAssertTrue(try value("in_call.voice_check.differs_detail", language, in: strings).contains("%1$@"), language)
        }
    }

    func testNoWordingAccusesAnyone() throws {
        let strings = try catalog()
        let forbidden = ["impostor", "impostore", "fake", "deepfake", "fraud", "frode", "betrug", "f\u{00E4}lsch", "fraude", "fraude ",
                         "falso", "falsch", "faux", "usurp", "spoof", "clone"]
        for key in keys {
            for language in languages {
                let text = try value(key, language, in: strings).lowercased()
                for word in forbidden {
                    XCTAssertFalse(text.contains(word), "\(key) \(language) says \(word)")
                }
            }
        }
    }

    func testTheRegisterOfEachLanguageIsKept() throws {
        let strings = try catalog()
        let germanDetail = try value("in_call.voice_check.differs_detail", "de", in: strings)
        XCTAssertTrue(germanDetail.contains("Fragen Sie"), "German uses Sie")
        XCTAssertTrue(germanDetail.contains("rufen Sie"), "German uses Sie")
        let frenchDetail = try value("in_call.voice_check.differs_detail", "fr", in: strings)
        XCTAssertTrue(frenchDetail.contains("demande") && frenchDetail.contains("rappelle"), "French uses tu")
        XCTAssertFalse(frenchDetail.lowercased().contains("vous"), "French uses tu")
        for key in keys {
            XCTAssertFalse(try value(key, "fr", in: strings).lowercased().contains("vous "), key)
            XCTAssertFalse(try value(key, "de", in: strings).contains(" du "), key)
        }
    }

    func testEveryStateHasALineAndOnlyTheTwoStatesWithAnExplanationHaveAPopup() {
        for display in all {
            XCTAssertFalse(VoiceCheckCopy.line(for: display, name: "Ada").isEmpty, "\(display)")
        }
        XCTAssertNotNil(VoiceCheckCopy.detail(for: .checkingDifferentSetup, name: "Ada"))
        XCTAssertNotNil(VoiceCheckCopy.detail(for: .differs, name: "Ada"))
        XCTAssertNotNil(VoiceCheckCopy.detail(for: .differsNewDevice, name: "Ada"))
        for display in [VoiceCheckDisplay.matches, .checking, .off, .cannotVerify, .learning, .changed] {
            XCTAssertNil(VoiceCheckCopy.detail(for: display, name: "Ada"), "\(display)")
        }
    }

    func testTheNameIsPutIntoTheLineAndThePopup() {
        XCTAssertTrue(VoiceCheckCopy.line(for: .differsNewDevice, name: "Ada").contains("Ada"))
        XCTAssertTrue(VoiceCheckCopy.detail(for: .differs, name: "Ada")?.contains("Ada") == true)
        XCTAssertFalse(VoiceCheckCopy.line(for: .differsNewDevice, name: "Ada").contains("%@"))
    }

    func testTheCardIsNeverRedAndOnlyTheStatesThatSpeakOfADifferenceAreAmber() {
        for display in all {
            XCTAssertNotEqual(VoiceCheckCopy.tone(for: display), .riskHigh, "\(display)")
        }
        XCTAssertEqual(VoiceCheckCopy.tone(for: .matches), .success)
        XCTAssertEqual(VoiceCheckCopy.tone(for: .differs), .warning)
        XCTAssertEqual(VoiceCheckCopy.tone(for: .differsNewDevice), .warning)
        XCTAssertEqual(VoiceCheckCopy.tone(for: .changed), .warning)
        XCTAssertEqual(VoiceCheckCopy.tone(for: .checking), .neutral)
        XCTAssertEqual(VoiceCheckCopy.tone(for: .cannotVerify), .neutral)
    }

    func testNothingIsShownUntilTheEngineSetsAState() {
        let model = VoiceCheckModel()
        XCTAssertNil(model.display)
        model.set(.checking)
        XCTAssertEqual(model.display, .checking)
        model.set(nil)
        XCTAssertNil(model.display)
    }
}
