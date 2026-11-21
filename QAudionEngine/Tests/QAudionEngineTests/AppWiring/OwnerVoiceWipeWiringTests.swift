import XCTest

/// Account change and the owner voice ("Voce come chiave"): logout, account deletion and remote wipe all run
/// `LocalCryptoWipe.wipeAll()`, so the owner's template and the learning record must go with it, a failure must be reported
/// like the other steps, and the call monitor must hand its windows back with the generation it started with.
///
/// `LocalCryptoWipe` lives in the app target and cannot be driven here, so these are SOURCE INVARIANTS, the same choice
/// the other wiring tests of this folder make: comments are stripped and whitespace collapsed before matching, so only
/// code counts. The behaviour of the learner itself (`wipe`, the generation, the stage that is reported) is tested in
/// `OwnerVoiceLearningTests` and `OwnerContinuityMonitorTests`.
final class OwnerVoiceWipeWiringTests: XCTestCase {

    private struct SourceProblem: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    private func repoRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let marker = dir.appendingPathComponent("QAudionApp/Services/LocalCryptoWipe.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
        }
        XCTFail("QAudionApp/Services/LocalCryptoWipe.swift not found from \(file)")
        throw SourceProblem(what: "repository root not found")
    }

    /// The code of a source file: line comments stripped, every run of whitespace collapsed to one space.
    private func code(_ relative: String, file: StaticString = #filePath) throws -> String {
        let url = try repoRoot(file: file).appendingPathComponent(relative)
        let raw = try String(contentsOf: url, encoding: .utf8)
        let withoutComments = raw
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { line -> Substring in
                if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else {
            throw SourceProblem(what: "\(start) ... \(end) not found")
        }
        return String(text[a.upperBound..<b.lowerBound])
    }

    func testTheWipeRemovesTheOwnerVoiceAndReportsWhatIsLeft() throws {
        let wipe = try code("QAudionApp/Services/LocalCryptoWipe.swift")
        let all = try slice(wipe, from: "static func wipeAll() {", to: "static func wipeOwnerVoice(")
        XCTAssertTrue(all.contains("wipeOwnerVoice()"), "wipeAll() must remove the owner voice")
        let owner = try slice(wipe, from: "static func wipeOwnerVoice(", to: "static func clearLiveLogQueue(")
        XCTAssertTrue(owner.contains("learner.wipe()"))
        XCTAssertTrue(owner.contains("[LocalCryptoWipe] OwnerVoiceLearner.wipe left:"), "a leftover is printed like any failed step")
        XCTAssertFalse(owner.contains("try?"), "a failure is never swallowed")
        XCTAssertTrue(owner.contains("return left.isEmpty"))
    }

    func testEveryWayAnAccountEndsRunsTheWipe() throws {
        let app = try code("QAudionApp/AppState.swift")
        let logout = try slice(app, from: "func logout() {", to: "func endLiveCallsForSessionEnd() {")
        XCTAssertTrue(logout.contains("LocalCryptoWipe.wipeAll()"))
        let remote = try slice(app, from: "ws.registerHandler(type: \"remote_wipe\")", to: "ws.registerHandler(type: \"account_locked\")")
        XCTAssertTrue(remote.contains("LocalCryptoWipe.wipeAll()"))
        let legal = try code("QAudionApp/Services/LegalService.swift")
        let server = try slice(legal, from: "func finishLocalSessionAfterServerSideDeletion() {", to: "authService.clearToken()")
        XCTAssertTrue(server.contains("LocalCryptoWipe.wipeAll()"))
        let settings = try code("QAudionApp/Views/Settings/AccountSettingsScreen.swift")
        XCTAssertTrue(settings.contains("LocalCryptoWipe.wipeAll()"))
        XCTAssertTrue(legal.contains("LocalCryptoWipe.wipeAll()"))
    }

    func testTheMonitorHandsItsWindowsBackWithTheGenerationOfTheCallStart() throws {
        let monitor = try code("QAudionEngine/Sources/QAudionEngine/Deepfake/OwnerContinuityMonitor.swift")
        XCTAssertTrue(monitor.contains("let generation = learner.generation switch learner.prepare(userId: userId)"), "read before prepare")
        XCTAssertTrue(monitor.contains("sessionGeneration = generation"))
        XCTAssertTrue(monitor.contains("learner.record(windows: batch, userId: sessionUserId, generation: sessionGeneration)"))
    }
}
