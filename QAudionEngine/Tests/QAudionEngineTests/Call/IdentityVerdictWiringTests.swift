import XCTest

/// Every call integration of the app reports the identity verdict of its handshake rounds to the one handler.
///
/// A leg that built an integration and never wired `onIdentityVerdict` would leave the identity state of its calls at "pending" for
/// good: grey shield, no marker on the contact. Source invariants, like `CallMinimizeWiringTests` (comments stripped, whitespace
/// collapsed): they fail when someone adds an integration without the shared wiring.
final class IdentityVerdictWiringTests: XCTestCase {

    private func code(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                return raw.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found: the wiring invariants cannot run")
        throw NSError(domain: "IdentityVerdictWiringTests", code: 1)
    }

    private func sourceDirectory(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue { return candidate }
        }
        XCTFail("\(relativePath) not found: the wiring invariants cannot run")
        throw NSError(domain: "IdentityVerdictWiringTests", code: 2)
    }

    private func count(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    func testTheSharedWiringSetsTheVerdictAndTheProofFetchOnTheIntegration() throws {
        let app = try code("QAudionApp/AppState.swift")
        let start = try XCTUnwrap(app.range(of: "private func wireHandshakeSigning(on integration: QAudionCallIntegration) {"))
        let tail = String(app[start.lowerBound...])
        XCTAssertTrue(tail.contains("integration.onIdentityVerdict = "))
        XCTAssertTrue(tail.contains("handleIdentityVerdict(report)"))
        XCTAssertTrue(tail.contains("integration.fetchPublishedKeyForDevice = "))
        // and nowhere else: one assignment each, so a second, different handler cannot appear
        XCTAssertEqual(1, count(of: ".onIdentityVerdict = ", in: app))
        XCTAssertEqual(1, count(of: ".fetchPublishedKeyForDevice = ", in: app))
    }

    /// Every construction of a call integration is followed, in its leg, by the shared wiring.
    func testEveryIntegrationOfTheAppGoesThroughTheSharedWiring() throws {
        let app = try code("QAudionApp/AppState.swift")
        let service = try code("QAudionApp/Services/CallService.swift")
        // the responder leg builds its own integration in AppState and wires it
        XCTAssertEqual(1, count(of: "QAudionCallIntegration()", in: app))
        let responder = try XCTUnwrap(app.range(of: "private func ensureResponderIntegration(forCaller callerId: String) -> QAudionCallIntegration {"))
        let responderBody = String(app[responder.lowerBound...].prefix(60_000))
        XCTAssertTrue(responderBody.contains("wireHandshakeSigning(on: integration) responderCallIntegration = integration"),
                      "the responder integration is wired before it is kept")
        // the outgoing leg builds it in CallService and AppState wires whatever CallService holds, right after the call is set up
        XCTAssertEqual(1, count(of: "QAudionCallIntegration()", in: service))
        XCTAssertTrue(app.contains("if let integration = callService.callIntegration, let provider = liveProvider {"))
        XCTAssertTrue(app.contains("wireHandshakeSigning(on: integration) integration.sendCallProcessing"),
                      "the outgoing integration is wired with the same function")
        // nothing else creates one: every .swift file of the app and of the engine is scanned, so a new construction anywhere
        // (a group leg, a video view, a new service) fails here until it goes through wireHandshakeSigning(on:)
        let allowed = ["QAudionApp/AppState.swift": 1, "QAudionApp/Services/CallService.swift": 1]
        var scanned = 0
        for root in ["QAudionApp", "QAudionEngine/Sources"] {
            let dir = try sourceDirectory(root)
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil), "cannot enumerate \(dir.path)")
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let relative = root + String(url.path.dropFirst(dir.path.count))
                let text = try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                XCTAssertEqual(allowed[relative] ?? 0, count(of: "QAudionCallIntegration(", in: text),
                               "\(relative): a call integration must be built only where wireHandshakeSigning(on:) follows it")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan found almost no source files: the directory lookup is broken")
        // the engine never assigns a call integration to another holder
        XCTAssertEqual(2, count(of: "self.callIntegration = integration", in: service),
                       "a new place that stores a call integration must be wired too: update this test with its wiring")
    }
}
