import XCTest
@testable import QAudionEngine

/// The WIRING of the notice push in the app target. `NoticePushTests` pin the decisions; what they cannot see
/// is whether the app still asks them where it must (`AppState`, the notification centre and the home screen
/// cannot be driven here). SOURCE INVARIANTS, the same choice `PhoneTransferWiringTests` makes: comments are
/// stripped and whitespace collapsed before matching, and a missing file or marker FAILS, it never skips.
final class NoticePushWiringTests: XCTestCase {

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

    func testTheTokenGoesToTheNoticeEndpointOnlyWhenTheAlertCallPathIsOff() throws {
        let text = try slice(
            try appState(), from: "func handleApnsDeviceToken(hex: String) {",
            to: "private func reassertStandardApnsTokenRegistration() {")
        XCTAssertTrue(text.contains(
            "guard CallsGate.callKitFreeMode else { registerNoticeApnsToken(hex: hex) return } registerStandardApnsToken(hex: hex)"))
    }

    func testLoginAndForegroundRunTheNoticeCheckOnlyWithoutTheAlertCallPath() throws {
        let text = try slice(
            try appState(), from: "private func reassertStandardApnsTokenRegistration() {",
            to: "private func registerStandardApnsToken(hex: String) {")
        XCTAssertTrue(text.contains("guard CallsGate.callKitFreeMode else { ensureNoticePushRegistration() return }"))
    }

    func testThePermissionIsAskedOnlyWhenThePolicySaysSo() throws {
        let text = try slice(
            try appState(), from: "private func ensureNoticePushRegistration() {",
            to: "private func registerNoticeApnsToken(hex: String) {")
        XCTAssertTrue(text.contains("guard !CallsGate.callKitFreeMode"))
        XCTAssertTrue(text.contains("guard authService.loadToken()?.isEmpty == false else { return }"),
                      "nothing is asked before sign-in")
        XCTAssertTrue(text.contains("NoticePushPolicy.step("))
        XCTAssertTrue(text.contains("case .register: UIApplication.shared.registerForRemoteNotifications()"))
        XCTAssertTrue(text.contains("case .askThenRegister: _ = await center.requestAuthorization()"))
        XCTAssertEqual(text.components(separatedBy: "requestAuthorization()").count - 1, 1,
                       "the one request is the .askThenRegister step")
    }

    func testTheNoticeRegistrationUsesTheNoticeRouteAndKeepsNoCallAlertState() throws {
        let notice = try slice(
            try appState(), from: "private func registerNoticeApnsToken(hex: String) {",
            to: "func scheduleWsKeepalive() {")
        XCTAssertTrue(notice.contains("route: .notice"))
        XCTAssertFalse(notice.contains(".callAlert"))
        XCTAssertFalse(notice.contains("UserDefaults"))
        XCTAssertFalse(notice.contains("pendingApnsTokenHex"))
        let alert = try slice(
            try appState(), from: "private func registerStandardApnsToken(hex: String) {",
            to: "private func ensureNoticePushRegistration() {")
        XCTAssertTrue(alert.contains("route: .callAlert"))
    }

    func testAnAccountChangeForgetsTheRunningNoticeTokenRequest() throws {
        let text = try slice(
            try appState(), from: "func resetAccountScopedRuntimeState() {", to: "phoneTransferNotice.reset()")
        XCTAssertTrue(text.contains("noticeTokenInFlight.reset()"),
                      "logout, remote wipe and account deletion run this function; the next account registers again")
        let notice = try slice(
            try appState(), from: "private func registerNoticeApnsToken(hex: String) {",
            to: "func scheduleWsKeepalive() {")
        XCTAssertTrue(notice.contains("noticeTokenInFlight.begin(hex: hex)"))
        XCTAssertTrue(notice.contains("noticeTokenInFlight.finish(ticket: ticket)"))
    }

    func testTheAlertCallPermissionRequestIsStillOnlyForTheAlertCallPath() throws {
        XCTAssertTrue(try appState().contains(
            "if CallsGate.callKitFreeMode { Task { @MainActor in _ = await NotificationCenterService.shared.requestAuthorization() } }"))
    }

    func testATapOnTheNoticeOpensTheChatListAndReadsTheState() throws {
        let app = try appState()
        XCTAssertTrue(app.contains(
            "NotificationCenterService.shared.onPhoneTransferPendingTap = { [weak self] in self?.openChatListForPhoneTransferNotice() }"))
        XCTAssertTrue(app.contains("NotificationCenterService.shared.flushPendingPhoneTransferTap()"))
        XCTAssertTrue(app.contains(
            "func openChatListForPhoneTransferNotice() { chatListOpenRequest += 1 refreshPhoneTransferNotice() }"))
        let center = try code("QAudionApp/Services/NotificationCenterService.swift")
        XCTAssertTrue(center.contains(
            "if categoryFinal != .incomingCall, actionFinal == UNNotificationDefaultActionIdentifier, PhoneTransferNotice.isPendingPush(userInfo: infoFinal) {"))
        let home = try code("QAudionApp/Views/HomeView.swift")
        XCTAssertTrue(home.contains(
            ".onChange(of: appState.chatListOpenRequest) { _ in selectedTab = .chats chatsPath = NavigationPath() }"))
    }
}
