import XCTest
@testable import QAudionApp
import QAudionEngine

/// The screens of the contact-voice recognition: the words of the contact row, the actions of the detail of a Differs state, and the
/// catalog (every string in the six languages of the app, no accusing word, the informal form in French).
final class ContactVoiceUiTests: XCTestCase {
    private let languages = ["it", "en", "de", "es", "fr", "pt-BR"]
    private let keys = [
        "in_call.voice_check.was_him", "in_call.voice_check.compare_code",
        "contact_detail.voice_rec.label", "contact_detail.voice_rec.off", "contact_detail.voice_rec.learning",
        "contact_detail.voice_rec.partly", "contact_detail.voice_rec.learned", "contact_detail.voice_rec.learned_nodate",
        "contact_detail.voice_rec.changed", "contact_detail.voice_rec.forget", "contact_detail.voice_rec.relearn",
        "settings.contact_voice.section", "settings.contact_voice.title", "settings.contact_voice.subtitle",
        "settings.contact_voice.unavailable", "settings.contact_voice.list_title", "settings.contact_voice.list_empty",
        "settings.contact_voice.delete_all", "settings.contact_voice.confirm_title", "settings.contact_voice.confirm_body",
        "settings.contact_voice.confirm", "settings.contact_voice.cancel", "settings.contact_voice.failed",
    ]
    private let pluralKeys = ["contact_detail.voice_rec.sessions %lld", "contact_detail.voice_rec.days %lld"]

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
        throw NSError(domain: "ContactVoiceUiTests", code: 1)
    }

    private func localization(_ key: String, _ language: String, in strings: [String: Any]) throws -> [String: Any] {
        let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
        return try XCTUnwrap(localizations[language] as? [String: Any], "\(key) \(language)")
    }

    private func value(_ key: String, _ language: String, in strings: [String: Any]) throws -> String {
        let unit = try XCTUnwrap(try localization(key, language, in: strings)["stringUnit"] as? [String: Any], "\(key) \(language)")
        return try XCTUnwrap(unit["value"] as? String, "\(key) \(language)")
    }

    func testEveryStringIsInTheCatalogInEveryLanguage() throws {
        let strings = try catalog()
        for key in keys {
            for language in languages {
                XCTAssertFalse(try value(key, language, in: strings).isEmpty, "\(key) \(language)")
            }
        }
        for key in pluralKeys {
            for language in languages {
                let variations = try XCTUnwrap(try localization(key, language, in: strings)["variations"] as? [String: Any], "\(key) \(language)")
                let plural = try XCTUnwrap(variations["plural"] as? [String: Any], "\(key) \(language)")
                XCTAssertNotNil(plural["one"], "\(key) \(language)")
                XCTAssertNotNil(plural["other"], "\(key) \(language)")
            }
        }
    }

    func testNoWordingAccusesAnyoneAndFrenchSpeaksInTheInformalForm() throws {
        let strings = try catalog()
        let forbidden = ["impostor", "impostore", "fake", "deepfake", "fraud", "frode", "betrug", "f\u{00E4}lsch", "fraude",
                         "falso", "falsch", "faux", "usurp", "spoof", "clone"]
        for key in keys {
            for language in languages {
                let text = try value(key, language, in: strings).lowercased()
                for word in forbidden {
                    XCTAssertFalse(text.contains(word), "\(key) \(language): \(word)")
                }
                if language == "fr" {
                    XCTAssertFalse(text.contains("vous") || text.contains("votre") || text.contains("vos "), "\(key): \(text)")
                }
            }
        }
    }

    func testThePlaceholdersSurviveInEveryLanguage() throws {
        let strings = try catalog()
        for language in languages {
            XCTAssertTrue(try value("in_call.voice_check.was_him", language, in: strings).contains("%@"), language)
            XCTAssertTrue(try value("contact_detail.voice_rec.learned", language, in: strings).contains("%@"), language)
            let learning = try value("contact_detail.voice_rec.learning", language, in: strings)
            XCTAssertTrue(learning.contains("%1$lld") && learning.contains("%2$lld"), language)
        }
    }

    // MARK: the row

    private func summary(_ kind: ContactVoiceSummary.Kind, enrolledS: Int = 0, sessions: Int = 2) -> ContactVoiceSummary {
        ContactVoiceSummary(kind: kind, speechS: 35, targetS: 120, sessions: sessions, days: 2, enrolledS: enrolledS)
    }

    func testTheRowReadsOffWhenTheOwnerSettingIsOff() {
        for kind in [ContactVoiceSummary.Kind.learning, .partlyLearned, .learned, .mayHaveChanged] {
            XCTAssertEqual(ContactVoiceRowText.kind(summary: summary(kind), ownerOn: false), .off)
        }
        XCTAssertEqual(ContactVoiceRowText.kind(summary: nil, ownerOn: false), .off)
    }

    func testTheRowStatesFollowTheRecord() {
        XCTAssertEqual(ContactVoiceRowText.kind(summary: nil, ownerOn: true), .learning)
        XCTAssertEqual(ContactVoiceRowText.kind(summary: summary(.learning), ownerOn: true), .learning)
        XCTAssertEqual(ContactVoiceRowText.kind(summary: summary(.partlyLearned), ownerOn: true), .partly)
        XCTAssertEqual(ContactVoiceRowText.kind(summary: summary(.learned), ownerOn: true), .learned)
        XCTAssertEqual(ContactVoiceRowText.kind(summary: summary(.mayHaveChanged), ownerOn: true), .changed)
    }

    func testOnlyAVoiceThatMayHaveChangedOffersRelearn() {
        XCTAssertTrue(summary(.mayHaveChanged).canRelearn)
        for kind in [ContactVoiceSummary.Kind.learning, .partlyLearned, .learned] {
            XCTAssertFalse(summary(kind).canRelearn)
        }
    }

    func testTheLearnedDateComesFromTheRecordAndFollowsTheLocale() {
        let utc = TimeZone(identifier: "UTC") ?? .current
        // 2026-10-12 12:00:00 UTC
        let enrolled = 1_791_806_400
        let english = ContactVoiceRowText.learnedDate(enrolledS: enrolled, locale: Locale(identifier: "en_US"), timeZone: utc)
        let italian = ContactVoiceRowText.learnedDate(enrolledS: enrolled, locale: Locale(identifier: "it_IT"), timeZone: utc)
        XCTAssertTrue(english.contains("Oct") && english.contains("12") && english.contains("2026"), english)
        XCTAssertTrue(italian.contains("ott") && italian.contains("12") && italian.contains("2026"), italian)
        let text = ContactVoiceRowText.text(
            summary: summary(.learned, enrolledS: enrolled), ownerOn: true, locale: Locale(identifier: "en_US"))
        XCTAssertFalse(text.isEmpty)
    }

    func testTheLearningTextShowsTheProgress() {
        let text = ContactVoiceRowText.text(summary: summary(.learning), ownerOn: true)
        XCTAssertTrue(text.contains("35") && text.contains("120"), text)
    }

    // MARK: the Differs detail

    func testOnlyTheDifferingStatesOfferTheTwoActions() {
        XCTAssertTrue(VoiceCheckCopy.offersActions(for: .differs))
        XCTAssertTrue(VoiceCheckCopy.offersActions(for: .differsNewDevice))
        for display in [VoiceCheckDisplay.matches, .checking, .checkingDifferentSetup, .off, .cannotVerify, .learning, .changed] {
            XCTAssertFalse(VoiceCheckCopy.offersActions(for: display), "\(display)")
        }
        XCTAssertTrue(VoiceCheckCopy.wasHimTitle(name: "Anna").contains("Anna"))
        XCTAssertFalse(VoiceCheckCopy.compareCodeTitle.isEmpty)
    }
}
