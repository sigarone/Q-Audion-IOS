import XCTest
@testable import QAudionEngine

/// W-BUSYHOLD / W-MISSEDBADGE / W-MISSEDQUIET (2026-10-04) — the WIRING of the busy hold, the Calls-tab missed-calls
/// badge and the quiet missed-call notification in the app target.
///
/// `CallerBusyHoldTests`, `MissedCallsBadgeStateTests` and `MissedCallAlertPolicyTests` pin the pure pieces. What they
/// cannot see is whether the app still uses them. `AppState`, `HomeView` and `NotificationCenterService` cannot be
/// driven here (CallKit, a live provider, SwiftUI, `UNUserNotificationCenter`), so these are SOURCE INVARIANTS, the
/// same choice `CallerBusyWiringTests` and `AccountWipeRuntimeResetWiringTests` make. Comments are stripped and
/// whitespace collapsed before matching, so only code counts. A missing file or marker FAILS: it never skips.
final class BadgeAndBusyHoldWiringTests: XCTestCase {

    // MARK: - reading the source

    private struct SourceProblem: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    /// `relativePath` from the repository root, comments stripped, whitespace collapsed.
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

    private func appCode() throws -> String { try code("QAudionApp/AppState.swift") }

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

    /// The text between the braces of the function declared as `declaration` (which ends with its opening brace).
    private func body(
        of declaration: String, in code: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let start = try XCTUnwrap(code.range(of: declaration), "declaration not found: \(declaration)", file: file, line: line)
        var depth = 1
        var index = start.upperBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(code[start.upperBound..<index]) }
            }
            index = code.index(after: index)
        }
        XCTFail("unbalanced braces after: \(declaration)", file: file, line: line)
        throw SourceProblem(what: "unbalanced braces after \(declaration)")
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func assertOrder(
        _ text: String, _ first: String, before second: String, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let a = text.range(of: first) else { return XCTFail("missing: \(first)", file: file, line: line) }
        guard let b = text.range(of: second) else { return XCTFail("missing: \(second)", file: file, line: line) }
        XCTAssertLessThan(a.lowerBound, b.lowerBound, message, file: file, line: line)
    }

    // MARK: - the busy hold: AppState follows CallerOutcomeHold

    /// `showCallerOutcome` asks the hold, and a duplicate (`alreadyShown`) touches nothing: no screen change, no tone
    /// restart, no timer. Fails if the duplicate branch starts the tone or the screen again (the restart / overwrite).
    func testShowingAnOutcomeGoesThroughTheHoldAndADuplicateTouchesNothing() throws {
        let show = try slice(
            try appCode(), from: "private func showCallerOutcome(", to: "private func callerOutcomeHoldElapsed(")
        XCTAssertTrue(
            show.contains("switch callerOutcomeHold.show(outcome, callId: callId, nowMs: Self.monotonicMs()) {"),
            "the showing is the hold's: first terminal of a call wins")
        let duplicate = try slice(show, from: "case .alreadyShown:", to: "case .started(")
        for forbidden in ["callerOutcome =", "callerBusyTone", "asyncAfter", "callerOutcomeHold"] {
            XCTAssertFalse(duplicate.contains(forbidden), "a duplicate outcome must change nothing (\(forbidden))")
        }
        XCTAssertTrue(show.contains("RTLog.info(\"call\", showing.shownLine)"), "busy feedback shown call=<id> holdMs=<n>")
        XCTAssertTrue(show.contains("if outcome.playsBusyTone { callerBusyTone.play() }"))
        assertOrder(show, "callerOutcome = outcome", before: "callerBusyTone.play()", "the screen is up when the tone starts")
    }

    /// The hold timer is scheduled for the SHOWING's own hold (`holdMs`: the one 4000 ms constant for busy) and
    /// carries its serial; no literal duration, and not `outcome.holdSeconds`. Fails if a literal 3.0 / 4.0 comes back.
    func testTheTimerUsesTheShowingsHoldAndSerial() throws {
        let show = try slice(
            try appCode(), from: "private func showCallerOutcome(", to: "private func callerOutcomeHoldElapsed(")
        XCTAssertTrue(show.contains("let serial: Int = showing.serial"))
        XCTAssertTrue(show.contains("let holdSeconds: Double = Double(showing.holdMs) / 1_000"))
        XCTAssertTrue(show.contains("DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds)"))
        XCTAssertTrue(show.contains("self?.callerOutcomeHoldElapsed(serial: serial)"))
        XCTAssertFalse(show.contains("outcome.holdSeconds"), "the hold comes from the showing")
        XCTAssertFalse(show.contains("+ 3.0"))
        XCTAssertFalse(show.contains("+ 4.0"))
    }

    /// The timer closes through the hold with ITS serial; it never touches the tone (the tone is as long as the hold
    /// and disposes of itself after its end).
    func testTheHoldTimerClosesThroughTheHoldAndLeavesTheToneToItself() throws {
        let elapsed = try slice(
            try appCode(), from: "private func callerOutcomeHoldElapsed(serial: Int) {", to: "func dismissCallerOutcome() {")
        XCTAssertTrue(elapsed.contains("guard let closed = callerOutcomeHold.holdElapsed(serial: serial, nowMs: Self.monotonicMs()) else { return }"))
        XCTAssertTrue(elapsed.contains("RTLog.info(\"call\", closed.closedLine)"), "busy feedback closed call=<id> by=timeout ms=<n>")
        XCTAssertTrue(elapsed.contains("callerOutcome = nil"))
        XCTAssertFalse(elapsed.contains("callerBusyTone"), "no early stop of the tone from the timer")
    }

    /// The close button and a redial go through the hold too (`by=user`), then clear the screen and stop the tone.
    func testDismissClosesThroughTheHoldAndStopsTheTone() throws {
        let dismiss = try slice(
            try appCode(), from: "func dismissCallerOutcome() {", to: "private func isCurrentOutgoingCall(")
        XCTAssertTrue(dismiss.contains("callerOutcomeHold.close(by: .user, nowMs: Self.monotonicMs())"))
        XCTAssertTrue(dismiss.contains("RTLog.info(\"call\", closed.closedLine)"))
        assertOrder(dismiss, "callerOutcome = nil", before: "callerBusyTone.stop()", "screen first, then the tone")
    }

    /// `callerOutcome` has exactly three writers: the showing, the hold timer and the dismissal. Anything else that
    /// wrote it could close the screen early. Fails when a fourth writer appears, so the new one is reviewed.
    func testCallerOutcomeHasExactlyTheThreeWritersOfTheHold() throws {
        let code = try appCode()
        XCTAssertEqual(occurrences(of: "callerOutcome = ", in: code), 3,
                       "show (= outcome), hold timer (= nil), dismiss (= nil): nothing else may write it")
        XCTAssertEqual(occurrences(of: "callerOutcome = outcome", in: code), 1)
        XCTAssertEqual(occurrences(of: "callerOutcomeHold.show(", in: code), 1)
        XCTAssertEqual(occurrences(of: "callerOutcomeHold.holdElapsed(", in: code), 1)
        XCTAssertEqual(occurrences(of: "callerOutcomeHold.close(", in: code), 1)
        XCTAssertFalse(code.contains("callerOutcomeSerial"), "the old serial is the hold's now")
    }

    /// A second end callback (CallKit's `onEndCall` racing a `call_hangup`, a late `call_cancel`, the remote-hangup
    /// teardown) runs `endCall` again, or a remote-hangup path: none of them may touch the outcome or the tone. This is
    /// what keeps a second terminal callback from cutting the 4 s hold on iOS. Fails if any of them starts to.
    func testNoTeardownPathCanReachTheOutcomeOrTheTone() throws {
        let code = try appCode()
        let end = try slice(
            code, from: "func endCall(notifyPeerInBand: Bool = true, outcome: CallerTerminalOutcome? = nil) {",
            to: "func promoteToGroupCall(newPeerIds:")
        let cancel = try slice(
            code, from: "private func routeCallCancel(envelopeCallId: String, reason: String?) {",
            to: "private func handleRemoteCallHangup(reasonString: String, viaServerCancel: Bool = false) {")
        let remote = try slice(
            code, from: "private func handleRemoteCallHangup(reasonString: String, viaServerCancel: Bool = false) {",
            to: "private func wireIncomingChatHandlers(on ws: BCryptoWebSocketClient) {")
        for (name, text) in [("endCall", end), ("routeCallCancel", cancel), ("handleRemoteCallHangup", remote)] {
            for forbidden in ["callerBusyTone", "callerOutcome"] {
                XCTAssertFalse(text.contains(forbidden), "\(name) must not touch \(forbidden)")
            }
        }
    }

    /// The busy tone is stopped from five places and no more: the incoming ring (flag, in-app ringtone), answering a
    /// 1:1 or a group call, and the dismissal. A sixth would be a new way to cut it and must be reviewed.
    func testTheBusyToneIsStoppedFromExactlyTheKnownPlaces() throws {
        let code = try appCode()
        XCTAssertEqual(occurrences(of: "callerBusyTone.stop()", in: code), 5)
        XCTAssertEqual(occurrences(of: "callerBusyTone.play()", in: code), 1, "one start: the showing of a busy outcome")
    }

    /// The tone's own timing: disposed after its end (derived from the one constant), a file name that carries its length.
    func testTheToneIsDisposedAfterItsEndAndItsFileCarriesItsLength() throws {
        let tone = try code("QAudionApp/Services/CallerBusyTone.swift")
        XCTAssertTrue(tone.contains("Double(CallerBusyFeedback.soundDisposeAfterMs) / 1_000"))
        XCTAssertTrue(tone.contains("DispatchQueue.main.asyncAfter(deadline: .now() + disposeAfter, execute: work)"))
        XCTAssertFalse(tone.contains("3.5"), "#169's 3.5 s disposal would cut the last burst of a 4 s tone")
        XCTAssertTrue(tone.contains("QAudionCueWav.busyToneFileName"))
        XCTAssertFalse(tone.contains("\"qaudion_busy_tone.wav\""), "a stale 3 s file must never be reused")
    }

    // MARK: - the badge

    /// Every wipe path runs `resetAccountScopedRuntimeState()`: the badge's mark is reset there, so the next account
    /// never inherits the previous account's. Fails if the line is dropped.
    func testTheAccountResetResetsTheMissedCallsMark() throws {
        let reset = try body(of: "func resetAccountScopedRuntimeState() {", in: try appCode())
        XCTAssertTrue(reset.contains("MissedCallsBadge.shared.resetForAccountChange()"),
                      "resetAccountScopedRuntimeState() must reset the Calls-tab mark")
    }

    /// The badge exists from launch, so the mark of a first run is the launch time (a missed call replayed right after
    /// start-up is counted).
    func testTheBadgeIsCreatedAtLaunch() throws {
        let code = try appCode()
        XCTAssertTrue(code.contains("_ = MissedCallsBadge.shared"))
        assertOrder(code, "NotificationCenterService.shared.flushPendingIncomingAction()", before: "_ = MissedCallsBadge.shared",
                    "created in the same start-up block that wires the notifications")
    }

    /// The Calls tab carries the missed-calls number, the Chats tab keeps the chat one, and the shell asks to move the
    /// mark when the Calls tab is selected and the app active.
    func testHomeViewShowsTheMissedCallsNumberOnTheCallsTab() throws {
        let home = try code("QAudionApp/Views/HomeView.swift")
        let callsItem = try slice(home, from: "callsTab .tabItem {", to: ".tag(Tab.calls)")
        XCTAssertTrue(callsItem.contains(".badge(missedCalls.unreadCount)"), "the Calls tab carries the missed-calls number")
        XCTAssertFalse(callsItem.contains("totalUnreadCount"), "never the chat number")
        let chatsItem = try slice(home, from: "chatsTab .tabItem {", to: ".tag(Tab.chats)")
        XCTAssertTrue(chatsItem.contains(".badge(totalUnreadCount)"), "the chat number stays on Chats")
        XCTAssertFalse(chatsItem.contains("missedCalls"))
        XCTAssertTrue(home.contains("@ObservedObject private var missedCalls = MissedCallsBadge.shared"))
        // the iPad sidebar
        XCTAssertTrue(home.contains("if tab == .calls, missedCalls.unreadCount > 0 {"))
    }

    func testHomeViewMovesTheMarkOnlyWhenTheCallsTabIsLookedAt() throws {
        let home = try code("QAudionApp/Views/HomeView.swift")
        let ask = try body(of: "private func markMissedCallsSeenIfLookedAt() {", in: home)
        XCTAssertTrue(ask.contains(
            "MissedCallsBadgeState.countsAsLookedAt( callsTabSelected: selectedTab == .calls, appActive: scenePhase == .active)"),
            "selected AND the app active")
        XCTAssertTrue(ask.contains("if lookedAt { missedCalls.markSeen() }"))
        for trigger in [
            ".onAppear { markMissedCallsSeenIfLookedAt() }",
            ".onChange(of: selectedTab) { _ in markMissedCallsSeenIfLookedAt() }",
            ".onChange(of: scenePhase) { _ in markMissedCallsSeenIfLookedAt() }",
            ".onChange(of: missedCalls.unreadCount) { _ in markMissedCallsSeenIfLookedAt() }",
        ] {
            XCTAssertTrue(home.contains(trigger), trigger)
        }
    }

    /// The history row and the notification of a call that reached a busy user: a `.missed` record, and the
    /// `.missedCall` category (its own thread), never the chat category.
    func testTheBusyRecipientGetsAMissedRowAndACallsNotificationNeverChat() throws {
        let missed = try slice(
            try appCode(), from: "private func handleMissedCallEvent(_ data: [String: Any], source: String) {",
            to: "private func handleIceRecoveryExhausted() {")
        XCTAssertTrue(missed.contains("PersistentCallRecordStore.shared.beginCall("))
        XCTAssertTrue(missed.contains("direction: .missed,"))
        XCTAssertTrue(missed.contains("category: .missedCall,"))
        XCTAssertFalse(missed.contains(".messageDelivered"), "never the chat category")
        let service = try code("QAudionApp/Services/NotificationCenterService.swift")
        XCTAssertTrue(service.contains("case missedCall = \"QAUDION_MISSED_CALL\""))
        XCTAssertTrue(service.contains("case messageDelivered = \"QAUDION_MESSAGE_DELIVERED\""))
        XCTAssertTrue(service.contains("content.threadIdentifier = category.rawValue"), "each category is its own thread")
    }

    // MARK: - what is a missed call (review of #196)

    /// A remote hangup / cancel asks the policy before it writes a missed row: a ring ended by the user's OTHER device
    /// (`answered_on_other_device` / `declined_on_other_device`) is not a missed call, and the record id is released
    /// only when `markMissed` really turned the row missed (an outgoing record stays, and `endCall` closes it).
    func testRemoteHangupAsksThePolicyBeforeItMarksAMissedCall() throws {
        let code = try appCode()
        let remote = try slice(
            code, from: "private func handleRemoteCallHangup(reasonString: String, viaServerCancel: Bool = false) {",
            to: "private func wireIncomingChatHandlers(on ws: BCryptoWebSocketClient) {")
        XCTAssertTrue(remote.contains(
            "let recordMissed: Bool = GhostCallPolicy.shouldRecordMissedOnRemoteHangup( wasRinging: wasRinging, reason: reasonString, viaServerCancel: viaServerCancel )"))
        XCTAssertTrue(remote.contains(
            "if recordMissed, let rid = missedRecordId, PersistentCallRecordStore.shared.markMissed(id: rid) { self.activeOutgoingRecordId = nil }"),
                      "the id is released only when the row became missed, so endCall still closes an outgoing record")
        XCTAssertFalse(remote.contains("if wasRinging, let rid"), "the ring flag alone no longer decides")
        XCTAssertEqual(occurrences(of: "markMissed(id:", in: code), 2,
                       "the two known writers: the remote hangup and the cancel push; a third must be reviewed")
    }

    /// Only the `call_cancel` router vouches for a sibling-device reason; the peer-written reason of a `call_hangup` or
    /// of an in-band hangup frame never does.
    func testOnlyTheCancelRouterVouchesForASiblingDeviceReason() throws {
        let code = try appCode()
        XCTAssertEqual(occurrences(of: "viaServerCancel: true", in: code), 1)
        let cancel = try slice(
            code, from: "private func routeCallCancel(envelopeCallId: String, reason: String?) {",
            to: "private func handleRemoteCallHangup(reasonString: String, viaServerCancel: Bool = false) {")
        XCTAssertTrue(cancel.contains(
            "handleRemoteCallHangup(reasonString: r.isEmpty ? \"timeout\" : r, viaServerCancel: true)"))
    }

    // MARK: - the quiet notification

    /// `willPresent` and `scheduleLocal` both ask the policy; the call-in-flight signal is read only for a missed call;
    /// no bare toggle read is left that could play the chime.
    func testThePresentationAndTheLocalContentAskThePolicy() throws {
        let service = try code("QAudionApp/Services/NotificationCenterService.swift")
        let present = try slice(
            service, from: "willPresent notification: UNNotification", to: "private func isCallInFlight() -> Bool {")
        XCTAssertTrue(present.contains("MissedCallAlertPolicy.foreground("))
        XCTAssertTrue(present.contains("isMissedCall: isMissedCall,"))
        XCTAssertTrue(present.contains(
            "let isMissedCall: Bool = notification.request.content.categoryIdentifier == Category.missedCall.rawValue"))
        XCTAssertTrue(present.contains("var callInFlight: Bool = false if isMissedCall { callInFlight = await self.isCallInFlight() }"),
                      "only a missed call needs the call state")
        XCTAssertFalse(present.contains("return [.banner, .sound, .list, .badge]"), "no bare chime path")
        let schedule = try slice(service, from: "func scheduleLocal(category: Category,", to: "func postIncomingCall(")
        XCTAssertTrue(schedule.contains("MissedCallAlertPolicy.localContentHasSound("))
        XCTAssertTrue(schedule.contains("isMissedCall: category == .missedCall,"))
        XCTAssertTrue(schedule.contains("content.sound = hasSound ? .default : nil"))
        XCTAssertFalse(schedule.contains("content.sound = NotificationsGate.inAppSoundEnabled ? .default : nil"),
                       "the content's sound goes through the policy")
        XCTAssertTrue(schedule.contains("content.categoryIdentifier = category.rawValue"), "the category is unchanged")
    }

    /// AppState wires "a call is in flight" with the app's own definition (`noCallInFlight`).
    func testAppStateWiresTheCallInFlightSignal() throws {
        let code = try appCode()
        let wiring = try slice(
            code, from: "NotificationCenterService.shared.callInFlightProvider = {", to: "_ = MissedCallsBadge.shared")
        XCTAssertTrue(wiring.contains("guard let self else { return false }"))
        XCTAssertTrue(wiring.contains("return !self.noCallInFlight()"))
    }
}
