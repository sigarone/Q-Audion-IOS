import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03, review of #169) — the WIRING of the busy / peer-offline teardown in `AppState`.
///
/// `CallerBusyTeardownTests` and `OutgoingCallKitStartPolicyTests` pin the pure pieces (the outcome, the latch, the
/// CallKit decision). What they cannot see is whether `AppState` still uses them: the original defect was the two
/// handlers tearing the call down by hand instead of through `AppState.endCall`, which left the CallKit outgoing call,
/// the call record and the ring-back timer open. `AppState` cannot be driven here (CallKit, live provider,
/// WebSocket), so these are SOURCE INVARIANTS, the same choice `EarbudRetiredWiringTests` and
/// `MediaReadyRoutingTests` make: reverting the handlers, the `endCall` outcome plumbing or the late-CallKit-start
/// settle fails one of them. Comments are stripped and whitespace collapsed before matching, so only code counts.
final class CallerBusyWiringTests: XCTestCase {

    // MARK: - reading the source

    /// `QAudionApp/AppState.swift`, line comments stripped and every run of whitespace collapsed to one space.
    private func appCode() throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("QAudionApp/AppState.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                let withoutComments = raw
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        throw XCTSkip("QAudionApp/AppState.swift not found from \(#filePath)")
    }

    /// The text from the first `start` to the next `end` after it. Both markers must exist: a refactor that moves
    /// them must update this test, never silently stop checking.
    private func slice(
        _ code: String, from start: String, to end: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let s = try XCTUnwrap(code.range(of: start), "marker not found: \(start)", file: file, line: line)
        let e = try XCTUnwrap(
            code.range(of: end, range: s.upperBound..<code.endIndex),
            "end marker not found after \(start): \(end)", file: file, line: line)
        return String(code[s.lowerBound..<e.lowerBound])
    }

    private func assertOrder(
        _ body: String, _ first: String, before second: String, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let a = body.range(of: first) else {
            return XCTFail("missing: \(first)", file: file, line: line)
        }
        guard let b = body.range(of: second) else {
            return XCTFail("missing: \(second)", file: file, line: line)
        }
        XCTAssertLessThan(a.lowerBound, b.lowerBound, message, file: file, line: line)
    }

    // MARK: - the two handlers

    /// After the id gate (unchanged), a terminal envelope ends the call through `endOutgoingCallAfterTerminalEnvelope`
    /// and does nothing by hand: no `callService.endCall()`, no manual state reset (the old copy that bypassed
    /// `AppState.endCall`).
    private func assertTerminalHandler(
        _ body: String, kind: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertOrder(
            body,
            "self.callerTerminalEnvelopeEndsCall(\(kind), envelopeCallId: envelopeCallId)",
            before: "self.endOutgoingCallAfterTerminalEnvelope(\(kind), envelopeCallId: envelopeCallId)",
            "the id gate runs first; only what follows it is the teardown", file: file, line: line)
        for forbidden in [
            "callService.endCall()", "callState =", "isInCall =", "callContactId =", "errorMessage",
            "CallMediaTelemetry", "clearKeyConfirmationState", "acceptLatch",
        ] {
            XCTAssertFalse(
                body.contains(forbidden),
                "the handler must not hand-roll the teardown (\(forbidden)): it goes through AppState.endCall",
                file: file, line: line)
        }
    }

    func testTheBusyHandlerTearsDownThroughTheOneEndCall() throws {
        let body = try slice(try appCode(), from: "ws.onCallBusy = {", to: "ws.onCallCancel = {")
        assertTerminalHandler(body, kind: ".busy")
    }

    func testThePeerOfflineHandlerTearsDownThroughTheOneEndCall() throws {
        let body = try slice(try appCode(), from: "ws.onCallPeerOffline = {", to: "ws.onCallBusy = {")
        assertTerminalHandler(body, kind: ".peerOffline")
    }

    // MARK: - the teardown helper

    /// The helper runs `AppState.endCall(notifyPeerInBand: false, outcome:)`, keeps the #160 deferred-idle settle, and
    /// never touches the accept latch: the gate and `endCall` are the only paths that reset it, so
    /// `testTheTerminalTeardownResetsExactlyOnce` keeps holding.
    func testTheTeardownHelperRunsEndCallWithTheOutcomeAndKeepsTheSettle() throws {
        let body = try slice(
            try appCode(), from: "private func endOutgoingCallAfterTerminalEnvelope(",
            to: "private func showCallerOutcome(")
        XCTAssertTrue(body.contains("endCall(notifyPeerInBand: false, outcome: outcome)"),
                      "the busy / peer-offline teardown is AppState.endCall with the outcome, announcing nothing to the peer")
        XCTAssertTrue(body.contains("CallerOutgoingStatePolicy.shouldSettleToIdle("),
                      "the 1 s deferred-idle settle of #160 stays")
        XCTAssertFalse(body.contains("acceptLatch"), "no second reset of the accept latch")
        XCTAssertFalse(body.contains("callerTerminalEnvelopeEndsCall"), "the id gate runs once, in the handler")
        XCTAssertFalse(body.contains("callService.endCall()"), "no hand-rolled teardown")
        assertOrder(
            body, "callerTerminalEnd = CallerTerminalEndRecord(", before: "endCall(notifyPeerInBand: false, outcome: outcome)",
            "how the call ended is remembered before the teardown, for a CallKit start that returns after it")
        assertOrder(
            body, "endCall(notifyPeerInBand: false, outcome: outcome)", before: "showCallerOutcome(outcome)",
            "the outcome screen is shown after the call is torn down")
    }

    // MARK: - endCall

    /// `AppState.endCall` reports the outcome's reason to CallKit (never `.userEnded` for busy / peer offline), and
    /// closes the call record and the telemetry with the outcome's token.
    func testEndCallReportsTheOutcomeToCallKitTheRecordAndTheTelemetry() throws {
        let body = try slice(
            try appCode(),
            from: "func endCall(notifyPeerInBand: Bool = true, outcome: CallerTerminalOutcome? = nil) {",
            to: "callService.endCall()")
        XCTAssertTrue(body.contains("let callKitEndReason: CallEndReason = outcome?.callKitEndReason ?? .userEnded"))
        XCTAssertTrue(body.contains("reportCallEnded(uuid: uuid, reason: callKitEndReason)"),
                      "CallKit hears the outcome's reason")
        XCTAssertFalse(body.contains("reportCallEnded(uuid: uuid, reason: .userEnded)"),
                       "a busy / unreachable callee is not reported as a local hangup")
        XCTAssertTrue(body.contains("callEndAttrs[\"end_reason\"] = outcome.closeToken"))
        XCTAssertTrue(body.contains("closeReason: closeReason?.rawValue ?? outcome?.closeToken"),
                      "the call record closes as busy / peer_offline")
    }

    // MARK: - startCall

    /// A redial clears the outcome screen and the busy tone before it admits anything.
    func testStartCallDismissesTheOutcomeBeforeAdmittingTheCall() throws {
        let body = try slice(
            try appCode(), from: "func startCall(contactId: String, video: Bool = false) async {",
            to: "var sharedOutgoingCallId: String = \"\"")
        assertOrder(
            body, "acceptLatch.beginOutgoing(callId: nativeSrtpOutgoingCallId)", before: "dismissCallerOutcome()",
            "the call is the current one before its outcome screen is cleared")
        assertOrder(
            body, "dismissCallerOutcome()", before: "callState = .connecting",
            "the previous outcome and its tone are gone before this call's own cues can start")
    }

    /// The CallKit start result is never assigned straight to `activeCallKitId`: it goes through
    /// `settleOutgoingCallKitStart`, which closes the late CallKit call of a call that ended while CallKit was
    /// starting it (the incident: busy at +577 ms, CallKit start fulfilled at ~+691 ms).
    func testTheCallKitStartResultGoesThroughTheLateStartSettle() throws {
        let body = try slice(
            try appCode(), from: "func startCall(contactId: String, video: Bool = false) async {",
            to: "var sharedOutgoingCallId: String = \"\"")
        XCTAssertTrue(body.contains("callKit?.startOutgoingCall(handle: peerDisplayName, hasVideo: hasVideo)"))
        XCTAssertTrue(
            body.contains("await self.settleOutgoingCallKitStart(uuid: uuid, wireCallId: nativeSrtpOutgoingCallId)"),
            "the CallKit start result must be settled against the call it was issued for")
        XCTAssertFalse(
            body.contains("self.activeCallKitId = uuid"),
            "activeCallKitId must not be assigned from the CallKit start result without the check: "
                + "a busy that landed first would be re-orphaned")
    }

    /// `settleOutgoingCallKitStart`: adopt while the call is current; otherwise remember it as ended, report it to
    /// CallKit with the outcome's reason and run the reaper when the app is idle.
    func testTheLateStartSettleAdoptsOnlyTheCurrentCallAndEndsTheRest() throws {
        let body = try slice(
            try appCode(), from: "private func settleOutgoingCallKitStart(", to: "func routeCallCancel(")
        XCTAssertTrue(body.contains("isInCall && acceptLatch.isCurrentOutgoingCall(envelopeCallId: wireCallId)"),
                      "'current' is: in a call, and the latch still names this call's wire id")
        XCTAssertTrue(body.contains("callerTerminalEnd?.outcome(forCallId: wireCallId)"),
                      "the late report uses how THIS call ended")
        XCTAssertTrue(
            body.contains("OutgoingCallKitStartPolicy.decide(callStillCurrent: stillCurrent, endedBy: endedBy)"))
        assertOrder(body, "case .adopt: activeCallKitId = uuid", before: "case .endAtOnce(let reason):",
                    "adopt first, then the ended branch")
        XCTAssertEqual(body.components(separatedBy: "activeCallKitId = uuid").count - 1, 1,
                       "the uuid is stored in the adopt case only")
        XCTAssertTrue(body.contains("recentlyEndedCallIds.recordEnded(uuid)"), "W-GHOSTCALL: the late uuid cannot be revived")
        XCTAssertTrue(body.contains("await callKit?.reportCallEnded(uuid: uuid, reason: reason)"))
        assertOrder(body, "reportCallEnded(uuid: uuid, reason: reason)", before: "noCallInFlight()",
                    "the reaper re-reads the app's state after the await")
        XCTAssertTrue(body.contains("endAllOutstanding()"))
        XCTAssertFalse(body.contains(".failed"), "nothing failed: busy / peer offline are not failures")
    }
}
