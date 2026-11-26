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
        "contact_detail.voice_rec.partly", "contact_detail.voice_rec.sessions", "contact_detail.voice_rec.days", "contact_detail.voice_rec.learned", "contact_detail.voice_rec.learned_nodate",
        "contact_detail.voice_rec.changed", "contact_detail.voice_rec.forget", "contact_detail.voice_rec.relearn",
        "settings.contact_voice.section", "settings.contact_voice.title", "settings.contact_voice.subtitle",
        "settings.contact_voice.unavailable", "settings.contact_voice.list_title", "settings.contact_voice.list_empty",
        "settings.contact_voice.delete_all", "settings.contact_voice.confirm_title", "settings.contact_voice.confirm_body",
        "settings.contact_voice.confirm", "settings.contact_voice.cancel", "settings.contact_voice.failed",
    ]

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

    // MARK: where the check starts

    /// The functions of the app state that start the check of a call (and its announcement): an answered call must be one of them,
    /// not only the function that a placed call reaches.
    func testAnAnsweredCallStartsTheCheckToo() throws {
        var dir = URL(fileURLWithPath: "\(#filePath)")
        var found: URL?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/AppState.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
        }
        let lines = try String(contentsOf: XCTUnwrap(found), encoding: .utf8).components(separatedBy: "\n")
        var enclosing = ""
        var starters: Set<String> = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            if let r = line.range(of: "func ") {
                enclosing = String(line[r.upperBound...].prefix { $0 != "(" && $0 != "<" && $0 != " " })
                continue
            }
            if line.contains("startVoiceCheckForThisCall()") { starters.insert(enclosing) }
        }
        XCTAssertFalse(starters.isEmpty)
        XCTAssertTrue(starters.contains { $0 != "finalizeCallActive" }, "started only from \(starters.sorted())")
    }

    private func appStateText() throws -> String {
        var dir = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/AppState.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
        }
        throw NSError(domain: "ContactVoiceUiTests", code: 2)
    }

    /// A connection that is built later, or a call peer that is known later, still starts the check of an answered call: the start has
    /// no time limit and is asked again by the events that make the call ready.
    func testTheStartOfAnAnsweredCallIsEventDrivenWithNoTimeLimit() throws {
        let text = try appStateText()
        let start = try XCTUnwrap(text.range(of: "private func startVoiceCheckAtAnswer() {"))
        let body = String(text[start.lowerBound...].prefix(500))
        XCTAssertFalse(body.contains("Task.sleep"), "no retry loop")
        XCTAssertFalse(body.contains("attempt"), "no attempt limit")
        XCTAssertTrue(body.contains("voiceAnswerGate.pending(activeCallId: canonicalActiveCallId(), inCall: isInCall)"))
        let controllerSet = try XCTUnwrap(text.range(of: "var webRtcController: Any? {"))
        XCTAssertTrue(String(text[controllerSet.lowerBound...].prefix(900)).contains("startVoiceCheckAtAnswer()"))
        XCTAssertTrue(String(text[controllerSet.lowerBound...].prefix(900)).contains("voiceConnectionReady"))
        let peerSet = try XCTUnwrap(text.range(of: "@Published var callContactId: String? {"))
        XCTAssertTrue(String(text[peerSet.lowerBound...].prefix(300)).contains("startVoiceCheckAtAnswer()"))
        XCTAssertTrue(text.contains("voiceAnswerGate.arm(callId: self.canonicalActiveCallId())"))
        XCTAssertTrue(text.contains("voiceAnswerGate.disarm()"))
    }
}
