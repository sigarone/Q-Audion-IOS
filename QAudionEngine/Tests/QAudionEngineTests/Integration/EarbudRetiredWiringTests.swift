import XCTest
@testable import QAudionEngine

/// R-EARBUD — there is no unauthenticated handshake path: the earbud-relay-v1 counterparty
/// handshake is retired. The capability tag is an unsigned field the server relays, so nothing
/// the app does may depend on it: it must never start a counterparty handshake and never switch
/// the dead-media watchdog off.
///
/// Behavioural tests are not available (AppState / CallService need CallKit, a live provider and
/// a WebSocket), so these are SOURCE INVARIANTS, the same choice `PskAdvertLatchWiringTests` makes.
final class EarbudRetiredWiringTests: XCTestCase {

    private func repoSource(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("could not locate \(relative) from \(#filePath)")
    }

    /// Code (not comments) of `src`: line comments stripped.
    private func code(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                return line
            }
            .joined(separator: "\n")
    }

    func testTheAppNeverStartsAnEarbudCounterpartyHandshake() throws {
        let app = code(try repoSource("QAudionApp/AppState.swift"))
        XCTAssertFalse(app.contains("earbudCounterparty.start("),
                       "a server-relayed earbud capability must not start an unauthenticated handshake")
        XCTAssertFalse(app.contains("peerAdvertisedEarbudRelay"),
                       "AppState must not branch on the earbud capability")
    }

    func testTheMediaDeadWatchdogHasNoEarbudExemption() throws {
        let service = code(try repoSource("QAudionApp/Services/CallService.swift"))
        // The only remaining reader of the tag is the audio-profile resolver, which can only move
        // a call toward the STANDARD profile.
        let readers = service.components(separatedBy: "peerAdvertisedEarbudRelay").count - 1
        XCTAssertEqual(readers, 1, "only the audio-profile resolver may read the earbud capability")
    }

    func testTheCounterpartyInstallStaysRetired() {
        let integration = QAudionCallIntegration()
        XCTAssertThrowsError(try integration.completeEarbudCounterparty(
            callId: "11111111-2222-3333-4444-555555555555", sessionKey: Data(repeating: 7, count: 32))) { error in
            guard case IntegrationError.handshakeAborted(let code) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(code, "earbud_relay_retired")
        }
    }
}
