import XCTest

/// The legal screens and the places that start them, as source invariants (the views cannot be driven here): comments
/// are stripped and whitespace collapsed before matching, so only code counts.
final class LegalWiringTests: XCTestCase {

    private func code(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                let withoutComments = raw
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found from \(file)", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    func testTheRootViewMountsTheLegalLayer() throws {
        XCTAssertTrue(try code("QAudionApp/QAudionApp.swift").contains(".legalRoot(appState: appState)"))
    }

    /// The re-acceptance screen is taken down by a call of any kind, with the same rule the consent sheet uses.
    func testTheGateFollowsTheCallActivityRule() throws {
        let root = try code("QAudionApp/Views/Legal/LegalRootModifier.swift")
        XCTAssertTrue(root.contains("MeshConsentPresentation.callIsBusy("))
        XCTAssertTrue(root.contains(".onReceive(callBusy) { busy in gate.setCallBusy(busy) }"))
        XCTAssertTrue(root.contains("if gate.isPresented { TermsGateScreen("), "an overlay: a call never waits for it to slide away")
    }

    func testTheGateIsAskedAtLaunchAndOnForeground() throws {
        let root = try code("QAudionApp/Views/Legal/LegalRootModifier.swift")
        XCTAssertTrue(root.contains(".onReceive(appState.$isAuthenticated)"))
        XCTAssertTrue(root.contains("if phase == .active && appState.isAuthenticated { Task { await gate.refresh() } }"))
    }

    func testTheGateScreenOffersDeleteAccountOnTheSameScreen() throws {
        let screen = try code("QAudionApp/Views/Legal/TermsAcceptanceViews.swift")
        XCTAssertTrue(screen.contains("account.deleteAccount()"))
        XCTAssertTrue(screen.contains("terms-gate-delete-account"))
    }

    func testTheFirstPhoneCallAsksForTheEmergencyNotice() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("if origin == .phone { await EmergencyNoticeCenter.shared.confirmBeforeFirstCall()"))
    }

    func testEveryRegistrationPathSendsTheAcceptance() throws {
        XCTAssertTrue(try code("QAudionApp/Views/Onboarding/OtpVerificationScreen.swift").contains("termsAcceptance: termsAcceptance"))
        XCTAssertTrue(try code("QAudionApp/Views/Onboarding/ExtensionOnlyRegisterScreen.swift").contains("termsAcceptance: acceptance"))
        XCTAssertTrue(try code("QAudionApp/Views/Onboarding/PhoneEntryScreen.swift").contains("onContinue(number.hash, number.e164, true, acceptance)"))
    }

    /// A refusal over the Terms clears the acceptance, brings the steps back and keeps the data already entered.
    func testARefusedAcceptanceBringsTheStepsBackOnBothRegistrationScreens() throws {
        let otp = try code("QAudionApp/Views/Onboarding/OtpVerificationScreen.swift")
        XCTAssertTrue(otp.contains("if mode == .register, BCryptoTermsRefusal.from(error) != nil {"))
        XCTAssertTrue(otp.contains("acceptanceRefused = true renewedAcceptance = nil showingTerms = true"))
        XCTAssertTrue(otp.contains("guard renewedAcceptance != nil else { return } Task { await verify() }"), "same registration, same code")
        let ext = try code("QAudionApp/Views/Onboarding/ExtensionOnlyRegisterScreen.swift")
        XCTAssertTrue(ext.contains("if BCryptoTermsRefusal.from(error) != nil {"))
        XCTAssertTrue(ext.contains("acceptedTerms = nil showingTerms = true"))
        XCTAssertTrue(ext.contains("guard let acceptance = acceptedTerms else { return } Task { await submit(acceptance: acceptance) }"))
    }

    func testTheEmergencyNoticeNeverHoldsTheStartGateForever() throws {
        let service = try code("QAudionApp/Services/LegalService.swift")
        XCTAssertTrue(service.contains("UIApplication.shared.applicationState == .active"))
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("if isInCall { callStartGate.end() RTLog.warn(\"call\", \"startCall ignored — a call went live while the emergency notice was shown\") return }"))
    }

    func testTheReceiptIsKeptOnDiskAndClosingUnsavedAsks() throws {
        let service = try code("QAudionApp/Services/LegalService.swift")
        XCTAssertTrue(service.contains("try? file?.save(newReceipt)"))
        let withdrawal = try code("QAudionApp/Views/Legal/WithdrawalViews.swift")
        XCTAssertTrue(withdrawal.contains("WithdrawalReceiptStore.shared.present(receipt)"))
        XCTAssertTrue(withdrawal.contains("switch ReceiptClosePolicy.decide(saved: saved) {"))
        XCTAssertTrue(withdrawal.contains("Button(LegalStrings.receiptSave) { exporting = true }"))
    }

    func testTheOldHardcodedTermsVersionIsGone() throws {
        let age = try code("QAudionEngine/Sources/QAudionEngine/Backend/Protocols/AgeDeclaration.swift")
        XCTAssertFalse(age.contains("terms_version"))
        XCTAssertFalse(age.contains("2026-08-05"))
    }

    func testTheWithdrawalRowIsInTheAccountScreenAndTheReceiptIsKeptAboveTheApp() throws {
        XCTAssertTrue(try code("QAudionApp/Views/Settings/AccountSettingsScreen.swift").contains("WithdrawalScreen(appState: appState)"))
        let root = try code("QAudionApp/Views/Legal/LegalRootModifier.swift")
        XCTAssertTrue(root.contains("WithdrawalReceiptScreen(receipt: receipt)"))
    }
}
