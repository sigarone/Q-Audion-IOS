import XCTest
@testable import QAudionEngine

/// The incompatible-peer end is wired end to end: the peer-origin malformed verdicts report `peer_incompatible`
/// (never a relaxed check), the wire hangup keeps `handshake_malformed`, the callee's watchdog is armed on answer,
/// and the message and history label exist in every language.
final class PeerIncompatibleWiringTests: XCTestCase {

    private func sourceText(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("source not found: \(relativePath)")
    }

    private let appPath = "QAudionApp/AppState.swift"
    private let integrationPath = "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"
    private let catalogPath = "QAudionApp/Localizable.xcstrings"

    func testEveryPeerBundleMalformedVerdictReportsPeerIncompatible() throws {
        let src = try sourceText(integrationPath)
        let peer = src.components(separatedBy: "reportHandshakeFatal(callId: callId, reason: CallCloseReason.peerIncompatible.rawValue)").count - 1
        XCTAssertEqual(peer, 6, "OFFER round, OFFER verdict, OFFER transcript, commit missing, ACCEPT verdict, ACCEPT transcript")
        // The call without an id is not the peer's bundle: it stays the malformed class.
        XCTAssertTrue(src.contains("reportHandshakeFatal(callId: callId, reason: \"handshake_malformed\")"))
        // Verdict-only checks: the signature and fingerprint checks are untouched.
        XCTAssertTrue(src.contains("case .malformed(let code):"))
    }

    func testTheFatalHandlerKeepsTheMalformedReasonOnTheWireAndShowsTheMessage() throws {
        let app = try sourceText(appPath)
        XCTAssertTrue(app.contains("let wireReason: String = CallCloseReason.accepted(reason)?.wireReason ?? reason"))
        XCTAssertTrue(app.contains("self.callService.sendControlHangup(reason: wireReason)"))
        XCTAssertTrue(app.contains("reason: wireReason)"))
        XCTAssertTrue(app.contains("peerIncompatibleToastText = String("))
        XCTAssertTrue(app.contains("handleHandshakeFatal(callId: callId, reason: CallCloseReason.peerIncompatible.rawValue)"))
        let content = try sourceText("QAudionApp/Views/ContentView.swift")
        XCTAssertTrue(content.contains(".onChange(of: appState.peerIncompatibleToastText)"))
    }

    func testTheCalleeWatchdogIsArmedOnAnswerAndEndsAsPeerIncompatible() throws {
        let app = try sourceText(appPath)
        XCTAssertTrue(app.contains("self.armCalleeOfferWatchdog(callId: ringPlanCallId)"))
        XCTAssertTrue(app.contains("CalleeOfferWatchdog.verdict("))
        XCTAssertTrue(app.contains("hasProcessedOffer(callId: callId)"))
        // Only a healthy link gives the verdict; the task is stored and cancelled at teardown.
        XCTAssertTrue(app.contains("linkHealthy: acceptDelivered && socketUp"))
        XCTAssertTrue(app.contains("calleeOfferWatchdogTask?.cancel()"))
        XCTAssertFalse(app.contains("hasProcessedOffer(callId: callId) ?? false"))
        // The legacy caller (no call id) gets the same message.
        let reject = try XCTUnwrap(app.range(of: "private func rejectIncomingCallWithoutCallId"))
        XCTAssertTrue(app[reject.lowerBound...].prefix(900).contains("showPeerIncompatibleToast()"))
    }

    func testTheMessageAndTheHistoryLabelExistInEveryLanguage() throws {
        let catalog = try sourceText(catalogPath)
        let data = Data(catalog.utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for key in ["call.peer_incompatible", "call_history.close.peer_incompatible"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for lang in ["it", "en", "fr", "de", "es", "pt-BR"] {
                let loc = try XCTUnwrap(locs[lang] as? [String: Any], "\(key) \(lang)")
                let unit = try XCTUnwrap(loc["stringUnit"] as? [String: Any], "\(key) \(lang)")
                XCTAssertFalse(((unit["value"] as? String) ?? "").isEmpty, "\(key) \(lang)")
            }
        }
        let it = try XCTUnwrap((((strings["call.peer_incompatible"] as? [String: Any])?["localizations"] as? [String: Any])?["it"] as? [String: Any])?["stringUnit"] as? [String: Any])
        XCTAssertEqual(it["value"] as? String,
                       "Impossibile completare la chiamata: il contatto usa una versione di Q-Audion non compatibile. Chiedigli di aggiornare l'app.")
    }
}
