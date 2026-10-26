import XCTest
@testable import QAudionEngine

/// What ends a signed-in session in the app (logout, the server's `remote_wipe` and `account_locked`) must leave no
/// live runtime behind: `connectPersistentSocket()` returns early while `liveProvider` is set, so a session that
/// keeps its provider gives the next sign-in no WebSocket and no presence. The app target has no unit-test host for
/// `AppState`, so the wiring is pinned as source invariants, the way `GroupPromotionWiringTests` does.
final class SessionTeardownWiringTests: XCTestCase {

    private struct SourceNotFound: Error { let path: String }

    private func code(_ relativePath: String = "QAudionApp/AppState.swift",
                      file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        var found: URL?
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { found = candidate; break }
        }
        guard let url = found else {
            XCTFail("\(relativePath) not found: the source invariants cannot run", file: file, line: line)
            throw SourceNotFound(path: relativePath)
        }
        let raw = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let withoutComments = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func slice(_ text: String, from start: String, to end: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let s = text.range(of: start) else {
            XCTFail("start marker not found: \(start)", file: file, line: line)
            throw SourceNotFound(path: start)
        }
        guard let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
            XCTFail("end marker not found: \(end)", file: file, line: line)
            throw SourceNotFound(path: end)
        }
        return String(text[s.lowerBound..<e.lowerBound])
    }

    private func assertInOrder(_ text: String, _ markers: [String], file: StaticString = #filePath, line: UInt = #line) {
        var from = text.startIndex
        for marker in markers {
            guard let r = text.range(of: marker, range: from..<text.endIndex) else {
                XCTFail("\(marker) is missing or out of order", file: file, line: line)
                return
            }
            from = r.upperBound
        }
    }

    func testTheTeardownDropsTheProviderTheSocketAndThePresence() throws {
        let app = try code()
        let teardown = try slice(app, from: "func tearDownSessionRuntime() {", to: "sasReadyObserverToken = nil }")
        for needle in ["endLiveCallsForSessionEnd()", "callEngineLifecycle.teardown()",
                       "liveProvider?.persistentConnection.disconnect()", "liveProvider = nil", "_relayProvider = nil",
                       "presenceService.reset()", "currentUserId = nil", "callState = .idle", "isInCall = false"] {
            XCTAssertTrue(teardown.contains(needle), "the teardown must run \(needle)")
        }
    }

    func testTheNextSignInRebuildsTheSocketBecauseTheProviderIsGone() throws {
        let app = try code()
        // The reason the teardown matters: the connect is a no-op while a provider exists.
        let connect = try slice(app, from: "private func connectPersistentSocket() {", to: "wireGroupChatFanOut()")
        XCTAssertTrue(connect.contains("if liveProvider != nil { return }"))
        // Every way a session ends runs the teardown, then flips the sign-in state.
        let logout = try slice(app, from: "func logout() {", to: "func endLiveCallsForSessionEnd() {")
        assertInOrder(logout, ["endLiveCallsForSessionEnd()", "LocalCryptoWipe.wipeAll()", "tearDownSessionRuntime()", "isAuthenticated = false"])
        let wipe = try slice(app, from: "ws.registerHandler(type: \"remote_wipe\")", to: "ws.registerHandler(type: \"account_locked\")")
        assertInOrder(wipe, ["endLiveCallsForSessionEnd()", "LocalCryptoWipe.wipeAll()", "tearDownSessionRuntime()", "isAuthenticated = false"])
        let locked = try slice(app, from: "ws.registerHandler(type: \"account_locked\")", to: "ws.registerHandler(type: \"entitlements_changed\")")
        assertInOrder(locked, ["endLiveCallsForSessionEnd()", "clearToken()", "tearDownSessionRuntime()", "isAuthenticated = false"])
    }

    /// With a CarPlay scene connected the App-level scene phase is the aggregate of all scenes and stays active while
    /// the car is in front. The app lock must follow the phone window's own phase.
    func testTheAppLockFollowsThePhoneWindowAndNotTheAggregateScenePhase() throws {
        let app = try code("QAudionApp/QAudionApp.swift")
        let appStruct = try slice(app, from: "struct QAudionApp: App {", to: "var body: some Scene {")
        XCTAssertFalse(appStruct.contains("@Environment(\\.scenePhase)"), "no App-level scene phase")
        XCTAssertTrue(app.contains(".modifier(PhoneWindowPhase(handle: handleScenePhase))"))
        let modifier = try slice(app, from: "private struct PhoneWindowPhase: ViewModifier {", to: "func body(content: Content)")
        XCTAssertTrue(modifier.contains("@Environment(\\.scenePhase) private var phase"))
    }

    func testALiveCallEndsThroughTheOneTeardownThatTellsCallKit() throws {
        let app = try code()
        let ends = try slice(app, from: "func endLiveCallsForSessionEnd() {", to: "func tearDownSessionRuntime() {")
        XCTAssertTrue(ends.contains("if isInCall || callState != .idle { endCall() }"))
        XCTAssertTrue(ends.contains("if groupCallControllerState != .idle { leaveLiveGroupCall(why: .hangUp) }"))
    }
}
