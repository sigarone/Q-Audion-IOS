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

    /// The source file was not found: the test FAILS (it never skips). A silently skipped invariant is the failure
    /// this file exists to prevent.
    private struct SourceNotFound: Error, CustomStringConvertible {
        let path: String
        var description: String { "source file not found: \(path)" }
    }

    /// `relativePath` (from the repository root), line comments stripped and every run of whitespace collapsed to one
    /// space. A missing file is `XCTFail` and a thrown error, never `XCTSkip`.
    private func code(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
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
        XCTFail("\(relativePath) not found from \(file): the wiring invariants cannot run", file: file, line: line)
        throw SourceNotFound(path: relativePath)
    }

    /// `QAudionApp/AppState.swift`.
    private func appCode() throws -> String { try code("QAudionApp/AppState.swift") }

    /// `QAudionApp/Views/ContentView.swift`.
    private func contentViewCode() throws -> String { try code("QAudionApp/Views/ContentView.swift") }

    /// `QAudionEngine/Sources/QAudionEngine/Integration/CallKitProvider.swift`.
    private func callKitProviderCode() throws -> String {
        try code("QAudionEngine/Sources/QAudionEngine/Integration/CallKitProvider.swift")
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
        XCTAssertTrue(body.contains("let stillCurrent: Bool = isCurrentOutgoingCall(wireCallId: wireCallId)"),
                      "'current' is decided by the one helper every post-await decision of startCall's Task uses")
        let helper = try slice(
            try appCode(), from: "private func isCurrentOutgoingCall(wireCallId: String) -> Bool {",
            to: "private func outgoingFallbackActivationAllowed(")
        XCTAssertTrue(helper.contains("isInCall && acceptLatch.isCurrentOutgoingCall(envelopeCallId: wireCallId)"),
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

    // MARK: - review of #169, item 2: nothing goes to the peer

    /// `endCall` announces nothing for a busy / unreachable callee on EVERY send path: the in-band control frame, the
    /// WS `call_hangup` + opaque `HANGUP` (no-controller path), and `sendHangupAndClose()` (controller path, which
    /// becomes a plain close). The bound call id is dropped locally instead, after its last read.
    func testEndCallAnnouncesNothingToThePeerForABusyOrUnreachableCallee() throws {
        let body = try slice(
            try appCode(),
            from: "func endCall(notifyPeerInBand: Bool = true, outcome: CallerTerminalOutcome? = nil) {",
            to: "func promoteToGroupCall(newPeerIds:")
        XCTAssertTrue(body.contains("let announcesToPeer: Bool = outcome?.sendsHangupToPeer ?? true"))
        XCTAssertTrue(
            body.contains("if notifyPeerInBand && announcesToPeer { callService.sendControlHangup(reason: \"local_hangup\") }"),
            "the in-band control frame is gated by the outcome too")
        XCTAssertTrue(
            body.contains("if announcesToPeer, let peer = callContactId, let provider = liveProvider, webRtcController == nil {"),
            "the WS call_hangup + opaque HANGUP path is gated by the outcome")
        XCTAssertEqual(body.components(separatedBy: "sendHangup(recipientId:").count - 1, 1,
                       "one hangup send in the teardown, and it is the gated one")
        assertOrder(
            body, "if announcesToPeer, let peer = callContactId", before: "provider.callingApi.sendHangup(recipientId: peer)",
            "the send is inside the gate")
        XCTAssertTrue(
            body.contains("if announcesToPeer { ctrl.sendHangupAndClose() } else { ctrl.closeSynchronously() }"),
            "with a controller, busy / unreachable only closes the peer connection")
        XCTAssertEqual(body.components(separatedBy: "sendHangupAndClose()").count - 1, 1)
        XCTAssertTrue(
            body.contains("if !announcesToPeer, let endedId = endCallId, let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl { impl.unbindActiveCallId(matching: endedId) }"),
            "nothing was sent, so the bound call id is dropped locally (a hangup would have cleared it)")
        assertOrder(
            body, "CallMediaTelemetry.shared.recordEnded(", before: "impl.unbindActiveCallId(matching: endedId)",
            "every read of the bound id (telemetry, key-confirmation state) happens before it is dropped")
        // The W564 post-call key exchange: `ContactKeyExchange.initiate(force: false)` always sends an opaque
        // KEY_EXCHANGE_OFFER, so for a busy / unreachable callee (in another call, or offline) it is gated too.
        XCTAssertTrue(
            body.contains("if announcesToPeer, let peer = callContactId { triggerKeyExchange(with: peer) }"),
            "the post-call key exchange offer is gated by the outcome")
        XCTAssertFalse(
            body.contains("if let peer = callContactId { triggerKeyExchange(with: peer) }"),
            "the ungated post-call key exchange must not come back")
        XCTAssertEqual(body.components(separatedBy: "triggerKeyExchange(with:").count - 1, 1,
                       "one key exchange trigger in the teardown, and it is the gated one")
        assertOrder(
            body, "if announcesToPeer, let peer = callContactId { triggerKeyExchange(with: peer) }",
            before: "callContactId = nil",
            "the offer reads the contact before the teardown clears it")
    }

    // MARK: - review of #169, item 3: the guard is call-scoped

    func testTheEndCallGuardIsTheCallScopedLatch() throws {
        let code = try appCode()
        XCTAssertTrue(code.contains("private var teardownLatch = CallTeardownLatch()"))
        XCTAssertTrue(code.contains("private var isEndingCall: Bool { teardownLatch.inFlight }"))
        XCTAssertFalse(code.contains("isEndingCall = "),
                       "the guard is only ever entered through the latch: no flag assignment may come back")
        let body = try slice(
            code, from: "func endCall(notifyPeerInBand: Bool = true, outcome: CallerTerminalOutcome? = nil) {",
            to: "func promoteToGroupCall(newPeerIds:")
        XCTAssertTrue(body.contains("guard let teardownToken = teardownLatch.begin() else { return }"))
        XCTAssertTrue(body.contains("self.teardownLatch.release(token: teardownToken)"),
                      "the 0.3 s timer releases only the guard of ITS teardown")
    }

    func testStartCallAdmitsTheNewCallToTheLatchBeforeItsStateMoves() throws {
        let body = try slice(
            try appCode(), from: "func startCall(contactId: String, video: Bool = false) async {",
            to: "var sharedOutgoingCallId: String = \"\"")
        assertOrder(
            body, "acceptLatch.beginOutgoing(callId: nativeSrtpOutgoingCallId)", before: "teardownLatch.newCallAdmitted()",
            "the call is the current one first")
        assertOrder(
            body, "teardownLatch.newCallAdmitted()", before: "callState = .connecting",
            "the previous call's guard is gone before this call can be torn down")
    }

    func testTheTerminalHandlerReadsTheCallScopedGuard() throws {
        let body = try slice(
            try appCode(), from: "private func endOutgoingCallAfterTerminalEnvelope(",
            to: "private func showCallerOutcome(")
        XCTAssertTrue(body.contains("let hangupInFlight = teardownLatch.inFlight"))
        XCTAssertFalse(body.contains("= isEndingCall"), "not the bare flag: a redial inside the window would inherit it")
    }

    // MARK: - review of #169, item 4: every branch of startCall's CallKit Task is gated

    func testEveryFallbackBranchOfTheCallKitTaskAsksThePolicy() throws {
        let code = try appCode()
        let helper = try slice(
            code, from: "private func outgoingFallbackActivationAllowed(", to: "private func settleOutgoingCallKitStart(")
        XCTAssertTrue(helper.contains("OutgoingCallKitStartPolicy.decideFallback(callStillCurrent: current)"))
        XCTAssertTrue(helper.contains("let current: Bool = isCurrentOutgoingCall(wireCallId: wireCallId)"))

        let body = try slice(
            code, from: "func startCall(contactId: String, video: Bool = false) async {",
            to: "var sharedOutgoingCallId: String = \"\"")
        let marker = "callService.handleAudioSessionActivated()"
        let segments = body.components(separatedBy: marker)
        XCTAssertEqual(segments.count - 1, 3, "the three fallback branches (CallKit-free, nil, throw) activate the call's audio")
        guard segments.count == 4 else { return }
        for n in 1...3 {
            XCTAssertTrue(
                segments[n - 1].contains("guard self.outgoingFallbackActivationAllowed(wireCallId: nativeSrtpOutgoingCallId, site: \(n)) else { return }"),
                "branch \(n) must ask the policy before it activates the audio")
        }
        XCTAssertEqual(
            body.components(separatedBy: "outgoingFallbackActivationAllowed(wireCallId: nativeSrtpOutgoingCallId").count - 1,
            3, "one gate per branch, the success branch has its own (settleOutgoingCallKitStart)")
        // CallKit-free mode: the local id is stored only when the call is still current.
        assertOrder(
            body, "outgoingFallbackActivationAllowed(wireCallId: nativeSrtpOutgoingCallId, site: 1)",
            before: "self.activeCallKitId = localId", "no ended call gets a stale local id")
    }

    // MARK: - review of #169, item 1: the late activation

    /// `activateAudioSession` marks and announces its activation only through the ledger's atomic check; an activation
    /// that lands after the call ended is balanced on the spot and announces nothing.
    func testALateActivationIsBalancedAndAnnouncesNothing() throws {
        let body = try slice(
            try callKitProviderCode(),
            from: "private func activateAudioSession(logSite: String, source: AudioSessionActivationSource, uuid: UUID?) async {",
            to: "public func providerDidReset(")
        XCTAssertTrue(body.contains("switch ledger.markAudioSelfActivatedUnlessEnded(uuid) {"))
        XCTAssertFalse(body.contains("ledger.markAudioSelfActivated(uuid)"),
                       "the unconditional mark is what let a late activation go unbalanced")
        let owed = try slice(body, from: "case .owed:", to: "case .callAlreadyEnded:")
        XCTAssertTrue(owed.contains("onAudioSessionActivated?(source)"), "an open call hears its activation, as before")
        let ended = try slice(body, from: "case .callAlreadyEnded:", to: "let nsErr = error as NSError")
        XCTAssertTrue(ended.contains("try rtcSession.setActive(false)"), "balanced at once with the counted API")
        XCTAssertFalse(ended.contains("onAudioSessionActivated"),
                       "no onAudioSessionActivated after the call ended: it would pre-satisfy the redial's W464 gate")
        XCTAssertFalse(ended.contains("handleAudioSessionActivated"))
        XCTAssertTrue(ended.contains("rtcSession.unlockForConfiguration()"))
        XCTAssertTrue(ended.contains("return"))
    }

    /// The end report records the ended call (inside `consumeEndBalance`) BEFORE it tells CallKit.
    func testTheEndReportRecordsTheEndedCall() throws {
        let body = try slice(
            try callKitProviderCode(), from: "public func reportCallEnded(uuid: UUID, reason: CallEndReason) async {",
            to: "public func endAllOutstanding(")
        assertOrder(
            body, "ledger.consumeEndBalance(uuid)", before: "provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)",
            "the ended mark is in place before CallKit hears about the end")
    }

    // MARK: - review of #169, item 5: the busy tone

    func testTheBusyToneStopsWhenAnIncomingCallRingsOrIsAnswered() throws {
        let code = try appCode()
        XCTAssertTrue(
            code.contains("@Published var incomingCallRingVisible: Bool = false { didSet { if incomingCallRingVisible { callerBusyTone.stop() } } }"),
            "an incoming 1:1 ring silences the tone")
        let ring = try slice(code, from: "func startInAppRingtone() {", to: "func stopInAppRingtone() {")
        assertOrder(ring, "callerBusyTone.stop()", before: "guard ringtoneTimer == nil",
                    "any ring (1:1 or group) silences it, whether or not a ring timer is already up")
        XCTAssertTrue(
            code.contains("private func performAcceptIncoming(uuid: UUID, dismissNativeUI: Bool) -> Bool { callerBusyTone.stop()"),
            "answering a 1:1 call, on any path, silences it")
        XCTAssertTrue(
            code.contains("callerBusyTone.stop() stopInAppRingtone() markGroupCallHandled(invite.callId)"),
            "answering a group call silences it")
        let dismiss = try slice(code, from: "func dismissCallerOutcome() {", to: "private func isCurrentOutgoingCall(")
        XCTAssertTrue(dismiss.contains("callerBusyTone.stop()"), "startCall and the close button stop it")
    }

    /// The tone is played for a busy outcome only, by the outcome screen's own showing.
    func testTheBusyToneIsPlayedOnlyForABusyOutcome() throws {
        let body = try slice(
            try appCode(), from: "private func showCallerOutcome(", to: "func dismissCallerOutcome() {")
        XCTAssertTrue(body.contains("if outcome.playsBusyTone { callerBusyTone.play() }"))
        assertOrder(body, "callerOutcome = outcome", before: "callerBusyTone.play()",
                    "the screen is up when the tone starts")
    }

    // MARK: - review of #169, item 7: the outcome screen and the identity it must not leak

    func testTheOutcomeScreenSitsBetweenTheCallStackAndTheSplash() throws {
        let code = try contentViewCode()
        XCTAssertTrue(
            code.contains("if appState.isInCall { inCallStack } else if let outcome = appState.callerOutcome { callerOutcomeScreen(outcome) } else if !splashResolved {"),
            "an in-call state always wins; the outcome replaces Home, not a live call")
    }

    func testTheOutcomeScreenIsTheEndedOutgoingScreenWithACloseButton() throws {
        let body = try slice(
            try contentViewCode(),
            from: "private func callerOutcomeScreen(_ outcome: CallerTerminalOutcome) -> OutgoingCallScreen {",
            to: "private func makeOutgoingScreen()")
        XCTAssertTrue(body.contains("state: .ended"))
        XCTAssertTrue(body.contains("errorMessage: CallerOutcomeText.message(for: outcome)"))
        XCTAssertTrue(body.contains("onHangup: { appState.dismissCallerOutcome() }"),
                      "the close button dismisses the outcome (and its tone) at once")
    }

    func testTheDialledIdentityIsClearedWhenTheOutcomeScreenEnds() throws {
        let code = try contentViewCode()
        XCTAssertTrue(
            code.contains(".onChange(of: appState.callerOutcome) { outcome in if outcome == nil { resolveOutgoingName(appState.callContactId) } }"),
            "when the outcome is gone the three outgoing-identity values are re-resolved: cleared, or the redial's")
        XCTAssertTrue(code.contains("if id == nil, appState.callerOutcome != nil { return } resolveOutgoingName(id)"),
                      "the outcome screen itself still shows whom it dialled")
        let resolve = try slice(
            code, from: "private func resolveOutgoingName(_ contactId: String?) {", to: "outgoingResolvedFor = id")
        XCTAssertTrue(
            resolve.contains("outgoingDisplayName = \"\" outgoingShortNumber = nil outgoingAvatarUrl = nil outgoingResolvedFor = nil"),
            "clearing clears the scope too")
    }

    func testTheIncomingRingNeverTakesTheOutgoingIdentityOfAnotherPerson() throws {
        let body = try slice(
            try contentViewCode(), from: "private func incoming1to1CallScreen() -> some View {",
            to: "onAccept: { audioOnly in appState.answerIncomingCall(audioOnly: audioOnly) }")
        XCTAssertTrue(body.contains("PeerNameScope.matches( resolvedFor: outgoingResolvedFor, callContactId: appState.callContactId)"))
        XCTAssertTrue(body.contains("PeerNameScope.incomingRingName("))
        XCTAssertTrue(body.contains("avatarUrl: resolvedIsThisCallers ? outgoingAvatarUrl : nil"))
        XCTAssertTrue(body.contains("peerShortNumber: resolvedIsThisCallers ? outgoingShortNumber : nil"))
        XCTAssertFalse(body.contains("avatarUrl: outgoingAvatarUrl"), "no unscoped avatar")
        XCTAssertFalse(body.contains("peerShortNumber: outgoingShortNumber"), "no unscoped short number")
        XCTAssertFalse(body.contains("outgoingDisplayName.isEmpty ?"), "no unscoped name preference")
    }
}
