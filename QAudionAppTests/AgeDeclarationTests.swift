import XCTest
@testable import QAudionApp

/// The age declaration on the registration screens: which gates keep the submit button off (and that each screen's
/// own property calls its gate with the ticked state, and that the buttons are disabled by it), what the phone screen
/// hands to the OTP step, the pages the box
/// links to, which screens show the box and send the declaration, and the
/// texts of the box in the string catalog. The body of the requests is covered by `BCryptoAuthWireFormatTests` in
/// the engine tests.
final class AgeDeclarationTests: XCTestCase {

    private let validInvite = "QA1-7K3M9-PXTVY-R2HN5-ZZ"

    // MARK: - Gates

    func testPhoneRegisterNeedsTheBoxTicked() {
        XCTAssertFalse(PhoneEntryScreen.ageOk(mode: .register, ageDeclared: false))
        XCTAssertTrue(PhoneEntryScreen.ageOk(mode: .register, ageDeclared: true))
    }

    func testPhoneLoginNeedsNoBox() {
        XCTAssertTrue(PhoneEntryScreen.ageOk(mode: .login, ageDeclared: false))
    }

    func testPhoneScreenHandsTheOtpStepWhatWasTickedForRegisterAndNothingForLogin() {
        XCTAssertTrue(PhoneEntryScreen.ageWireValue(mode: .register, ageDeclared: true))
        XCTAssertFalse(PhoneEntryScreen.ageWireValue(mode: .register, ageDeclared: false))
        XCTAssertFalse(PhoneEntryScreen.ageWireValue(mode: .login, ageDeclared: true))
    }

    /// The interno + email form needs the three conditions together: a wrong one keeps the button off even when the
    /// box is ticked, and an unticked box keeps it off even when the rest is right.
    func testExtensionFormNeedsEmailInviteAndBox() {
        XCTAssertTrue(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: true, inviteCode: validInvite, ageDeclared: true))
        XCTAssertFalse(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: true, inviteCode: validInvite, ageDeclared: false))
        XCTAssertFalse(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: false, inviteCode: validInvite, ageDeclared: true))
        XCTAssertFalse(ExtensionOnlyRegisterScreen.isSubmittable(emailValid: true, inviteCode: "QA1-7K3M9", ageDeclared: true))
    }

    /// The whole gate of the phone screen's button, not only the age part: for a registration the box is one of three
    /// conditions, and each of them alone keeps the button off.
    func testPhoneRegisterButtonNeedsNumberInviteAndBox() {
        XCTAssertTrue(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .register, inviteCode: validInvite, ageDeclared: true))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .register, inviteCode: validInvite, ageDeclared: false))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: false, mode: .register, inviteCode: validInvite, ageDeclared: true))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .register, inviteCode: "QA1-7K3M9", ageDeclared: true))
    }

    /// A login shows no box and no invite field: a valid number is all it takes, ticked or not.
    func testPhoneLoginButtonNeedsOnlyTheNumber() {
        XCTAssertTrue(PhoneEntryScreen.isSubmittable(phoneValid: true, mode: .login, inviteCode: "", ageDeclared: false))
        XCTAssertFalse(PhoneEntryScreen.isSubmittable(phoneValid: false, mode: .login, inviteCode: "", ageDeclared: true))
    }

    // MARK: - Links

    func testTermsAndPrivacyPagesForItalianUseTheItalianRoute() {
        XCTAssertEqual(LegalLinks.appTerms(languageCode: "it").absoluteString, "https://bcrypto.com/it/legal/qaudion-terms")
        XCTAssertEqual(LegalLinks.appPrivacy(languageCode: "it").absoluteString, "https://bcrypto.com/it/legal/qaudion-privacy")
    }

    func testTermsAndPrivacyPagesForEveryOtherLanguageHaveNoPrefix() {
        for language in ["en", "de", "es", "fr", "pt-BR"] {
            XCTAssertEqual(LegalLinks.appTerms(languageCode: language).absoluteString,
                           "https://bcrypto.com/legal/qaudion-terms", language)
            XCTAssertEqual(LegalLinks.appPrivacy(languageCode: language).absoluteString,
                           "https://bcrypto.com/legal/qaudion-privacy", language)
        }
    }

    // MARK: - Screens

    /// The box is on both registration screens, and each sends what was ticked: the phone screen to the OTP step,
    /// which hands it to the server with the code; the interno + email screen straight to the server. Dropping the box
    /// from a screen, or the argument from a call, would let the flag on the server block people.
    func testEveryRegistrationScreenShowsTheBoxAndSendsTheDeclaration() throws {
        let box = "AgeDeclarationSection(declared: $ageDeclared)"

        let phone = try sourceText("QAudionApp/Views/Onboarding/PhoneEntryScreen.swift")
        XCTAssertTrue(phone.contains(box), "PhoneEntryScreen does not show the box")
        assertMatches(phone, #"onContinue\([^)]*Self\.ageWireValue\(mode: mode, ageDeclared: ageDeclared\)"#,
                      "PhoneEntryScreen does not hand the declaration to the next step")

        let root = try sourceText("QAudionApp/Views/Onboarding/OnboardingRoot.swift")
        assertMatches(root, #"route = \.otpVerification\([^)]*ageDeclared: ageDeclared"#,
                      "OnboardingRoot does not carry the declaration to the OTP step")
        assertMatches(root, #"OtpVerificationScreen\([^)]*ageDeclared: ageDeclared"#,
                      "OnboardingRoot does not pass the declaration to OtpVerificationScreen")

        let otp = try sourceText("QAudionApp/Views/Onboarding/OtpVerificationScreen.swift")
        assertMatches(otp, #"verifyOtp\([^)]*ageDeclared: ageDeclared"#,
                      "OtpVerificationScreen does not send the declaration")

        let interno = try sourceText("QAudionApp/Views/Onboarding/ExtensionOnlyRegisterScreen.swift")
        XCTAssertTrue(interno.contains(box), "ExtensionOnlyRegisterScreen does not show the box")
        assertMatches(interno, #"registerExtensionOnly\([^)]*ageDeclared: ageDeclared"#,
                      "ExtensionOnlyRegisterScreen does not send the declaration")
    }

    /// The gates above are static functions; what keeps the button off in the app is the view's own property calling
    /// them with what the screen holds. Taking `ageDeclared: ageDeclared` (or the mode) out of that call, or putting a
    /// constant in its place, would enable the button with the box unticked while every test of the functions passes.
    func testTheButtonGatesAreCalledWithTheTickedStateAndTheModeOfTheScreen() throws {
        let phone = try sourceText("QAudionApp/Views/Onboarding/PhoneEntryScreen.swift")
        let phoneGate = try bodyOf("private var isValid: Bool {", in: phone)
        XCTAssertTrue(phoneGate.contains("Self.isSubmittable("), "PhoneEntryScreen.isValid does not go through the gate")
        XCTAssertTrue(phoneGate.contains("mode: mode"), "PhoneEntryScreen.isValid does not pass the mode")
        XCTAssertTrue(phoneGate.contains("inviteCode: inviteCode"), "PhoneEntryScreen.isValid does not pass the invite code")
        XCTAssertTrue(phoneGate.contains("ageDeclared: ageDeclared"), "PhoneEntryScreen.isValid does not pass the box")

        let interno = try sourceText("QAudionApp/Views/Onboarding/ExtensionOnlyRegisterScreen.swift")
        let internoGate = try bodyOf("private var canSubmit: Bool {", in: interno)
        XCTAssertTrue(internoGate.contains("Self.isSubmittable("), "ExtensionOnlyRegisterScreen.canSubmit does not go through the gate")
        XCTAssertTrue(internoGate.contains("inviteCode: inviteCode"), "ExtensionOnlyRegisterScreen.canSubmit does not pass the invite code")
        XCTAssertTrue(internoGate.contains("ageDeclared: ageDeclared"), "ExtensionOnlyRegisterScreen.canSubmit does not pass the box")
    }

    /// The gates are only worth something if the button is really off when they say no. The `.disabled(...)` modifier
    /// of each registration button is what turns the tap off, and the phone screen's `submit()` checks the same gate
    /// as its first statement, so a tap that gets through anyway still starts nothing. Removing the modifier, moving
    /// it above the button it belongs to, or taking the first statement out of `submit()` leaves every test of the
    /// static gates green, so these lines are pinned here.
    func testTheRegistrationButtonsAreDisabledByTheGateAndSubmitChecksItAgain() throws {
        let phone = codeLines(try sourceText("QAudionApp/Views/Onboarding/PhoneEntryScreen.swift"))
        let phoneAction = try XCTUnwrap(phone.firstIndex(of: "submit()"), "the button of PhoneEntryScreen does not call submit()")
        let phoneDisabled = try XCTUnwrap(phone.firstIndex(of: ".disabled(!isValid)"),
                                          "the button of PhoneEntryScreen is not disabled by isValid")
        XCTAssertGreaterThan(phoneDisabled, phoneAction, "the disabled modifier of PhoneEntryScreen is above its button")

        let phoneSubmit = try XCTUnwrap(phone.firstIndex(of: "private func submit() {"), "PhoneEntryScreen.submit() not found")
        XCTAssertEqual(phone.dropFirst(phoneSubmit + 1).first, "guard isValid else { return }",
                       "PhoneEntryScreen.submit() does not check the gate first")

        let interno = codeLines(try sourceText("QAudionApp/Views/Onboarding/ExtensionOnlyRegisterScreen.swift"))
        let internoAction = try XCTUnwrap(interno.firstIndex(of: "Task { await submit() }"),
                                          "the button of ExtensionOnlyRegisterScreen does not call submit()")
        let internoDisabled = try XCTUnwrap(interno.firstIndex(of: ".disabled(!canSubmit || isSubmitting)"),
                                            "the button of ExtensionOnlyRegisterScreen is not disabled by canSubmit")
        XCTAssertGreaterThan(internoDisabled, internoAction, "the disabled modifier of ExtensionOnlyRegisterScreen is above its button")
    }

    /// The engine's own view-model hands on the declaration it receives, for the phone registration and for the
    /// sovereign one, and holds no constant of its own: a hard-coded `false` there would drop the declaration
    /// whatever the caller passes, and nothing else would notice.
    func testTheEngineViewModelHandsOnTheDeclarationItReceives() throws {
        let source = try sourceText("QAudionEngine/Sources/QAudionEngine/UI/QAudionAppState.swift")
        let code = codeLines(source).joined(separator: "\n")
        assertMatches(code, #"func register\([^)]*ageDeclared: Bool = false\)"#,
                      "QAudionAppState.register does not take the declaration")
        assertMatches(code, #"accountApi\.register\([\s\S]{0,300}?ageDeclared: ageDeclared"#,
                      "QAudionAppState.register does not hand the declaration to the server")
        assertMatches(code, #"func registerSovereign\([^)]*ageDeclared: Bool = false\)"#,
                      "QAudionAppState.registerSovereign does not take the declaration")
        assertMatches(code, #"registerWithServer\([\s\S]{0,200}?ageDeclared: ageDeclared"#,
                      "QAudionAppState.registerSovereign does not hand the declaration to the server")
        XCTAssertFalse(code.contains("ageDeclared: false"), "QAudionAppState holds a constant declaration")
        XCTAssertFalse(code.contains("ageDeclared: true"), "QAudionAppState holds a constant declaration")
    }

    /// The lines of code of `source`, trimmed, with blank lines and comment lines left out.
    private func codeLines(_ source: String) -> [String] {
        source.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
    }

    /// The code between the opening brace of `header` and the first closing brace after it, comment lines left out.
    /// The properties looked at hold a single expression, so that brace is the end of the property.
    private func bodyOf(_ header: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: header), "\(header) not found")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.firstIndex(of: "}"), "the end of \(header) not found")
        return rest[..<end]
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func assertMatches(_ text: String, _ pattern: String, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), message, file: file, line: line)
    }

    // MARK: - Texts

    private let appLanguages = ["it", "en", "es", "fr", "de", "pt-BR"]

    /// The texts of the box as the code asks for them: the literals handed to `Text(...)` in the box's source. The
    /// minimum age interpolated into two of them is the integer placeholder of the catalog.
    private func boxTextKeys() throws -> [String] {
        let source = try sourceText("QAudionApp/Views/Onboarding/AgeDeclarationSection.swift")
        let regex = try NSRegularExpression(pattern: #"Text\("((?:[^"\\]|\\.)*)"\)"#)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        return matches.compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }.map { $0.replacingOccurrences(of: "\\(AgeDeclaration.minimumAge)", with: "%lld") }
    }

    private func catalogValue(_ strings: [String: Any], _ key: String, _ language: String) -> String? {
        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let localization = localizations[language] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    private func placeholders(in text: String) -> Int {
        text.components(separatedBy: "%lld").count - 1
    }

    /// Every text the box shows is in the catalog in the six languages. Italian is the text the code shows, the other
    /// five are translated (not the key), and each language keeps the same placeholders as the key.
    func testTheBoxTextsAreInTheCatalogInAllSixLanguages() throws {
        let keys = try boxTextKeys()
        XCTAssertEqual(keys.count, 5, "the heading, the sentence, the checkbox and the two links")
        XCTAssertEqual(Set(keys).count, keys.count, "a text appears twice")

        let catalog = try sourceText("QAudionApp/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])

        for key in keys {
            XCTAssertNotNil(strings[key], "\(key) is not in the catalog")
            for language in appLanguages {
                let value = catalogValue(strings, key, language)
                XCTAssertNotNil(value, "\(key) is not translated into \(language)")
                guard let text = value else { continue }
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) \(language) is empty")
                XCTAssertEqual(placeholders(in: text), placeholders(in: key), "\(key) \(language) changes the placeholders")
                XCTAssertFalse(text.replacingOccurrences(of: "%lld", with: "").contains("%"),
                               "\(key) \(language) has a placeholder the code does not fill")
                if language == "it" {
                    XCTAssertEqual(text, key, "the Italian text of \(key) is not what the code shows")
                } else {
                    XCTAssertNotEqual(text, key, "\(key) \(language) is the Italian text")
                }
            }
        }
    }

    /// The two sentences that carry the minimum age keep exactly one integer placeholder, and nobody wrote the age
    /// into a translation as a number.
    func testTheMinimumAgeIsAPlaceholderNotANumberInEveryLanguage() throws {
        let keys = try boxTextKeys().filter { placeholders(in: $0) > 0 }
        XCTAssertEqual(keys.count, 2, "the sentence and the checkbox carry the minimum age")
        let catalog = try sourceText("QAudionApp/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        for key in keys {
            for language in appLanguages {
                let text = try XCTUnwrap(catalogValue(strings, key, language))
                XCTAssertEqual(placeholders(in: text), 1, "\(key) \(language)")
                XCTAssertFalse(text.contains("18"), "\(key) \(language) writes the age as a number")
            }
        }
    }

    // MARK: - Source lookup

    private struct SourceNotFound: Error {}

    private func sourceText(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        XCTFail("\(relativePath) not found from \(file)")
        throw SourceNotFound()
    }
}
