import XCTest

/// Source invariants of the call hold wiring (WIRE_SPEC 16): the app target has no unit-test host for `CallService` and
/// `AppState`, so the rules that must not drift are pinned on the text.
final class CallHoldWiringTests: XCTestCase {

    private struct SourceNotFound: Error { let path: String }

    private func code(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
                let stripped = raw
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
                return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        throw SourceNotFound(path: relativePath)
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let s = try XCTUnwrap(text.range(of: start), "missing \(start)")
        let rest = text[s.lowerBound...]
        let e = try XCTUnwrap(rest.range(of: end), "missing \(end)")
        return String(rest[rest.startIndex..<e.lowerBound])
    }

    func testTheSendPathSealsEveryLegAndNeverWritesTheUnsealedOuterOffFrame() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        let body = try slice(service, from: "private func sendHoldControl(", to: "private func consumeHoldControlFrame(")
        XCTAssertTrue(body.contains("HoldLegPolicy.select("), "legs come from the pure policy")
        XCTAssertTrue(body.contains("outerTx(frame, integration: integration)"), "every leg goes through the single seal site")
        XCTAssertTrue(body.contains("guard out.relayAllowed, outer == .sealed"), "the relay only when the call is SEALED")
        XCTAssertFalse(body.contains("outerOffFrame"), "the unsealed outer-off write is forbidden for the hold kinds")
        XCTAssertFalse(body.contains("sendControlHangup"))
        XCTAssertEqual(body.components(separatedBy: "ws.sendAudioFrame(").count - 1, 1, "one relay write, under the sealed guard")
    }

    func testTheHoldKindsAreGatedOnTheirOwnTagAndNeverOnDcHangup() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        let gate = try slice(service, from: "private func peerHasCallHoldTag()", to: "private func holdOuterState()")
        XCTAssertTrue(gate.contains("CallCapabilities.callHoldV1"))
        XCTAssertFalse(gate.contains("dcHangupV1"))
    }

    func testBothReceivePathsPassTheLegAndRouteTheHoldKinds() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        XCTAssertTrue(service.contains("consumeInboundControlFrame(inner, leg: entry.leg, authenticated: innerAuthenticated)"))
        XCTAssertTrue(service.contains("self.consumeInboundControlFrame(inner, leg: leg, authenticated: innerAuthenticated)"))
        XCTAssertTrue(service.contains("kind == WireRelayFrameCodec.controlKindCallHold || kind == WireRelayFrameCodec.controlKindCallHoldAck"))
        XCTAssertTrue(service.contains("route: leg == .dataChannel ? .replyDc : .replyRelay"), "an ACK follows the leg of its frame")
    }

    func testAHeldSenderFeedsNoAudioOnEitherPath() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        let tx = try slice(service, from: "private func processAndSendEncryptedFrame(", to: "let frameToProcess")
        XCTAssertTrue(tx.contains("guard !holdLocalActive else { return }"), "sealed-frame path: no frame at all")
        XCTAssertTrue(service.contains("localHold: holdLocalActive"), "native SRTP path: the outbound track is disabled")
        let remove = try slice(service, from: "func holdRemoveCause(", to: "func holdSetSystemHold(")
        let resumedFirst = try XCTUnwrap(remove.range(of: "guard sender.removeCause(cause) else { return }"))
        let afterResumed = String(remove[resumedFirst.upperBound...])
        XCTAssertTrue(afterResumed.contains("holdLocalActive = false"), "RESUMED is written before audio restarts")
    }

    func testTheSilenceWatchdogAsksTheHoldGateAndTheSessionTriggersAreWired() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        XCTAssertTrue(service.contains("holdSilenceGate.step(peerHeld: self.holdReceiver.held)"))
        XCTAssertTrue(service.contains("public func handleAudioSessionActivated(source: AudioSessionActivationSource = .selfManaged) { holdNoteSessionActivated()"))
        XCTAssertEqual(service.components(separatedBy: "holdNoteSessionDeactivated(pairedGeneration:").count - 1, 3, "two call sites and the definition")
        let app = try code("QAudionApp/AppState.swift")
        let hold = try slice(app, from: "provider.onHoldChanged = {", to: "provider.onAudioSessionActivated = {")
        XCTAssertTrue(hold.contains("self.callService.holdSetSystemHold(isOnHold)"))
    }

    func testTheStaleDeactivationCheckRunsBeforeTheDebounceOnBothBranches() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        let helper = try slice(service, from: "private func holdNoteSessionDeactivated(pairedGeneration: Int?)", to: "private func holdNoteSessionActivated()")
        XCTAssertTrue(helper.contains("callKitDeactivationOwner("))
        let check = try XCTUnwrap(helper.range(of: "guard owner != .endedCall else { return }"))
        let arm = try XCTUnwrap(helper.range(of: "triggers.sessionDeactivated()"))
        XCTAssertLessThan(check.lowerBound, arm.lowerBound)
        XCTAssertEqual(service.components(separatedBy: "holdNoteSessionDeactivated(pairedGeneration: pairedGeneration)").count - 1, 2,
                       "native and non-native branch")
    }

    func testVideoFollowsTheFirstAndLastHoldCauseNotTheCallKitAction() throws {
        let app = try code("QAudionApp/AppState.swift")
        let hold = try slice(app, from: "provider.onHoldChanged = {", to: "provider.onAudioSessionActivated = {")
        XCTAssertFalse(hold.contains("videoSetCameraEnabled"), "the CallKit handler no longer decides video")
        XCTAssertTrue(app.contains("callService.onLocalHoldActiveChanged = {"))
        let service = try code("QAudionApp/Services/CallService.swift")
        XCTAssertTrue(service.contains("if ensureHoldSender().addCause(cause) { onLocalHoldActiveChanged?(true) }"))
        XCTAssertTrue(service.contains("onLocalHoldActiveChanged?(false)"))
    }

    func testAHoldFrameActsOnlyOnTheDecisionMadeForThatFrame() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        let body = try slice(service, from: "private func consumeHoldControlFrame(", to: "private func startHoldTicker()")
        XCTAssertTrue(body.contains("guard authenticated, peerHasCallHoldTag() else {"))
        XCTAssertFalse(body.contains("relaySealerRecv"), "the sealer slot is never re-read after the frame was processed")
        XCTAssertFalse(body.contains("currentOuterMode"), "nor the mode")
        let rx = try slice(service, from: "private func outerRx(", to: "private func holdForSealer(")
        XCTAssertTrue(rx.contains("HoldRxTrust.frameIsAuthenticated(rx: decision"))
        XCTAssertEqual(rx.components(separatedBy: "relaySealerRecv").count - 1, 1, "one reading of the slot per frame")
        XCTAssertTrue(rx.contains("unsealRelayFrame(data, with: sealer)"))
        XCTAssertEqual(service.components(separatedBy: "authenticated: innerAuthenticated)").count - 1, 2, "both receive paths")
    }

    func testASystemHoldBeforeTheCallIsActiveStillPausesVideoAndMutes() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        let add = try slice(service, from: "func holdAddCause(", to: "func holdRemoveCause(")
        let pending = try XCTUnwrap(add.range(of: "holdPendingCauses.append(cause)"))
        let video = try XCTUnwrap(add.range(of: "onLocalHoldActiveChanged?(true)"))
        XCTAssertLessThan(pending.lowerBound, video.lowerBound)
        XCTAssertTrue(add.contains("reapplyNativeSenderMute(site: 7)"))
        XCTAssertTrue(service.contains("holdFlushPendingCauses()"), "CALL_HOLD goes out when the call becomes active")
    }

    func testEveryOutboundVideoPathIsGatedByTheHeldFlag() throws {
        let app = try code("QAudionApp/AppState.swift")
        // the only raw unpause is the one inside the deferral helper; consent, caller initial video, finalise, the
        // post-consent start and the promotion all go through it
        XCTAssertEqual(app.components(separatedBy: "setVideoPaused(false)").count - 1, 2,
                       "the helper, and the application of a deferred unpause on release")
        for site in ["unpauseOutboundVideo(videoPipeline)", "unpauseOutboundVideo(startedPipeline)",
                     "self.unpauseOutboundVideo(self.videoPipeline)", "unpauseOutboundVideo(newPipeline)"] {
            XCTAssertTrue(app.contains(site), site)
        }
        let share = try slice(app, from: "public func startScreenShare() async {", to: "guard isInCall else")
        XCTAssertTrue(share.contains("OutboundVideoGate.mayStartScreenShare(locallyHeld: callService.isLocalHeld)"))
        let camera = try slice(app, from: "func setCamera(_ enabled: Bool) {", to: "videoPipeline?.setCameraEnabled(enabled)")
        XCTAssertTrue(camera.contains("OutboundVideoGate.mayEnableCamera(locallyHeld: callService.isLocalHeld)"))
        let toggle = try slice(app, from: "func videoSetCameraEnabled(_ enabled: Bool) {", to: "videoPipeline?.setCameraEnabled(enabled)")
        XCTAssertTrue(toggle.contains("OutboundVideoGate.mayEnableCamera(locallyHeld: callService.isLocalHeld)"))
        XCTAssertTrue(app.contains("pipeline.isLocalHeld = { [weak self] in self?.callService.isLocalHeld ?? false }"))
        XCTAssertTrue(app.contains("if self.videoUnpauseDeferral.released() { self.videoPipeline?.setVideoPaused(false) }"), "restore after release")
    }

    func testThePipelineDropsCameraAndExternalFramesThroughTheHeldGate() throws {
        let pipeline = try code("QAudionApp/Services/VideoCallPipeline.swift")
        XCTAssertEqual(pipeline.components(separatedBy: "OutboundVideoGate.drops(paused: self.paused, locallyHeld: self.isLocalHeld?() ?? false)").count - 1, 2,
                       "captureOutput and submitExternalFrame")
        let service = try code("QAudionApp/Services/CallService.swift")
        XCTAssertTrue(service.contains("public var isLocalHeld: Bool { holdLocalActive }"), "pending causes included")
    }

    func testTheToneOnlyPlaysOnAnActiveSession() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        XCTAssertTrue(service.contains("if audioSessionActive, HoldToneSynth.due("))
    }

    func testNoTransientRouteChangeIsAHoldTrigger() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        let hold = try slice(service, from: "private func startHoldTicker()", to: "private func resetHoldState()")
        XCTAssertFalse(hold.contains("routeChangeNotification"))
        XCTAssertTrue(hold.contains("AVAudioSession.interruptionNotification"))
    }
}
