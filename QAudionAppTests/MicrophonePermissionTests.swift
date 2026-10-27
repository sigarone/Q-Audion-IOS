import XCTest
@testable import QAudionApp

/// The microphone permission across a call: when the app asks, what the call screen offers, when the capture restarts,
/// and that the pieces are wired where the call starts, is answered and is on screen.
final class MicrophonePermissionTests: XCTestCase {

    // MARK: - Asking before a call

    func testAsksOnlyWhileUndeterminedAndOnScreen() {
        XCTAssertTrue(MicrophonePermissionPolicy.shouldAskBeforeCall(state: .undetermined, appActive: true))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldAskBeforeCall(state: .undetermined, appActive: false),
                       "from the lock screen no request can be shown")
        XCTAssertFalse(MicrophonePermissionPolicy.shouldAskBeforeCall(state: .denied, appActive: true))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldAskBeforeCall(state: .granted, appActive: true))
    }

    // MARK: - The strip in the call screen

    func testBannerFollowsTheStateOnlyDuringACall() {
        XCTAssertEqual(MicrophonePermissionPolicy.bannerKind(state: .granted, inCall: true), .none)
        XCTAssertEqual(MicrophonePermissionPolicy.bannerKind(state: .undetermined, inCall: true), .ask)
        XCTAssertEqual(MicrophonePermissionPolicy.bannerKind(state: .denied, inCall: true), .openSettings)
        for state in [MicrophonePermissionState.granted, .undetermined, .denied] {
            XCTAssertEqual(MicrophonePermissionPolicy.bannerKind(state: state, inCall: false), .none)
        }
    }

    // MARK: - Capture restart

    func testCaptureRestartsWhenThePermissionArrivesDuringACall() {
        XCTAssertTrue(MicrophonePermissionPolicy.shouldRestartCapture(previous: .undetermined, current: .granted, inCall: true))
        XCTAssertTrue(MicrophonePermissionPolicy.shouldRestartCapture(previous: .denied, current: .granted, inCall: true))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldRestartCapture(previous: .granted, current: .granted, inCall: true))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldRestartCapture(previous: .undetermined, current: .granted, inCall: false))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldRestartCapture(previous: .undetermined, current: .denied, inCall: true))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldRestartCapture(previous: .granted, current: .denied, inCall: true))
    }

    // MARK: - First-use screen

    func testPrimerIsOfferedOnceAndNeverDuringACall() {
        XCTAssertTrue(MicrophonePermissionPolicy.shouldOfferPrimer(state: .undetermined, inCall: false, alreadyOffered: false))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldOfferPrimer(state: .undetermined, inCall: true, alreadyOffered: false))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldOfferPrimer(state: .undetermined, inCall: false, alreadyOffered: true))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldOfferPrimer(state: .denied, inCall: false, alreadyOffered: false))
        XCTAssertFalse(MicrophonePermissionPolicy.shouldOfferPrimer(state: .granted, inCall: false, alreadyOffered: false))
    }

    // MARK: - Log codes

    func testLogCodesAreStable() {
        XCTAssertEqual([MicrophonePermissionState.undetermined, .denied, .granted].map(\.rawValue), [0, 1, 2])
        XCTAssertEqual([MicrophonePermissionSource.dial, .answer, .foreground, .banner, .primer].map(\.rawValue), [1, 2, 3, 4, 5])
    }

    // MARK: - Wiring

    func testTheCallStartAsksOnlyAfterTheStartGateIsHeldAndFromThePhone() throws {
        let src = try source("QAudionApp/AppState.swift")
        let start = try XCTUnwrap(src.range(of: "func startCall(contactId: String, video: Bool = false, origin: CallStartOrigin = .phone) async {"))
        let tail = String(src[start.upperBound...])
        let ask = try XCTUnwrap(tail.range(of: "askBeforeCallIfNeeded(source: .dial)"))
        let gate = try XCTUnwrap(tail.range(of: "callStartGate.tryBegin()"))
        XCTAssertLessThan(gate.lowerBound, ask.lowerBound, "admission comes before the first await")
        let before = String(tail[..<ask.lowerBound])
        XCTAssertTrue(before.contains("if origin == .phone {"), "nothing is shown on the phone for a car start")
        // After the request the call state is checked again and the gate is released on the early exit.
        let after = String(tail[ask.upperBound...].prefix(400))
        XCTAssertTrue(after.contains("guard !isInCall else"))
        XCTAssertTrue(after.contains("callStartGate.end()"))
    }

    func testThePrimerGoesAwayWhenACallGoesLive() throws {
        let src = try source("QAudionApp/Services/MicrophonePermission.swift")
        XCTAssertTrue(src.contains("if inCall { shown = false }"))
        XCTAssertTrue(try source("QAudionApp/AppState.swift").contains("MicrophonePermissionMonitor.shared.callStateChanged()"))
    }

    func testTheAnswerAsksAndTheMonitorIsWiredToTheCapture() throws {
        let src = try source("QAudionApp/AppState.swift")
        XCTAssertTrue(src.contains("askBeforeCallIfNeeded(source: .answer)"))
        XCTAssertTrue(src.contains("MicrophonePermissionMonitor.shared.onGrantedDuringCall"))
        XCTAssertTrue(src.contains("callService.restartCaptureAfterMicrophoneGranted()"))
    }

    func testTheCallScreenAndTheHomeScreenCarryTheNewViews() throws {
        XCTAssertTrue(try source("QAudionApp/Views/Call/InCallScreen.swift").contains("MicrophonePermissionBanner()"))
        XCTAssertTrue(try source("QAudionApp/Views/HomeView.swift").contains(".microphonePrimer()"))
    }

    func testTheFirstUseScreenHasOnlyContinuaAndCannotBeDismissed() throws {
        let src = try source("QAudionApp/Services/MicrophonePermission.swift")
        let sheet = try XCTUnwrap(src.range(of: "struct MicrophonePrimerSheet: View {"))
        let end = try XCTUnwrap(src.range(of: "/// Offers the first-use screen over the home screen."))
        let body = String(src[sheet.lowerBound..<end.lowerBound])
        XCTAssertEqual(body.components(separatedBy: "Button(").count - 1, 1, "one button")
        XCTAssertTrue(body.contains("Text(\"Continua\")"))
        XCTAssertTrue(body.contains(".interactiveDismissDisabled(true)"))
        XCTAssertFalse(body.contains("Salta") || body.contains("Non ora") || body.contains("Annulla"))
    }

    // MARK: - Strings in every language

    func testEveryNewStringIsTranslatedInAllLanguages() throws {
        let keys = ["call.mic.banner.title", "call.mic.banner.ask", "call.mic.banner.denied",
                    "call.mic.banner.allow", "call.mic.banner.settings",
                    "call.mic.primer.title", "call.mic.primer.body"]
        let data = try Data(contentsOf: sourceURL("QAudionApp/Localizable.xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let loc = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for lang in ["it", "en", "fr", "de", "es", "pt-BR"] {
                let one = try XCTUnwrap(loc[lang] as? [String: Any], "\(key) lacks \(lang)")
                let unit = try XCTUnwrap(one["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(value.isEmpty, "\(key) \(lang)")
            }
        }
    }

    // MARK: - Source access

    private func sourceURL(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw NSError(domain: "MicrophonePermissionTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(relativePath) not found from \(file)"])
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceURL(relativePath), encoding: .utf8)
    }
}
