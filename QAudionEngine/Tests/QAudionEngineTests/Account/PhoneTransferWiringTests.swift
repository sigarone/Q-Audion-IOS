import XCTest
@testable import QAudionEngine

/// The WIRING of the pending phone-number transfer banner in the app target.
///
/// `PhoneTransferNoticeModelTests` pin the behaviour of the model. What they cannot see is whether the app
/// still feeds and clears it where it must. `AppState`, the app scene and the chat list cannot be driven here
/// (live provider, SwiftUI, the app lock), so these are SOURCE INVARIANTS, the same choice
/// `BadgeAndBusyHoldWiringTests` makes: comments are stripped and whitespace collapsed before matching, and a
/// missing file or marker FAILS, it never skips.
final class PhoneTransferWiringTests: XCTestCase {

    private struct SourceProblem: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    private func code(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                let withoutComments = raw
                    .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        XCTFail("\(relativePath) not found from \(file): the wiring invariants cannot run", file: file, line: line)
        throw SourceProblem(what: "source file not found: \(relativePath)")
    }

    private func appState() throws -> String { try code("QAudionApp/AppState.swift") }

    /// The text from the first `start` to the next `end` after it. Both must exist.
    private func slice(
        _ code: String, from start: String, to end: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let s = try XCTUnwrap(code.range(of: start), "marker not found: \(start)", file: file, line: line)
        let e = try XCTUnwrap(
            code.range(of: end, range: s.upperBound..<code.endIndex),
            "end marker not found after \(start): \(end)", file: file, line: line)
        return String(code[s.lowerBound..<e.lowerBound])
    }

    // MARK: - what clears the state

    func testChangingTheSignedInAccountClearsTheState() throws {
        let text = try slice(try appState(), from: "@Published var currentUserId: String? {", to: "@Published")
        XCTAssertTrue(text.contains("if currentUserId != oldValue { phoneTransferNotice.reset() }"))
    }

    func testEveryWipePathClearsTheState() throws {
        let text = try slice(
            try appState(), from: "func resetAccountScopedRuntimeState() {", to: "ServiceSendHub.shared.reset()")
        XCTAssertTrue(text.contains("phoneTransferNotice.reset()"),
                      "logout, remote wipe and account deletion all run this function")
    }

    func testALockedAccountClearsTheState() throws {
        let text = try slice(
            try appState(), from: "ws.registerHandler(type: \"account_locked\")",
            to: "ws.registerHandler(type: \"entitlements_changed\")")
        XCTAssertTrue(text.contains("self?.authService.clearToken()"))
        XCTAssertTrue(text.contains("self?.phoneTransferNotice.reset()"))
    }

    func testARejectedSessionAtTheProfileReadClearsTheState() throws {
        let text = try slice(
            try appState(), from: "QR re-pair required\"", to: "self.isAuthenticated = false")
        XCTAssertTrue(text.contains("authService.clearToken()"))
        XCTAssertTrue(text.contains("self.phoneTransferNotice.reset()"))
    }

    func testTheAppLockDropsTheStateAndTheUnlockReadsAgain() throws {
        let scene = try code("QAudionApp/QAudionApp.swift")
        XCTAssertTrue(
            scene.contains(".onChange(of: lockService.isLocked) { locked in appState.phoneTransferNotice.setLocked(locked) if !locked { appState.refreshPhoneTransferNotice() } }"),
            "locking drops the state and stops reads, unlocking reads again without waiting")
        XCTAssertTrue(scene.contains("appState.isAppLocked = { lock.isLocked }"),
                      "the lock is also read where a read starts, so it cannot lag behind the observer")
    }

    // MARK: - what starts a read

    func testAReadNeedsASignedInSessionAndAnUnlockedApp() throws {
        let text = try slice(
            try appState(), from: "func refreshPhoneTransferNotice(throttled: Bool = false) {", to: "var isAppLocked")
        XCTAssertTrue(text.contains("guard liveProvider != nil, !(isAppLocked?() ?? false) else { return }"))
    }

    func testOnlyThePendingNoticeStartsAnUnthrottledRead() throws {
        let text = try slice(
            try appState(), from: "ws.registerHandler(type: \"account_notice\")",
            to: "ws.registerHandler(type: \"kms_key_available\")")
        XCTAssertTrue(text.contains("guard PhoneTransferNotice.isPending(data) else { return }"))
        XCTAssertTrue(text.contains("self?.refreshPhoneTransferNotice()"))
        XCTAssertFalse(text.contains("throttled: true"), "a notice is never held back by the minimum interval")
    }

    func testTheSocketAuthenticatingAndTheForegroundAreThrottled() throws {
        XCTAssertTrue(try appState().contains("self?.refreshPhoneTransferNotice(throttled: true)"))
        let scene = try code("QAudionApp/QAudionApp.swift")
        XCTAssertTrue(scene.contains("appState.refreshPhoneTransferNotice(throttled: true)"))
    }

    // MARK: - what the user sees

    func testTheBannerIsInTheChatListAndCancelsThroughTheModel() throws {
        XCTAssertTrue(try code("QAudionApp/Views/Chat/ChatListScreen.swift")
            .contains("PhoneTransferBanner(model: appState.phoneTransferNotice)"))
        XCTAssertTrue(try code("QAudionApp/Views/Chat/PhoneTransferBanner.swift")
            .contains("model.requestCancel()"), "the button disables itself at the first tap")
    }
}
