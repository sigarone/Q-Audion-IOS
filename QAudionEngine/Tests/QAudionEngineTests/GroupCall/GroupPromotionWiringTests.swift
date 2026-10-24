import XCTest
@testable import QAudionEngine

/// The app side of the 1:1 promotion and admission rules (docs/GROUP_CALLS_V2_SPEC.md 27-31),
/// pinned as source invariants: the app target has no unit-test host for `AppState`, so the
/// places where it calls the pure rules of `GroupPromotionPolicies` are read from the source. The
/// rules themselves are tested in `GroupPromotionPoliciesTests`.
final class GroupPromotionWiringTests: XCTestCase {

    // MARK: helpers

    private struct SourceNotFound: Error { let path: String }

    private func sourceURL(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("\(relativePath) not found from \(file): the source invariants cannot run", file: file, line: line)
        throw SourceNotFound(path: relativePath)
    }

    /// The file with line comments stripped and every run of whitespace collapsed to one space.
    private func code(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        // A checkout with CRLF line ends (one grapheme in Swift) reads like one with LF.
        let raw = try String(contentsOf: try sourceURL(relativePath, file: file, line: line), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
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

    private func app() throws -> String { try code("QAudionApp/AppState.swift") }

    // MARK: 27 - a 1:1 call while a group call is live

    func testSpec27_placingAOneToOneCallAsksBeforeAnythingIsStarted() throws {
        let startCall = try slice(try app(), from: "func startCall(contactId: String, video: Bool = false, origin: CallStartOrigin = .phone) async {",
                                  to: "guard let engine = ensureCallEngine(reason: \"startCall\")")
        XCTAssertTrue(startCall.contains("GroupAdmissionPolicy.decide(groupState: groupCallControllerState, isInCall: false) == .confirmLeaveGroup"))
        XCTAssertTrue(startCall.contains("callStartGate.end() if origin.mayAskToLeaveGroup { askToLeaveGroup(.dial(contactId: contactId, video: video)) } else {"),
                      "the start gate is released and the call is not started")
        XCTAssertTrue(startCall.contains("guard !isInCall else"), "the refusal of a second 1:1 call stays in front")
    }

    func testSpec27_aStartFromTheCarIsRefusedAndNeverAsksOnThePhone() throws {
        let app = try app()
        let startCall = try slice(app, from: "func startCall(contactId: String, video: Bool = false, origin: CallStartOrigin = .phone) async {",
                                  to: "guard let engine = ensureCallEngine(reason: \"startCall\")")
        let refusal = try slice(startCall, from: "} else { groupDiag(GroupDiagnostics.admissionLine(.refusedFromCar", to: "} return }")
        XCTAssertFalse(refusal.contains("askToLeaveGroup"), "no question on the phone for a start from the car")
        XCTAssertTrue(refusal.contains("roster: groupCallController?.currentRoster.count ?? 0"), "the refusal leaves a numeric line")
        // Both ways in from the car start through the one helper, which names the origin and tells the car screen.
        let helper = try slice(app, from: "private func startCallFromCar(contactId: String, video: Bool = false) async {",
                               to: "private func donateStartCallInteraction")
        XCTAssertTrue(helper.contains("await startCall(contactId: contactId, video: video, origin: .car)"))
        XCTAssertTrue(helper.contains("CarCallStartNotice.isDue(busyAtEntry: busyAtEntry, inCallAfter: isInCall)"))
        XCTAssertTrue(helper.contains("CarPlayBridge.shared.report(.callNotStarted)"), "the car shows its own notice")
        let carPlay = try slice(app, from: "CarPlayBridge.shared.placeCall = { [weak self] peerUserId, displayName in",
                                to: "CarPlayBridge.shared.sessionState")
        XCTAssertTrue(carPlay.contains("await self.startCallFromCar(contactId: peerUserId)"))
        XCTAssertFalse(carPlay.contains("startCall(contactId:"), "CarPlay never starts a call by the phone's route")
        let siri = try slice(app, from: "func handleSiriStartCall(_ userActivity: NSUserActivity) {",
                             to: "private func startCallFromCar(")
        XCTAssertTrue(siri.contains("await startCallFromCar(contactId: match.userId, video: video)"))
        XCTAssertFalse(siri.contains("await startCall(contactId:"), "Siri never starts a call by the phone's route")
    }

    func testSpec27_acceptingAOneToOneCallAsksBeforeTheCallIsAcceptedAndAfterTheDuplicateAnswerGuard() throws {
        let accept = try slice(try app(), from: "private func performAcceptIncoming(uuid: UUID) -> Bool {",
                               to: "self.answeredCallKitId = uuid")
        let guardRange = accept.range(of: "if self.answeredCallKitId == uuid {")
        let askRange = accept.range(of: "GroupAdmissionPolicy.decide(groupState: groupCallControllerState, isInCall: false) == .confirmLeaveGroup")
        XCTAssertNotNil(guardRange)
        XCTAssertNotNil(askRange)
        if let g = guardRange, let a = askRange {
            XCTAssertLessThan(g.lowerBound, a.lowerBound, "an answer already taken never asks again")
        }
        XCTAssertTrue(accept.contains("askToLeaveGroup(.answer(uuid: uuid)) return true"))
        XCTAssertFalse(accept.contains("self.isInCall = true"), "nothing of the accept has run yet")
    }

    func testSpec27_yesLeavesTheGroupThenContinuesNoDeclinesTheIncomingCallAsBusy() throws {
        let app = try app()
        let confirm = try slice(app, from: "func confirmLeaveGroupPrompt() {", to: "private func startOneToOneAfterLeavingGroup")
        let order = [confirm.range(of: "leaveGroupPrompt = nil"), confirm.range(of: "leaveLiveGroupCall(why: .oneToOne)"),
                     confirm.range(of: "waitForMainQueueTurn()"), confirm.range(of: "startOneToOneAfterLeavingGroup(prompt.purpose)")]
        XCTAssertFalse(order.contains { $0 == nil })
        let positions = order.compactMap { $0?.lowerBound }
        XCTAssertEqual(positions, positions.sorted(), "leave first, then wait for the group's teardown, then place or accept the call")
        let revalidate = confirm.range(of: "isIncomingAnswerStillLive(uuid: uuid)")
        XCTAssertNotNil(revalidate, "an answer for a call that ended meanwhile does not leave the group")
        if let r = revalidate, let leave = confirm.range(of: "leaveLiveGroupCall(why: .oneToOne)") {
            XCTAssertLessThan(r.lowerBound, leave.lowerBound)
        }
        let resume = try slice(app, from: "private func startOneToOneAfterLeavingGroup", to: "private func waitForMainQueueTurn")
        XCTAssertTrue(resume.contains("await startCall(contactId: contactId, video: video)"))
        XCTAssertTrue(resume.contains("performAcceptIncoming(uuid: uuid)"))
        let cancel = try slice(app, from: "func cancelLeaveGroupPrompt() {", to: "private func markGroupCallHandled(")
        XCTAssertTrue(cancel.contains("if prompt.isAnswer { declineIncomingCall() }"))
        XCTAssertFalse(cancel.contains("leaveLiveGroupCall"), "stay means stay")
    }

    func testSpec27_aQuestionAboutACallThatEndedIsWithdrawn() throws {
        let app = try app()
        let withdraw = try slice(app, from: "fileprivate func withdrawLeaveGroupAnswerPrompt() {", to: "private func isIncomingAnswerStillLive")
        XCTAssertTrue(withdraw.contains("guard leaveGroupPrompt?.isAnswer == true else { return }"), "a question about a dial is not affected")
        XCTAssertTrue(withdraw.contains("leaveGroupPrompt = nil"))
        let end = try slice(app, from: "let leavesGroup: Bool = shouldLeaveGroupAfterOneToOneEnded()",
                            to: "pendingIdentityRotation = nil callIdentityRotationAwaitingSas = false")
        XCTAssertTrue(end.contains("withdrawLeaveGroupAnswerPrompt()"), "the 1:1 call ended: the answer question goes with it")
        XCTAssertTrue(app.contains("self.incomingCallRingVisible = false self.withdrawLeaveGroupAnswerPrompt()"),
                      "a cancel push ended the ring")
        XCTAssertTrue(app.contains("@Published var incomingCallRingVisible: Bool = false { didSet { if incomingCallRingVisible { callerBusyTone.stop() } } }"))
    }

    func testSpec27_anAnsweredCallIsNotLeftWithoutAudioWhenTheQuestionWasUp() throws {
        let app = try app()
        let record = app.range(of: "if self.leaveGroupPrompt?.isAnswer == true { self.deferredAnswerActivationSource = source }")
        let group = app.range(of: "if groupLive { self.groupCallController?.audioSessionActivated(source: source) }")
        XCTAssertNotNil(record)
        XCTAssertNotNil(group)
        if let r = record, let g = group { XCTAssertLessThan(r.lowerBound, g.lowerBound) }
        let resume = try slice(app, from: "private func startOneToOneAfterLeavingGroup", to: "private func replayDeferredAnswerAudioActivation")
        XCTAssertTrue(resume.contains("let accepted: Bool = performAcceptIncoming(uuid: uuid) replayDeferredAnswerAudioActivation(accepted: accepted)"))
        let replay = try slice(app, from: "private func replayDeferredAnswerAudioActivation", to: "private func waitForMainQueueTurn")
        XCTAssertTrue(replay.contains("guard accepted, isInCall, let source = source else { return }"))
        XCTAssertTrue(replay.contains("callService.handleAudioSessionActivated(source: source)"))
    }

    func testSpec27_theRoutedHangUpLeavesTheWayEveryExitDoes() throws {
        let hangUp = try slice(try app(), from: "func endGroupCallFromSystemUI() {", to: "func clearGroupCallKitCall(")
        XCTAssertTrue(hangUp.contains("leaveLiveGroupCall(why: .hangUp)"))
        XCTAssertFalse(hangUp.contains("groupCallController?.leave()"))
        let view = try code("QAudionApp/Views/GroupCallView.swift")
        XCTAssertTrue(view.contains("controller.leaveOrEnd()"), "the group screen's red button leaves through the exit policy too")
    }

    func testSpec27_aQuestionLeftOpenByAGroupThatEndedOnItsOwnIsDropped() throws {
        let app = try app()
        XCTAssertTrue(app.contains("if case .idle = groupCallControllerState, leaveGroupPrompt != nil { leaveGroupPrompt = nil }"))
    }

    func testSpec27_leavingGoesThroughTheExitPolicy() throws {
        let leave = try slice(try app(), from: "func leaveLiveGroupCall(why: GroupDiagnostics.ExitReason) {",
                              to: "private func shouldLeaveGroupAfterOneToOneEnded")
        XCTAssertTrue(leave.contains("GroupExitPolicy.action("))
        XCTAssertTrue(leave.contains("case .endForAll: controller.endCallForAll() case .leave: controller.leave()"))
    }

    func testSpec27_acceptingAnotherGroupCallLeavesTheLiveOneFirst() throws {
        let join = try slice(try app(), from: "private func joinAcceptedGroupCall(_ invite: IncomingGroupCallInvite, autoJoin: GroupAutoJoinGuard? = nil) {",
                             to: "private func continueAcceptedGroupCall")
        XCTAssertTrue(join.contains("leaveLiveGroupCall(why: .acceptOther)"))
        XCTAssertTrue(join.contains("!GroupCallIds.ieq(liveId, invite.callId)"), "a different call id, compared without regard to case")
        let order = [join.range(of: "leaveLiveGroupCall(why: .acceptOther)"),
                     join.range(of: "continueAcceptedGroupCall(invite, autoJoin: autoJoin) } return }")]
        XCTAssertFalse(order.contains { $0 == nil })
    }

    // MARK: 28 - promotion consent

    func testSpec28_theBusyRuleLetsAPromotionPastTheOneToOneCallOnly() throws {
        let present = try slice(try app(), from: "func presentIncomingGroupCall(", to: "private func armGroupCallRingTimeout")
        XCTAssertTrue(present.contains("guard (oneToOneBusy && !isSelfPromotion) || groupBusy else { return nil }"),
                      "the self-promotion carve-out does not bypass a live group call")
        XCTAssertTrue(present.contains("GroupPromotionPolicy.isSelfPromotion("))
        XCTAssertFalse(present.contains("W-GRPRING busy"), "the busy decision is a numeric line, not a print")
        XCTAssertFalse(present.contains("W-GRPRING ring "), "the ring is a numeric line, not a print")
        XCTAssertTrue(present.contains("GroupDiagnostics.ringLine(.busyDrop, code: busyCode)"))
        XCTAssertTrue(present.contains("GroupDiagnostics.ringLine(.shown)"))
    }

    func testSpec28_anAttestedInviteWaitsForItsTokenBeforeAnythingRings() throws {
        let present = try slice(try app(), from: "func presentIncomingGroupCall(", to: "private func groupInviteBusyCode")
        XCTAssertTrue(present.contains("let attested: Bool = invite.promoted && source == .webSocket"),
                      "the push never carries the attestation")
        let watch = present.range(of: "if attested { return startPromotedInviteWatch(invite) } return presentGroupInviteRing(invite, source: source)")
        XCTAssertNotNil(watch, "an attested invite goes to the decision, every other invite rings as before")
        let ringUp = present.range(of: "if attested { _ = startPromotedInviteWatch(invite) if incomingGroupCallInvite == nil { return false } }")
        XCTAssertNotNil(ringUp, "a push that rang first is judged too, and its ring is taken down when the token holds")
        XCTAssertTrue(present.contains("GroupCallIds.ieq(current.callId, invite.callId)"), "the call id deduplication is case-insensitive")
        XCTAssertTrue(present.contains("if isGroupCallHandled(invite.callId) {"))
    }

    func testSpec28_theDecisionReadsTheInviteTheLiveCallAndTheAnchor() throws {
        let input = try slice(try app(), from: "private func promotionDecisionInput(", to: "fileprivate func startPromotedInviteWatch")
        XCTAssertTrue(input.contains("promoted: invite.promoted"))
        XCTAssertTrue(input.contains("liveCallId: liveId"))
        XCTAssertTrue(input.contains("anchorDefined: anchor.isDefined, anchorPoisoned: anchor.poisoned, kcmacVerified: anchor.kcmacVerified"))
        XCTAssertTrue(input.contains("micGranted: promotionMicGranted()"))
        XCTAssertTrue(input.contains("token: token, groupLive: GroupAdmissionPolicy.isLive(groupCallControllerState)"))
        let live = try slice(try app(), from: "fileprivate func liveOneToOneCallIdForPromotion() -> String? {", to: "fileprivate func promotionContext(")
        XCTAssertTrue(live.contains("guard isInCall, callContactId != nil else { return nil }"), "a 1:1 call that is live, not one that rings")
        let run = try slice(try app(), from: "fileprivate func runPromotionDecision(", to: "private func armPromotionHoldTimer")
        XCTAssertTrue(run.contains("GroupPromotionDecision.decide(input)"))
        for outcome in ["case .fallback:", "case .noConversion:", "case .hold:", "case .ring(let why):", "case .autoJoin:", "case .convert:"] {
            XCTAssertTrue(run.contains(outcome), outcome)
        }
    }

    func testSpec28_theAutoJoinConsumesTheTokenJoinsFirstAndIsAudioOnly() throws {
        let app = try app()
        let start = try slice(app, from: "private func startAutoJoin(", to: "fileprivate func autoJoinRosterRefused(")
        let order = [start.range(of: "context.book.consume(groupCallId: invite.callId)"),
                     start.range(of: "markGroupCallHandled(invite.callId)"),
                     start.range(of: "joinAcceptedGroupCall(invite, autoJoin: rosterGuard)")]
        XCTAssertFalse(order.contains { $0 == nil })
        let positions = order.compactMap { $0?.lowerBound }
        XCTAssertEqual(positions, positions.sorted(), "the token is consumed first, the join goes out, nothing touches the 1:1 leg")
        XCTAssertTrue(start.contains("if converting { dismissGroupRingForAutoJoin(callId: invite.callId) }"))
        let dismiss = try slice(app, from: "private func dismissGroupRingForAutoJoin(", to: "private func startAutoJoin(")
        XCTAssertTrue(dismiss.contains("clearGroupCallKitCall(reason: .remoteEnded)"), "a non-decline reason")
        XCTAssertFalse(dismiss.contains("declineGroupCall"), "a conversion is not a dismissal")
        let cont = try slice(app, from: "private func continueAcceptedGroupCall(", to: "self.armGroupCallJoinTimeout(callId: callId)")
        XCTAssertTrue(cont.contains("let hasVideo = autoJoin == nil ? invite.hasVideo : false"), "never the call type of the invite")
        XCTAssertTrue(cont.contains("controller.join(callId: callId, video: hasVideo, startMuted: startMuted, autoJoinGuard: autoJoin)"))
        XCTAssertTrue(cont.contains("autoJoined: autoJoin != nil"))
    }

    func testSpec28_aDeviceThatJoinedByItselfNeverHangsUpTheOneToOneCall() throws {
        let app = try app()
        let carry = try slice(app, from: "private func carryOutHandOver(", to: "private func hangUpOneToOneForPromotion()")
        XCTAssertTrue(carry.contains("if groupPromotion?.autoJoined == true { releaseAutoJoinedPromotion(reason) return }"))
        let release = try slice(app, from: "private func releaseAutoJoinedPromotion(", to: "private func carryOutHandOver(")
        XCTAssertFalse(release.contains("hangUpOneToOneForPromotion"))
        XCTAssertFalse(release.contains("endCall("))
        XCTAssertTrue(release.contains("completeGroupPromotion(hangUp: false)"), "only when the 1:1 call ended by itself")
    }

    func testSpec28_theCreatorSendsTheTokenBeforeTheCreateAndMintsTheIdInLowerCase() throws {
        let promote = try slice(try app(), from: "func promoteToGroupCall(newPeerIds: [String]) {", to: "private static func deriveTransitionalSasKey")
        XCTAssertTrue(promote.contains("GroupPromotionPlan.plan("))
        XCTAssertTrue(promote.contains("groupCallId: UUID().uuidString.lowercased()"))
        XCTAssertTrue(promote.contains("invitees: plan.recipients"), "the create carries exactly the recipients the token lists")
        XCTAssertTrue(promote.contains("groupCallId: plan.groupCallId, preCreateOpaque: opaque"))
        let order = [promote.range(of: "OpaqueSelfEchoFilter.shared.markSent(wire)"), promote.range(of: "controller.createCall(")]
        XCTAssertFalse(order.contains { $0 == nil })
        let positions = order.compactMap { $0?.lowerBound }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(promote.contains("HandshakeTranscript.sign(transcript: tbs, signingPrivateKeyRaw: seed)"))
        XCTAssertTrue(promote.contains("liveSigningPublicKey: identity?.signingPublic"), "the key that signed the round-1 bundle")
        let resend = try slice(try app(), from: "fileprivate func resendPromotionTokenAfterReauth() {", to: "func leaveLiveGroupCall(")
        XCTAssertTrue(resend.contains("!sent.resent"), "once")
        XCTAssertTrue(resend.contains("promotionWallMs <= sent.expiresAtWallMs"), "while it has not expired")
        XCTAssertTrue(resend.contains("payload: data"), "the same bytes, never a re-signed copy")
    }

    func testSpec28_theTokenIsRoutedBeforeTheBundleParserAndTheAnchorComesFromTheKeyRounds() throws {
        let app = try app()
        let parse = app.range(of: "CallPiggyBack.parse(blobStr)")
        let bundle = app.range(of: "AndroidHandshakeEnvelope.parse(blobStr)")
        XCTAssertNotNil(parse)
        XCTAssertNotNil(bundle)
        if let p = parse, let b = bundle { XCTAssertLessThan(p.lowerBound, b.lowerBound) }
        let route = try slice(app, from: "private func routeInboundCallPiggyBack(", to: "private func handleInboundSasReveal")
        XCTAssertTrue(route.contains("case .groupPromotion(let callId, let raw): handleInboundGroupPromotionToken(callId: callId, raw: raw, senderId: senderId)"))
        let ready = try slice(app, from: "private func handleKcMacReady(", to: "let state = KeyConfirmationCallState(event: event)")
        XCTAssertTrue(ready.contains("notePromotionAnchor(from: event)"))
        let reveal = try slice(app, from: "private func handleInboundSasReveal(", to: "case .ended(let reason):")
        XCTAssertTrue(reveal.contains("promotionContexts[key]?.anchor.noteBound()"))
        XCTAssertTrue(app.contains("promotionContexts[key]?.anchor.noteKcMacVerified(round: round)"))
        XCTAssertTrue(app.contains("promotionContexts.removeValue(forKey: key)"))
        XCTAssertFalse(app.contains("promotionContexts.removeAll()"), "a call that ends never wipes the state of another one")
        let receive = try slice(app, from: "private func handleInboundGroupPromotionToken(", to: "fileprivate enum PromotionTrigger")
        XCTAssertTrue(receive.contains("GroupPromotionReceiver.receive("))
        XCTAssertTrue(receive.contains("GroupDiagnostics.promoReceivedLine(ok: false, code: drop.rawValue)"))
        XCTAssertFalse(receive.contains("endCall"), "a token never ends or changes the 1:1 call")
    }

    func testSpec28_theEndOfOneCallRemovesOnlyItsOwnPromotionState() throws {
        let app = try app()
        let end = try slice(app, from: "let endedPromotionCallId: String? =",
                            to: "pendingIdentityRotation = nil callIdentityRotationAwaitingSas = false")
        XCTAssertTrue(end.contains("getActiveCallId().flatMap { $0.isEmpty ? nil : $0 }"), "the id is read before the teardown clears it")
        XCTAssertTrue(end.contains("if let ended = endedPromotionCallId { promotionContexts.removeValue(forKey: ended.lowercased()) releasePromotedInviteWatchesAfterOneToOneEnd(endedCallId: ended) }"))
        XCTAssertFalse(end.contains("removeAll()"))
        let release = try slice(app, from: "func releasePromotedInviteWatchesAfterOneToOneEnd(endedCallId: String) {",
                                to: "private func dismissGroupRingForAutoJoin")
        XCTAssertTrue(release.contains("promotedInviteWatches.filter { GroupCallIds.ieq($0.value.invite.promotedFromCallId, endedCallId) }"))
        XCTAssertFalse(release.contains("promotedInviteWatches.removeAll()"), "an invite that names another call stays held")
    }

    func testSpec28_theEndOfAHeldPromotedInviteIsHandledAndNeverRings() throws {
        let ended = try slice(try app(), from: "func groupRingEnded(callId: String, reason: String) {",
                              to: "private static let ratchetVault")
        XCTAssertTrue(ended.contains("let held: Bool = promotedInviteWatches[GroupCallIds.lower(callId)] != nil"))
        XCTAssertTrue(ended.contains("guard rings || held else { return }"))
        let handled = ended.range(of: "markGroupCallHandled(callId)")
        let ringOnly = ended.range(of: "guard rings else { return }")
        let ringtone = ended.range(of: "stopInAppRingtone()")
        XCTAssertNotNil(handled)
        XCTAssertNotNil(ringOnly)
        XCTAssertNotNil(ringtone)
        if let h = handled, let r = ringOnly, let t = ringtone {
            XCTAssertLessThan(h.lowerBound, r.lowerBound, "the call is handled whether or not it rang")
            XCTAssertLessThan(r.lowerBound, t.lowerBound, "an invite that never rang touches nothing of the ring surface")
        }
        // Marking it handled is what drops the watch, so the end of the hold cannot ring it.
        let mark = try slice(try app(), from: "private func markGroupCallHandled(_ callId: String) {", to: "guard !isGroupCallHandled(callId)")
        XCTAssertTrue(mark.contains("dropPromotedInviteWatch(key: GroupCallIds.lower(callId))"))
    }

    func testSpec28_callIdsAreMintedInLowerCaseAndMatchedCaseInsensitively() throws {
        let manager = try code("QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoGroupCallManager.swift")
        XCTAssertTrue(manager.contains("let newCallId = groupCallId ?? UUID().uuidString.lowercased()"))
        let coordinator = try code("QAudionEngine/Sources/QAudionEngine/GroupCall/GroupE2ee.swift")
        XCTAssertTrue(coordinator.contains("GroupCallIds.ieq(envelope.callId, callId)"))
        XCTAssertFalse(coordinator.contains("envelope.callId == callId"))
        let controller = try code("QAudionEngine/Sources/QAudionEngine/GroupCall/GroupCallController.swift")
        XCTAssertTrue(controller.contains("GroupCallIds.ieq($0.envelope.callId, callId)"))
        let view = try code("QAudionApp/Views/GroupCallView.swift")
        XCTAssertTrue(view.contains("!GroupCallIds.ieq(id, selfUserId) && !participants.contains(where: { GroupCallIds.ieq($0.id, id) })"))
    }

    func testSpec33_theMicrophoneThatIsHeldIsShownAsHeld() throws {
        let view = try code("QAudionApp/Views/GroupCallView.swift")
        XCTAssertTrue(view.contains("controller.onMicrophoneHeldChanged = { [weak self] held in DispatchQueue.main.async { self?.isMicrophoneHeld = held } }"))
        XCTAssertTrue(view.contains("isMicrophoneHeld = controller?.isMicrophoneHeld ?? false"), "a view model bound mid-call starts from the real state")
        XCTAssertTrue(view.contains("var isMicrophoneOff: Bool { isMuted || isMicrophoneHeld }"))
        XCTAssertEqual(view.components(separatedBy: "localMuted: viewModel.isMicrophoneOff,").count - 1, 2, "both self tiles")
        XCTAssertTrue(view.contains(".disabled(viewModel.isMicrophoneHeld)"))
        XCTAssertTrue(view.contains("\"group_call.mic_held\""))
    }

    func testSpec28_aRosterOutsideTheTokenLeavesTheGroupKeepsTheOneToOneCallAndSaysSo() throws {
        let app = try app()
        let refused = try slice(app, from: "fileprivate func autoJoinRosterRefused(extra: Int) {", to: "fileprivate func resendPromotionTokenAfterReauth()")
        XCTAssertTrue(refused.contains("leaveLiveGroupCall(why: .rosterMismatch)"))
        XCTAssertTrue(refused.contains("groupPromotionMismatchToastText = String("))
        XCTAssertTrue(refused.contains("\"group_call.promotion_mismatch_notice\""))
        XCTAssertFalse(refused.contains("endCall("), "the 1:1 call stays")
        XCTAssertTrue(app.contains("groupController.onAutoJoinRosterRefused = { [weak self] extra in"))
        let content = try code("QAudionApp/Views/ContentView.swift")
        XCTAssertTrue(content.contains(".onChange(of: appState.groupPromotionMismatchToastText) { text in"))
    }

    func testSpec28_theTimedOutRingAndTheDeclineLeaveNumericLines() throws {
        let app = try app()
        XCTAssertFalse(app.contains("W-GRPRING ring timed out"))
        XCTAssertFalse(app.contains("W-GRPRING busy"))
        XCTAssertFalse(app.contains("W-GRPRING declined"))
        XCTAssertTrue(app.contains("GroupDiagnostics.ringLine(.timedOut)"))
        XCTAssertTrue(app.contains("GroupDiagnostics.ringLine(.declined)"))
    }

    func testSpec28_theWireInviteCarriesTheAttestationIntoTheApp() throws {
        let app = try app()
        XCTAssertTrue(app.contains("promotedFromCallId: invite.promotedFromCallId, promoted: invite.promoted)"))
    }

    // MARK: 29 - hand-over

    func testSpec29_theTwoTimersAreTheCapAndTheMediaDeadline() throws {
        let begin = try slice(try app(), from: "func beginGroupPromotion(groupCallId: String, peerId: String, autoJoined: Bool = false) {",
                              to: "func groupPromotionDidChange")
        XCTAssertTrue(begin.contains("deadline: .now() + GroupHandOverPolicy.capSeconds, execute: cap"))
        XCTAssertTrue(begin.contains("deadline: .now() + GroupHandOverPolicy.mediaDeadlineSeconds, execute: mediaCheck"))
        XCTAssertFalse(begin.contains("+ 20"), "the cap is one timer of 50 s from the start, not 30 s plus 20 s")
    }

    func testSpec29_theHandOverTakesItsDecisionFromThePolicy() throws {
        let evaluate = try slice(try app(), from: "func evaluateGroupPromotion(minElapsed: Double = 0) {",
                                 to: "private func carryOutHandOver")
        XCTAssertTrue(evaluate.contains("GroupHandOverPolicy.decide(inputs)"))
        XCTAssertTrue(evaluate.contains("ringing: controller.currentRinging"))
        XCTAssertTrue(evaluate.contains("case .abort:"))
        XCTAssertTrue(evaluate.contains("case .abandonMediaNotUp:"))
        XCTAssertTrue(evaluate.contains("selfId: groupCallManager?.selfUserId ?? \"\""))
        let abort = try slice(evaluate, from: "case .abortKeepOneToOne:", to: "case .handOver(let reason):")
        XCTAssertTrue(abort.contains("leaveLiveGroupCall(why: .promotionAborted)"), "the group is left")
        XCTAssertFalse(abort.contains("endCall("), "the 1:1 call stays")
    }

    func testSpec29_theHandOverIsTakenFromTheStoredUpdateNotFromTheEarlierRosterCallback() throws {
        let app = try app()
        XCTAssertTrue(app.contains("groupController.onUpdateApplied = { [weak self] _, _ in DispatchQueue.main.async { self?.groupRosterChangedForPromotion() } }"))
        XCTAssertFalse(app.contains("viewModelParticipantsHook?(list) DispatchQueue.main.async { self?.groupRosterChangedForPromotion() }"),
                       "the roster callback fires before the controller stored the update")
        let abandon = try slice(app, from: "private func abandonGroupPromotion() {", to: "func groupRingEnded(")
        XCTAssertTrue(abandon.contains("leaveLiveGroupCall(why: .mediaNotUp)"), "the creator that is the last one ends the group")
    }

    func testSpec29_theOneToOneCallIsHungUpWithTheReasonPromotedToGroup() throws {
        let hangUp = try slice(try app(), from: "private func hangUpOneToOneForPromotion() {",
                               to: "private func completeGroupPromotion(hangUp: Bool = true)")
        XCTAssertTrue(hangUp.contains("callService.sendControlHangup(reason: \"promoted-to-group\")"))
        XCTAssertTrue(hangUp.contains("reason: \"promoted-to-group\")"))
        XCTAssertTrue(hangUp.contains("impl.unbindActiveCallId(matching: callId)"), "one hangup on the wire, not two")
        XCTAssertTrue(hangUp.contains("endCall(notifyPeerInBand: false)"))
        let complete = try slice(try app(), from: "private func completeGroupPromotion(hangUp: Bool = true) {",
                                 to: "private func abandonGroupPromotion()")
        XCTAssertTrue(complete.contains("hangUpOneToOneForPromotion()"))
    }

    func testSpec29_aOneToOneCallEndingWithAnEmptyGroupLeavesTheGroup() throws {
        let endCall = try slice(try app(), from: "let leavesGroup: Bool = shouldLeaveGroupAfterOneToOneEnded()",
                                to: "pendingIdentityRotation = nil callIdentityRotationAwaitingSas = false")
        XCTAssertTrue(endCall.contains("groupPromotion = nil"))
        XCTAssertTrue(endCall.contains("leaveLiveGroupCall(why: .oneToOneEndedAlone)"))
        XCTAssertTrue(endCall.contains("groupCallController?.oneToOneEnded()"), "the audio unit hand-over for every other case")
    }

    func testSpec30_thePromotionStateReachesTheGroupController() throws {
        let app = try app()
        XCTAssertTrue(app.contains("didSet { groupPromotionDidChange() }"))
        XCTAssertTrue(app.contains("groupCallController?.setPromotionPending(groupPromotion != nil)"))
    }

    // MARK: audio unit

    func testTheGroupDriverWritesNumericLinesAndTheControllerShipsThem() throws {
        let driver = try code("QAudionEngine/Sources/QAudionEngine/GroupCall/GroupAudioUnitDriver.swift")
        XCTAssertFalse(driver.contains("grpaudio"), "the old words are not shipper vocabulary")
        XCTAssertTrue(driver.contains("GroupDiagnostics.audioDriverLine(.begun, shared: true)"))
        XCTAssertTrue(driver.contains("GroupDiagnostics.audioDriverLine(.rearmed, shared: false)"))
        let controller = try code("QAudionEngine/Sources/QAudionEngine/GroupCall/GroupCallController.swift")
        XCTAssertTrue(controller.contains("(self.audio as? GroupAudioUnitDriver)?.log = { [weak self] line in self?.diagLog?(line) }"))
    }

    func testAGroupHeldUnitIsNotSwitchedOffByANewOneToOneCall() throws {
        let gate = try code("QAudionEngine/Sources/QAudionEngine/WebRTC/NativeAudioSessionGate.swift")
        let audit = try slice(gate, from: "public static func auditAtCallStart(nativeCall: Bool) {",
                              to: "let session = RTCAudioSession.sharedInstance()")
        XCTAssertTrue(audit.contains("if isGroupArmHeld { emit(\"admgate audit=1 held=1 grp=1\") return }"))
        XCTAssertTrue(gate.contains("let keepsGroupUnit = armedToken != 0 && armedToken == groupArmToken && prevManual && prevEnabled"))
        let driver = try code("QAudionEngine/Sources/QAudionEngine/GroupCall/GroupAudioUnitDriver.swift")
        XCTAssertTrue(driver.contains("NativeAudioSessionGate.markGroupArm(token: newToken)"))
    }

    func testTheRefusedOneToOneAudioStartLeavesAWarnLine() throws {
        let service = try code("QAudionApp/Services/CallService.swift")
        let refused = try slice(service, from: "if isGroupCallActive?() == true { let nativeCall",
                                to: "guard audioSessionActive else")
        XCTAssertTrue(refused.contains("GroupDiagnostics.audioStartRefusedLine(native: nativeCall, unitEnabled: unitEnabled)"))
        XCTAssertTrue(refused.contains("RTLog.warn(\"call\", refusedLine) return"))
    }

    // MARK: the texts

    private let languages = ["it", "en", "de", "es", "fr", "pt-BR"]
    private let keys = [
        "group_call.leave_prompt_title",
        "group_call.leave_prompt_message_dial",
        "group_call.leave_prompt_message_answer",
        "group_call.leave_prompt_confirm",
        "group_call.leave_prompt_stay",
        "group_call.ringing_badge",
        "group_call.mic_held",
        "group_call.promotion_mismatch_notice",
    ]

    func testEveryNewStringHasEveryShippedLanguage() throws {
        let url = try sourceURL("QAudionApp/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(localizations.keys), Set(languages), key)
            for language in languages {
                let one = try XCTUnwrap(localizations[language] as? [String: Any], "\(key) \(language)")
                let unit = try XCTUnwrap(one["stringUnit"] as? [String: Any], key)
                let text = try XCTUnwrap(unit["value"] as? String, key)
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) \(language)")
                XCTAssertEqual(unit["state"] as? String, "translated", "\(key) \(language)")
            }
        }
    }

    func testTheQuestionIsAskedInTheWordsOfTheSpec() throws {
        let url = try sourceURL("QAudionApp/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings["group_call.leave_prompt_title"] as? [String: Any])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let italian = try XCTUnwrap((localizations["it"] as? [String: Any])?["stringUnit"] as? [String: Any])
        XCTAssertEqual(italian["value"] as? String, "Vuoi uscire dal gruppo?")
    }

    func testTheViewsUseTheNewKeys() throws {
        let alert = try code("QAudionApp/Views/Call/LeaveGroupAlert.swift")
        for key in keys where key.hasPrefix("group_call.leave_prompt") {
            XCTAssertTrue(alert.contains("\"\(key)\""), key)
        }
        let view = try code("QAudionApp/Views/GroupCallView.swift")
        XCTAssertTrue(view.contains("\"group_call.ringing_badge\""))
        XCTAssertTrue(view.contains("viewModel.ringingTiles"))
        let content = try code("QAudionApp/Views/ContentView.swift")
        XCTAssertTrue(content.contains(".leaveGroupAlert( isPresented: appState.leaveGroupPrompt != nil"))
        XCTAssertTrue(try app().contains("\"group_call.promotion_mismatch_notice\""))
    }
}
