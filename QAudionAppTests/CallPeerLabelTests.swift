import XCTest
@testable import QAudionApp

/// Label rule of the call-history row: contact name, else the stored extension or number, else
/// "Unknown"; a user id or UUID is never shown.
final class CallPeerLabelTests: XCTestCase {
    private let unknown = "Unknown"
    private let uuid = "6cb04144-1a2b-4c3d-8e9f-0123456789ab"

    private func label(name: String? = nil, display: String? = nil, ext: Int? = nil) -> CallPeerLabel.Result {
        CallPeerLabel.resolve(contactName: name, storedDisplay: display, storedExtension: ext, unknownText: unknown)
    }

    func test_contactNameWins() {
        let r = label(name: "Mario Rossi", display: "Utente 6cb04144…", ext: 103)
        XCTAssertEqual(r.title, "Mario Rossi")
        XCTAssertEqual(r.extensionDigits, "103")
        XCTAssertFalse(r.isUnknown)
    }

    func test_storedExtensionWhenNotInContacts() {
        let r = label(display: "Utente 6cb04144…", ext: 207)
        XCTAssertEqual(r.title, "207")
        XCTAssertFalse(r.isUnknown)
    }

    func test_extensionRecoveredFromLegacyStoredLabel() {
        XCTAssertEqual(label(display: "Int. 103").title, "103")
    }

    func test_storedNumberWhenNoExtension() {
        let r = label(display: "+39 333 1234567")
        XCTAssertEqual(r.title, "+39 333 1234567")
        XCTAssertNil(r.extensionDigits)
        XCTAssertFalse(r.isUnknown)
    }

    func test_nothingKnownGivesUnknown() {
        for r in [label(), label(name: "", display: ""), label(display: "Utente 6cb04144…")] {
            XCTAssertEqual(r.title, unknown)
            XCTAssertTrue(r.isUnknown)
        }
    }

    func test_aUUIDNeverAppears() {
        for r in [label(name: uuid, display: uuid), label(display: uuid), label(name: uuid, display: "Utente 6cb04144…")] {
            XCTAssertEqual(r.title, unknown)
            XCTAssertFalse(r.title.contains("6cb04144"))
        }
    }

    func test_historyRowDoesNotUseTheUserIdFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("QAudionApp/Views/Call/CallHistoryView.swift"),
                             encoding: .utf8)
        XCTAssertFalse(src.contains("shortUserFallback"))
        XCTAssertFalse(src.contains("DisplayName.forUser"))
        XCTAssertTrue(src.contains("CallPeerLabel.resolve"))
    }
}
