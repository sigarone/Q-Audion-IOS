import XCTest
@testable import QAudionEngine

/// BLOCK — what the PushKit callback reports for a blocked caller, and where the app calls the block rules.
///
/// The pure decisions (the blocked-caller report, its recognition, what the delegate does with a prepared spec)
/// are tested directly. The app layer (`AppState`, the screens) cannot be built into an engine test, so its wiring
/// is pinned by SOURCE INVARIANTS, the choice `VoipPushSyncReportTests` and `CallerBusyWiringTests` make: line
/// comments are stripped and whitespace collapsed before matching, so only code counts.
///
/// What none of this proves: that the screens behave on a phone, that iOS accepts the report-and-end of a push on
/// a real device (only a VoIP push to a suspended app shows that), or that the server stops delivering. A
/// source invariant shows a guard is there and in the right order, not that it is reached.
final class ContactBlockWiringTests: XCTestCase {

    private let callId = UUID(uuidString: "B0D7BA30-655B-420D-A4ED-8848EFC51C98")!

    // MARK: - PushKit: the blocked-caller report

    func testABlockedCallersPushIsReportedAsAGenericPlaceholderThatEndsAtOnce() {
        let spec = PushKitProvider.blockedCallerSpec()
        XCTAssertEqual(spec.callerName, PushKitProvider.placeholderCallerName,
                       "the system screen must not show who called")
        XCTAssertFalse(spec.hasVideo)
        guard case .failed(let reason)? = spec.endReason else {
            return XCTFail("a push that must not ring is reported and then ended at once")
        }
        XCTAssertEqual(reason, PushKitProvider.blockedCallerEndReason)
    }

    func testTheBlockedCallerReportUsesAFreshUuidNeverTheCalls() {
        let a = PushKitProvider.blockedCallerSpec()
        let b = PushKitProvider.blockedCallerSpec()
        XCTAssertNotEqual(a.uuid, b.uuid)
        XCTAssertNotEqual(a.uuid, callId)
        let fixed = PushKitProvider.blockedCallerSpec(uuid: callId)
        XCTAssertEqual(fixed.uuid, callId, "a caller can pin the uuid (the app does not)")
    }

    func testOnlyTheBlockedCallerReportIsRecognisedAsSuch() {
        XCTAssertTrue(PushKitProvider.isBlockedCallerSpec(PushKitProvider.blockedCallerSpec()))
        XCTAssertFalse(PushKitProvider.isBlockedCallerSpec(PushKitProvider.placeholderSpec()))
        let ringing = PushKitProvider.ReportSpec(uuid: callId, callerName: "Anna", hasVideo: true, endReason: nil)
        XCTAssertFalse(PushKitProvider.isBlockedCallerSpec(ringing))
        let cancelled = PushKitProvider.ReportSpec(uuid: callId, callerName: "Q-Audion", hasVideo: false,
                                                   endReason: .remoteEnded)
        XCTAssertFalse(PushKitProvider.isBlockedCallerSpec(cancelled))
    }

    func testTheDelegateReportsTheBlockedSpecItWasHandedUnchanged() {
        // The PushKit rule: every push is reported, with the spec the app decided. A decoded 1:1 push whose
        // prepared spec is the blocked one must reach CallKit as that spec (so it is ended at once), not be
        // swapped for a ringing report or dropped.
        let incoming: [String: Any] = [
            "type": "incoming_call", "call_id": callId.uuidString, "caller_id": "u-1",
            "caller_name": "Anna", "call_type": "audio",
        ]
        let event = PushKitProvider.classify(incoming)
        XCTAssertEqual(event.kindCode, 1)
        let blocked = PushKitProvider.blockedCallerSpec()
        let resolved = PushKitProvider.resolveSpec(event: event, prepared: blocked)
        XCTAssertEqual(resolved.uuid, blocked.uuid)
        XCTAssertTrue(PushKitProvider.isBlockedCallerSpec(resolved))
    }

    func testTheCallersNameNeverReachesTheBlockedReport() {
        let incoming: [String: Any] = [
            "type": "incoming_call", "call_id": callId.uuidString, "caller_id": "u-1",
            "caller_name": "Anna Rossi", "call_type": "video",
        ]
        guard case .incoming(let payload) = PushKitProvider.classify(incoming) else {
            return XCTFail("expected .incoming")
        }
        XCTAssertEqual(payload.callerName, "Anna Rossi")
        let spec = PushKitProvider.blockedCallerSpec()
        XCTAssertFalse(spec.callerName.contains("Anna"))
        XCTAssertFalse(spec.hasVideo, "not even the call type of a blocked caller is shown")
    }

    // MARK: - Reading the source

    private struct SourceNotFound: Error, CustomStringConvertible {
        let path: String
        var description: String { "source file not found: \(path)" }
    }

    /// The repository root, found by walking up from this file.
    private func repoRoot(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<12 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("QAudionApp/AppState.swift").path) {
                return dir
            }
        }
        XCTFail("repository root not found from \(file): the wiring invariants cannot run", file: file, line: line)
        throw SourceNotFound(path: "QAudionApp/AppState.swift")
    }

    private func strip(_ raw: String) -> String {
        // "\r\n" is ONE Character in Swift, so a file checked out with Windows line endings would not split on "\n".
        let withoutComments = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `relativePath` from the repository root, comments stripped, whitespace collapsed. A missing file is a
    /// failure and a thrown error, never a skip.
    private func code(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = try repoRoot(file: file, line: line).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) not found: the wiring invariants cannot run", file: file, line: line)
            throw SourceNotFound(path: relativePath)
        }
        return strip(try String(contentsOf: url, encoding: .utf8))
    }

    /// `relativePath` from the repository root, as it is (comments kept). A missing file is a failure and a thrown error.
    private func rawText(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = try repoRoot(file: file, line: line).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) not found: the wiring invariants cannot run", file: file, line: line)
            throw SourceNotFound(path: relativePath)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `.swift` file under `QAudionApp`, as (path relative to the repository root, stripped code).
    private func appSources(file: StaticString = #filePath, line: UInt = #line) throws -> [(String, String)] {
        let root = try repoRoot(file: file, line: line)
        let appDir = root.appendingPathComponent("QAudionApp")
        guard let walker = FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil) else {
            XCTFail("cannot list QAudionApp", file: file, line: line)
            throw SourceNotFound(path: "QAudionApp")
        }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            out.append((relative, strip((try? String(contentsOf: url, encoding: .utf8)) ?? "")))
        }
        XCTAssertGreaterThan(out.count, 100, "the app sources were not found", file: file, line: line)
        return out
    }

    /// The text from the first `start` to the next `end` after it. Both markers must exist.
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
        guard let a = body.range(of: first) else { return XCTFail("missing: \(first)", file: file, line: line) }
        guard let b = body.range(of: second) else { return XCTFail("missing: \(second)", file: file, line: line) }
        XCTAssertLessThan(a.lowerBound, b.lowerBound, message, file: file, line: line)
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - One block / unblock function for every entry point

    func testNoScreenCallsTheBlockEndpointOrWritesTheLocalListDirectly() throws {
        // Only the shared coordinator (engine) talks to the block endpoints, and only `BlockedContactsStore`'s
        // own file and the service write the local list: a screen that did either itself would change the
        // server and the list separately, which is the bug this replaces.
        let allowedToWriteTheList: Set<String> = [
            "QAudionApp/Services/BlockedContactsStore.swift",
            "QAudionApp/Services/ContactBlockService.swift",
        ]
        let writes = ["BlockedContactsStore.add(", "BlockedContactsStore.remove(",
                      "BlockedContactsStore.replaceAll(", "BlockedContactsStore.clear("]
        for (path, source) in try appSources() {
            XCTAssertFalse(source.contains(".blockContact("), "\(path) calls the block endpoint itself")
            XCTAssertFalse(source.contains(".unblockContact("), "\(path) calls the unblock endpoint itself")
            XCTAssertFalse(source.contains("contactsApi.blockContact"), "\(path)")
            if !allowedToWriteTheList.contains(path) {
                for write in writes {
                    XCTAssertFalse(source.contains(write), "\(path) writes the local blocked list with \(write)")
                }
            }
        }
    }

    func testEveryScreenThatBlocksOrUnblocksGoesThroughTheSharedFunction() throws {
        let direct = [
            "QAudionApp/Views/Contacts/ContactDetailScreen.swift",
            "QAudionApp/Views/Contacts/ContactsScreen.swift",
            "QAudionApp/Views/ContactsListView.swift",
            "QAudionApp/Views/ChatContainer.swift",
        ]
        for path in direct {
            let source = try code(path)
            XCTAssertTrue(source.contains("ContactBlockService.shared.setBlocked("),
                          "\(path) must block / unblock through ContactBlockService")
        }
        // The chat menu reaches it through the container, for both directions (block and unblock): it asks
        // for the opposite of the state in force.
        let menu = try code("QAudionApp/Views/Chat/ChatDetailScreen.swift")
        XCTAssertTrue(menu.contains("let wanted: Bool = !container.isPeerBlocked"),
                      "the chat menu must offer block and unblock through one entry")
        XCTAssertTrue(menu.contains("container.setPeerBlocked(wanted, snackbar: snackbar)"))
        XCTAssertTrue(menu.contains("\"Sblocca contatto\""), "unblock must be reachable from the chat")
        XCTAssertFalse(menu.contains("toggleBlock()"), "the one-way block call is gone")
    }

    func testTheServiceRunsTheServerFirstThroughTheSharedCoordinator() throws {
        let service = try code("QAudionApp/Services/ContactBlockService.swift")
        XCTAssertTrue(service.contains("coordinator.setBlocked(blocked, userId: userId)"))
        XCTAssertTrue(service.contains("actionLabel: Self.retryLabel"), "a failure must offer a retry")
        let engine = try code("QAudionEngine/Sources/QAudionEngine/Backend/ContactBlocking.swift")
        let body = try slice(engine, from: "public func setBlocked(", to: "public func refreshFromServer()")
        assertOrder(body, "try await backend.blockContact(userId: id)", before: "self.storage.insert(id)",
                    "the server must accept before the local list says blocked")
        assertOrder(body, "try await backend.unblockContact(userId: id)", before: "self.storage.remove(id)",
                    "the server must accept before the local list says unblocked")
    }

    func testTheBlockedListIsReloadedAtSignInAndOnEveryReconnectAndClearedWithTheAccount() throws {
        let app = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(app.contains("ContactBlockService.shared.bind(contactsApi:"))
        let authenticated = try slice(app, from: "if state == .authenticated {", to: "self?.rewireCallAudioOnReconnect()")
        XCTAssertTrue(authenticated.contains("ContactBlockService.shared.refreshFromServerIfDue()"))
        let reset = try slice(app, from: "func resetAccountScopedRuntimeState() {", to: "ServiceSendHub.shared.reset()")
        XCTAssertTrue(reset.contains("ContactBlockService.shared.forgetAccount()"))
    }

    // MARK: - Incoming calls, on every path

    func testTheWebSocketCallIncomingHandlerDropsABlockedCallerBeforeAnyCallKitReport() throws {
        let app = try code("QAudionApp/AppState.swift")
        let handler = try slice(app, from: "ws.registerHandler(type: \"call_incoming\")",
                                to: "self.rejectIncomingCallWithoutCallId(senderId: senderId)")
        XCTAssertTrue(handler.contains("if BlockedContactsStore.isBlocked(senderId) { return }"))
    }

    func testThePushKitPathChecksTheBlockBeforeItRegistersTheCall() throws {
        let app = try code("QAudionApp/AppState.swift")
        let prepare = try slice(app, from: "private func prepareVoipIncomingReport(",
                                to: "private func prepareBlockedVoipIncomingReport(")
        assertOrder(prepare, "BlockedContactsStore.isBlocked(payload.callerId)", before: "prepareIncomingPushCall(",
                    "a blocked caller must leave no trace: the check comes before the call is registered")
        XCTAssertTrue(prepare.contains("return prepareBlockedVoipIncomingReport(payload)"))
        let blocked = try slice(app, from: "private func prepareBlockedVoipIncomingReport(",
                                to: "private func prepareBlockedVoipGroupReport(")
        XCTAssertTrue(blocked.contains("PushKitProvider.blockedCallerSpec()"))
        assertOrder(blocked, "ghostPlaceholderCallIds.recordEnded(spec.uuid)", before: "return spec",
                    "the placeholder must be known as unanswerable before it reaches CallKit")
        // The call id of the push is remembered as ended, so a later `call_cancelled` push for the same call
        // becomes a placeholder too (`planIncomingCancelReport`) instead of reporting the real id as a new call.
        assertOrder(blocked, "recentlyEndedCallIds.recordEnded(payload.callId)", before: "return spec",
                    "the blocked call id must be in the ended ledger before the report returns")
        XCTAssertFalse(blocked.contains("prepareIncomingPushCall("), "the blocked path registers nothing")
        XCTAssertFalse(blocked.contains("activeCallKitId"))
        let finish = try slice(app, from: "func finishVoipPushReport(", to: "case .group:")
        XCTAssertTrue(finish.contains("guard !PushKitProvider.isBlockedCallerSpec(spec) else { return }"),
                      "the socket is not woken for a blocked caller's offer")
    }

    func testTheOpaqueChannelDropsEverythingOfABlockedSenderExceptTheLiveCallAndTheKeyOfAGroupCall() throws {
        let app = try code("QAudionApp/AppState.swift")
        let dispatch = try slice(app, from: "private func dispatchInboundOpaque(",
                                 to: "static func resolvePskDisplayMeta(")
        XCTAssertTrue(dispatch.contains("let senderBlocked: Bool = BlockedContactsStore.isBlocked(senderId)"))
        XCTAssertTrue(dispatch.contains("let blockedLiveCall: Bool = senderBlocked && isLiveOneToOneCallPeer(senderId)"),
                      "a call already live with the sender is the one exception to the one-to-one drop")
        XCTAssertTrue(dispatch.contains("let blockedDrop: Bool = senderBlocked && !blockedLiveCall"))
        // The QUAD wire: offers and key-exchange offers are named in the log, every other frame is dropped too,
        // before the key exchange runs.
        let quad = try slice(dispatch, from: "QAudionCapabilityExchange.parse(blob) {", to: "await cke.handleOffer(")
        XCTAssertTrue(quad.contains("if blockedDrop {"))
        XCTAssertTrue(quad.contains("case .keyExchangeOffer, .offer:"))
        XCTAssertTrue(quad.contains("kind=offer"))
        XCTAssertTrue(quad.contains("kind=opaque"))
        XCTAssertTrue(quad.contains("return"))
        XCTAssertFalse(quad.contains("default: break"), "the QUAD gate does not wave the other frames through")
        // The call piggy-backs, the JSON bundle (offer and answer) and a malformed bundle: dropped before they are routed.
        let piggy = try slice(dispatch, from: "if let piggy = CallPiggyBack.parse(blobStr) {",
                              to: "self?.routeInboundCallPiggyBack(")
        XCTAssertTrue(piggy.contains("if blockedDrop {"))
        let android = try slice(dispatch, from: "if let parsed = AndroidHandshakeEnvelope.parse(blobStr) {",
                                to: "self?.routeInboundAndroidOffer(parsed: parsed, senderId: senderId)")
        XCTAssertTrue(android.contains("if blockedDrop {"))
        XCTAssertTrue(android.contains("parsed.bundle.kind == .offer"))
        let malformed = try slice(dispatch, from: "AndroidHandshakeEnvelope.malformedBundleCallId(blobStr) {",
                                  to: "self?.handleUndecodableHandshakeBundle(")
        XCTAssertTrue(malformed.contains("if blockedDrop {"),
                      "ending a call on a malformed bundle would be an answer to the blocked sender")
        // A private file announcement and an attachment receipt are never wanted from a blocked sender, a live call or not.
        let file = try slice(dispatch, from: "FileAttachmentAnnounceWireEnvelope.parse(wirePayloadB64: blobStr) {",
                             to: "ChatFileAttachmentReceiver(appState: self)")
        XCTAssertTrue(file.contains("if senderBlocked {"))
        XCTAssertTrue(file.contains("kind=file"))
        let receipt = try slice(dispatch, from: "AttachmentReceiptEnvelope.parse(wirePayloadB64: blobStr) {",
                                to: "let store = ConversationStore()")
        XCTAssertTrue(receipt.contains("if senderBlocked {"))
        // No offer is handed to the call integration without passing the gate.
        XCTAssertEqual(count("if blockedDrop {", in: dispatch), 4, "QUAD, piggy-back, JSON bundle, malformed bundle")
    }

    func testTheKeyOfAGroupCallIsAcceptedFromABlockedSenderOnlyForACallTheUserIsIn() throws {
        let app = try code("QAudionApp/AppState.swift")
        let dispatch = try slice(app, from: "private func dispatchInboundOpaque(",
                                 to: "static func resolvePskDisplayMeta(")
        // Pre-bootstrap wrapper: nothing is opened for a blocked sender when the user is in no group call, and what
        // is opened is judged by the call id it names before it reaches the controller.
        let kms = try slice(dispatch, from: "(obj[\"qa_kms\"] as? NSNumber)?.intValue == 1",
                            to: "self.groupCallController?.onGroupCallControlEnvelope(")
        XCTAssertTrue(kms.contains("if blockedDrop && liveGroupCallIds().isEmpty {"))
        XCTAssertTrue(kms.contains("guard BlockPolicy.acceptsGroupCallControl( senderBlocked: senderBlocked,"),
                      "a plain guard: nothing like `guard true || ...` in front of the decision")
        XCTAssertTrue(kms.contains("callId: BlockPolicy.groupCallControlCallId(ofEnvelope: decoded),"))
        XCTAssertTrue(kms.contains("liveCallIds: self.liveGroupCallIds()"))
        // The control envelope itself: no ratchet step is spent without a live group call, and the call id decides.
        let ctrl = try slice(dispatch, from: "(obj[\"qa_grpcall_ctrl\"] as? NSNumber)?.intValue == 1",
                             to: "groupCallController?.onGroupCallControlEnvelope(json: json, fromUserId: senderId)")
        assertOrder(ctrl, "if senderBlocked && liveGroupCallIds().isEmpty {", before: "decryptV5Routed(",
                    "a blocked sender's control frame is not opened when the user is in no group call")
        XCTAssertTrue(ctrl.contains("guard BlockPolicy.acceptsGroupCallControl( senderBlocked: senderBlocked,"),
                      "a plain guard: nothing like `guard true || ...` in front of the decision")
        XCTAssertTrue(ctrl.contains("callId: BlockPolicy.groupCallControlCallId(ofEnvelope: json),"))
        XCTAssertTrue(ctrl.contains("liveCallIds: liveGroupCallIds()"))
        // What counts as "in a group call now".
        let live = try slice(app, from: "private func liveGroupCallIds(", to: "private func sharesKnownGroup(")
        for needle in ["controller.state", "add(groupCallControllerState)", "pendingGroupCallJoinId"] {
            XCTAssertTrue(live.contains(needle), "the live group calls must include \(needle)")
        }
        // What counts as "the other end of the live one-to-one call".
        let peer = try slice(app, from: "private func isLiveOneToOneCallPeer(", to: "private func liveGroupCallIds(")
        XCTAssertTrue(peer.contains("guard isInCall || (callState != .idle && callState != .ended) else { return false }"))
        XCTAssertTrue(peer.contains("BlockPolicy.isLiveCallPeer(senderId, livePeerId: callContactId)"))
    }

    func testAnAnswerTappedOnABlockedCallersNotificationAnswersAndLatchesNothing() throws {
        let app = try code("QAudionApp/AppState.swift")
        let action = try slice(app, from: "NotificationCenterService.shared.onIncomingCallAction = { [weak self] action, info in",
                               to: "switch action {")
        XCTAssertTrue(action.contains("if self.isBlockedCallNotification(info) {"),
                      "an unconditional `if`, nothing in front of the check")
        // Before the group routing: a group call a blocked contact created is not answered or joined either. Before
        // anything is answered or latched.
        assertOrder(action, "self.isBlockedCallNotification(info)", before: "handleGroupCallNotificationAction(",
                    "a group call notification of a blocked creator is cleared, not routed")
        // The same peer rule as every other notification (empty ids skipped, group call alerts judged by their creator).
        let helper = try slice(app, from: "private func isBlockedCallNotification(", to: "private func isLiveOneToOneCallPeer(")
        XCTAssertTrue(helper.contains(
            "BlockPolicy.suppressesNotification( userInfo: info as [AnyHashable: Any], blocked: BlockedContactsStore.loadBlockedIds())"))
        XCTAssertFalse(helper.contains("info[\"peer_id\"] ?? info[\"caller_id\"]"), "no second, different peer rule")
        let afterBlock = try slice(app, from: "self.isBlockedCallNotification(info)", to: "case .open:")
        XCTAssertTrue(afterBlock.contains("return"))
        XCTAssertLessThan(try XCTUnwrap(afterBlock.range(of: "return")).lowerBound,
                          try XCTUnwrap(afterBlock.range(of: "pendingNotificationAnswer = true")).lowerBound,
                          "the blocked caller returns before the answer is latched")
    }

    func testAMissedCallOfABlockedContactLeavesNoHistoryRowAndNoBanner() throws {
        let app = try code("QAudionApp/AppState.swift")
        let missed = try slice(app, from: "private func handleMissedCallEvent(",
                               to: "PersistentCallRecordStore.shared.beginCall(")
        XCTAssertTrue(missed.contains("if BlockedContactsStore.isBlocked(callerId) {"))
    }

    func testTheLocalNotificationServiceSuppressesBlockedPrivateSenders() throws {
        let service = try code("QAudionApp/Services/NotificationCenterService.swift")
        let local = try slice(service, from: "func scheduleLocal(", to: "let content = UNMutableNotificationContent()")
        XCTAssertTrue(local.contains("BlockPolicy.suppressesNotification(userInfo: userInfo"))
        let call = try slice(service, from: "func postIncomingCall(", to: "let content = UNMutableNotificationContent()")
        XCTAssertTrue(call.contains("if BlockPolicy.isBlocked(peerId, in: BlockedContactsStore.loadBlockedIds()) { return }"))
        XCTAssertFalse(call.contains("groupCall,"), "no exception for a group call: its peer is the creator")
        XCTAssertFalse(call.contains("!groupCall"))
    }

    // MARK: - Incoming messages, on every path

    func testPrivateUserContentOfABlockedSenderIsDroppedBeforeAnythingIsStored() throws {
        let app = try code("QAudionApp/AppState.swift")
        let receive = try slice(app, from: "private func handleIncomingMessage(", to: "private func finishInboundFrame(")
        XCTAssertGreaterThanOrEqual(count("BlockedContactsStore.isBlocked(senderId)", in: receive), 2,
                                    "one gate for content, one for a frame that does not decrypt")
        assertOrder(receive, "kind=msg", before: "let store = ConversationStore()",
                    "no conversation, row, preview or unread count for a blocked sender's content")
        assertOrder(receive, "kind=msg", before: "NotificationCenterService.shared.scheduleLocal(",
                    "no banner for a blocked sender's message")
        // After the decrypt, never before it: an unopened frame would skip a step of the sender's ratchet.
        assertOrder(receive, "let routed = InboundRouter.verdict(", before: "kind=msg",
                    "the frame is decrypted and routed first, so the service frames behind it still open")
        // The group layer keeps working: service payloads are routed before the content gate.
        assertOrder(receive, "handleInboundServicePayload(decryptedRaw, senderId: senderId)", before: "kind=msg",
                    "service payloads (group keys) are consumed before the content gate")
    }

    func testPrivateServicePayloadsOfABlockedSenderAreDroppedExceptTheSenderKeysOfAKnownGroup() throws {
        let app = try code("QAudionApp/AppState.swift")
        let service = try slice(app, from: "private func handleInboundServicePayload(", to: "private func handleInboundGroupControl(")
        XCTAssertTrue(service.contains("let blockedSender: Bool = BlockedContactsStore.isBlocked(senderId)"))
        XCTAssertTrue(service.contains("if BlockPolicy.dropsServicePayload( senderBlocked: blockedSender, payload: raw,"),
                      "an unconditional `if`, nothing in front of the decision")
        // The group is looked up in the local registry by the envelope's own group id, never taken on trust.
        XCTAssertTrue(service.contains("isKnownGroup: { groupId in GroupRegistry.shared.entries.contains {"))
        XCTAssertTrue(service.contains("BlockPolicy.normalized($0.id) == BlockPolicy.normalized(groupId)"))
        XCTAssertFalse(service.contains("detectGroupCtlType(raw)\n"), "no type-only decision")
        assertOrder(service, "BlockPolicy.dropsServicePayload(", before: "handleControlEnvelope(env, senderId: senderId)",
                    "reactions, edits and deletes are dropped for a blocked sender")
        assertOrder(service, "BlockPolicy.dropsServicePayload(", before: "handleInboundAvatarAnnounce(",
                    "a blocked sender's picture announcement is dropped")
    }

    func testMeshPacketsOfABlockedContactAreDroppedBeforeDecryption() throws {
        let app = try code("QAudionApp/AppState.swift")
        let mesh = try slice(app, from: "private func handleIncomingMeshMessage(", to: "attemptDecryptMeshWireBlob(")
        XCTAssertTrue(mesh.contains("guard !BlockedContactsStore.isBlocked(senderId) else {"))
        let receipt = try slice(app, from: "private func handleIncomingMeshReceipt(", to: "attemptDecryptMeshWireBlob(")
        XCTAssertTrue(receipt.contains("guard !BlockedContactsStore.isBlocked(senderId) else {"),
                      "a mesh receipt of a blocked contact never reaches the message status")
    }

    func testReadReceiptsOfABlockedContactAreIgnored() throws {
        let app = try code("QAudionApp/AppState.swift")
        let read = try slice(app, from: "private func handleReadReceipts(", to: "let store = ConversationStore()")
        XCTAssertTrue(read.contains("guard !BlockedContactsStore.isBlocked(senderId) else { return }"))
    }

    // MARK: - A blocked contact cannot put the user into a group

    func testAnAddNamingTheUserToAnUnknownGroupCreatesNothingWhenTheSenderOrTheAdminIsBlocked() throws {
        let app = try code("QAudionApp/AppState.swift")
        let apply = try slice(app, from: "fileprivate func applyMemberAdded(", to: "fileprivate func applyMemberRemoved(")
        XCTAssertTrue(apply.contains(
            "if BlockPolicy.refusesGroupJoin(by: [senderId, adminUserId], blocked: blockedForJoin) { RTLog.info(\"group\", \"block drop=1 kind=grp\") return }"),
                      "the refusal is an unconditional `if` that logs and returns")
        // The gate is in the branch of a group the device does not know (after the known-group branch), and
        // before anything is created: no registry entry, no group session, no "added to the group" notice.
        assertOrder(apply, "if let entry = GroupRegistry.shared.entry(for: groupId) {", before: "BlockPolicy.refusesGroupJoin(",
                    "a group the user is already in is not filtered: its gate is not above the known-group branch")
        assertOrder(apply, "BlockPolicy.refusesGroupJoin(", before: "GroupRegistry.shared.upsert(entry)",
                    "no registry entry for a group a blocked contact added the user to")
        assertOrder(apply, "BlockPolicy.refusesGroupJoin(", before: "GroupChatService.shared.session(",
                    "no group session either")
        assertOrder(apply, "BlockPolicy.refusesGroupJoin(", before: "name: AppState.groupAutoJoinedNotification",
                    "and no notice")
        assertOrder(apply, "BlockPolicy.refusesGroupJoin(", before: "GroupTombstoneStore.shared.clear(",
                    "a refused add must not lift a tombstone either")
        // Nothing is sent back: the refusal is a return after a log line.
        let gate = try slice(apply, from: "BlockPolicy.refusesGroupJoin(", to: "GroupTombstoneStore.shared.isTombstoned(groupId)")
        XCTAssertTrue(gate.contains("block drop=1 kind=grp"))
        XCTAssertTrue(gate.contains("return"))
    }

    func testAServerEventThatOnboardsTheUserIntoAnUnknownGroupIsDroppedWhenItsActorIsBlocked() throws {
        let app = try code("QAudionApp/AppState.swift")
        let event = try slice(app, from: "fileprivate func handleGroupMembershipChanged(", to: "bootstrapGroupFromServer(")
        XCTAssertTrue(event.contains(
            "if BlockPolicy.refusesGroupJoin(by: [actor], blocked: blockedForServerJoin) { RTLog.info(\"group\", \"block drop=1 kind=grp\") return }"),
                      "the refusal is an unconditional `if` that logs and returns")
        assertOrder(event, "guard members.contains(selfId) else { return }", before: "BlockPolicy.refusesGroupJoin(",
                    "only the unknown-group branch is filtered: a group the user is in stays unfiltered")
        assertOrder(event, "BlockPolicy.refusesGroupJoin(", before: "classifyMembershipEventForTombstone(",
                    "a refused event decides nothing about a tombstone")
        XCTAssertTrue(event.contains("block drop=1 kind=grp"))
    }

    // MARK: - The creator's side: members the server left out

    func testTheCreatorOfAGroupSendsNoKeyOrInviteBeforeTheServerHasAnswered() throws {
        let app = try code("QAudionApp/AppState.swift")
        let create = try slice(app, from: "public func createGroup(", to: "fileprivate func completeGroupCreation(")
        // createGroup itself sends nothing: the sender keys are captured (the seal-after-capture ordering), the
        // invites are built later.
        XCTAssertFalse(create.contains("shipSenderKeyInits("), "the keys are captured at creation, not sent")
        XCTAssertFalse(create.contains("groupSenderKeyCtlNotification"), "no key and no invite leaves createGroup")
        XCTAssertFalse(create.contains("GroupInviteEnvelope"))
        assertOrder(create, "pendingInitsAfterBootstrap(", before: "sealCreationMetadata(",
                    "the keys are captured from the send chain BEFORE the metadata is sealed")
        // The keys and invites go out after the create request answered, with the refused ids of its reply...
        assertOrder(create, "api.createGroup(", before: "self?.completeGroupCreation(",
                    "keys and invites follow the server's answer")
        XCTAssertTrue(create.contains("refused: res?.couldNotAdd ?? []"))
        // ...or at once when there is no server registration to wait for.
        XCTAssertTrue(create.contains("var registrationStarted: Bool = false"))
        XCTAssertTrue(create.contains("if !registrationStarted {"))
        XCTAssertGreaterThanOrEqual(count("completeGroupCreation(", in: create), 2)

        let complete = try slice(app, from: "fileprivate func completeGroupCreation(",
                                 to: "fileprivate func handleGroupMemberNotAdded(")
        XCTAssertTrue(complete.contains("if roster.notifies {"), "the cut is an unconditional `if` on the outcome")
        XCTAssertTrue(complete.contains(
            "for id in roster.dropped { GroupRegistry.shared.removeMember(groupId: groupHex, userId: id) }"),
            "every refused member leaves the registry")
        XCTAssertTrue(complete.contains(
            "GroupChatService.shared.dropUnaddedMembers( groupId: groupHex, members: requestedMembers, selfId: selfId, unadded: roster.dropped)"),
            "and the crypto roster")
        // Roster first (registry and crypto), then the notice, and only then the first key or invite.
        assertOrder(complete, "GroupAddRefusal.outcome(", before: "groupSenderKeyCtlNotification",
                    "the roster is cut before anything is sent")
        assertOrder(complete, "GroupRegistry.shared.removeMember(", before: "groupSenderKeyCtlNotification",
                    "the refused members are out of the registry before anything is sent")
        assertOrder(complete, "GroupChatService.shared.dropUnaddedMembers(", before: "groupSenderKeyCtlNotification",
                    "and out of the crypto roster")
        assertOrder(complete, "groupMembersNotAddedToastText =", before: "groupSenderKeyCtlNotification",
                    "the creator is told once")
        // Only the members who are in get a key, and the invite is built from the cut roster.
        XCTAssertTrue(complete.contains("where stay.contains(BlockPolicy.normalized(pending.recipient))"))
        XCTAssertTrue(complete.contains("g: groupHex, name: name, members: fullMembers,"))
        XCTAssertTrue(complete.contains("for recipient in fullMembers where recipient != selfId {"))
        XCTAssertEqual(count("groupSenderKeyCtlNotification", in: complete), 3, "keys, invites, member_added")
        // The notice is generic: a fixed text, no name, no number, no reason.
        XCTAssertTrue(complete.contains("defaultValue: \"Alcuni membri non sono stati aggiunti\""))
        XCTAssertFalse(complete.contains("DisplayName"), "the notice names nobody")
        // The reply field is parsed by the shared pure function.
        let api = try code("QAudionApp/Services/GroupMembershipApi.swift")
        XCTAssertTrue(api.contains("GroupAddRefusal.couldNotAdd(fromReply: json?[\"could_not_add\"])"))
    }

    func testAnAddTheServerRefusesTakesTheMemberBackOutAndShowsOneGenericError() throws {
        let app = try code("QAudionApp/AppState.swift")
        let add = try slice(app, from: "public func addGroupMembers(", to: "public func removeGroupMember(")
        XCTAssertTrue(add.contains("if GroupAddRefusal.isAddRefusal(statusCode: res.statusCode) {"))
        assertOrder(add, "GroupAddRefusal.isAddRefusal(", before: "guard res.isSuccess else { return }",
                    "the refusal is judged before the generic non-success return")
        XCTAssertTrue(add.contains("self?.handleGroupMemberNotAdded(groupHex: groupHex, member: newMember)"))
        let handler = try slice(app, from: "fileprivate func handleGroupMemberNotAdded(",
                                to: "fileprivate func applyGroupCreationResult(")
        XCTAssertTrue(handler.contains("GroupRegistry.shared.removeMember(groupId: groupHex, userId: member)"))
        XCTAssertTrue(handler.contains("GroupChatService.shared.dropUnaddedMembers("))
        XCTAssertTrue(handler.contains("groupMembersNotAddedToastText = String("))
        XCTAssertTrue(handler.contains("defaultValue: \"Impossibile aggiungere il membro\""))
        XCTAssertFalse(handler.contains("DisplayName"), "the error names nobody")
    }

    func testTheGenericNoticeIsShownByTheContentViewSnackbar() throws {
        let view = try code("QAudionApp/Views/ContentView.swift")
        let notice = try slice(view, from: ".onChange(of: appState.groupMembersNotAddedToastText) { text in",
                               to: "appState.groupMembersNotAddedToastText = nil")
        XCTAssertTrue(notice.contains("snackbarHost.show(.init(text: text, severity: .error))"))
        let catalog = try rawText("QAudionApp/Localizable.xcstrings")
        for key in ["\"group.create.members_not_added\"", "\"group.add.member_not_added\""] {
            XCTAssertEqual(count(key, in: catalog), 1, "\(key) is in the catalog once")
        }
    }

    // MARK: - Nothing is sent on its own to a blocked contact

    func testAFrameOfABlockedSenderThatDoesNotOpenStartsNoSessionRecovery() throws {
        let app = try code("QAudionApp/AppState.swift")
        let receive = try slice(app, from: "private func handleIncomingMessage(", to: "private func finishInboundFrame(")
        // CONTROL recovery (`handleUndecryptableControlFrame` buffers the frame and calls `ensureV4Session`, a
        // bootstrap message to the sender) comes after the blocked-sender gate; the CHAT retry/nack after it too.
        assertOrder(receive, "kind=undec", before: "handleUndecryptableControlFrame(",
                    "no session bootstrap traffic to a blocked sender")
        assertOrder(receive, "kind=undec", before: "bufferOneToOneCiphertext(",
                    "no retry buffer for a blocked sender's frame")
        assertOrder(receive, "kind=undec", before: "sendDecryptNackDebounced(",
                    "no resend request to a blocked sender")
    }

    func testAControlFrameOfABlockedGroupMateThatDoesNotOpenKeepsTheNormalRetryPath() throws {
        let app = try code("QAudionApp/AppState.swift")
        let receive = try slice(app, from: "private func handleIncomingMessage(", to: "private func finishInboundFrame(")
        // The settle decision is the pure rule: blocked, and not (a CONTROL frame from somebody who shares a group).
        XCTAssertTrue(receive.contains("if BlockPolicy.settlesUndecryptableFrame("),
                      "an unconditional `if`, nothing in front of the decision")
        let gate = try slice(receive, from: "BlockPolicy.settlesUndecryptableFrame(", to: "kind=undec")
        XCTAssertTrue(gate.contains("senderBlocked: BlockedContactsStore.isBlocked(senderId),"))
        XCTAssertTrue(gate.contains("isControl: wireClass == .v5,"))
        XCTAssertTrue(gate.contains("sharesKnownGroup: { self.sharesKnownGroup(with: senderId) }"))
        // The control frame that is not settled reaches the ordinary CONTROL handler (buffer, retry, recovery).
        assertOrder(receive, "kind=undec", before: "if wireClass == .v5 { handleUndecryptableControlFrame(",
                    "the blocked-sender gate precedes the ordinary CONTROL handler, which a group mate still reaches")
        // "Shares a group" is read from the local registry.
        let shares = try slice(app, from: "private func sharesKnownGroup(", to: "private func planIncomingCancelReport(")
        XCTAssertTrue(shares.contains("BlockPolicy.sharesGroup("))
        XCTAssertTrue(shares.contains("GroupRegistry.shared.entries.map { $0.members }"))
    }

    func testTheNameLookupSkipsABlockedSender() throws {
        let app = try code("QAudionApp/AppState.swift")
        let receive = try slice(app, from: "private func handleIncomingMessage(", to: "private func finishInboundFrame(")
        XCTAssertTrue(receive.contains(
            "if !BlockedContactsStore.isBlocked(senderId) { NameResolutionService.shared.maybeRefreshFromChatActivity(userId: senderId) }"))
    }

    // MARK: - The list is loaded again when a first load fails or the backend is not there yet

    func testTheBlockedListIsRequestedWhenTheBackendIsBuiltAndRetriedAfterAFailure() throws {
        let app = try code("QAudionApp/AppState.swift")
        let connect = try slice(app, from: "private func connectPersistentSocket() {", to: "ChatOutboxDrain.shared.configure(")
        assertOrder(connect, "self.liveProvider = provider", before: "ContactBlockService.shared.refreshFromServerIfDue()",
                    "every sign-in and cold start builds the backend here: the list is requested right after")
        let service = try code("QAudionApp/Services/ContactBlockService.swift")
        XCTAssertTrue(service.contains("coordinator.refreshFromServerWithRetry()"),
                      "a failed or early request is retried, not left until the next reconnect")
        let refresh = try slice(service, from: "func refreshFromServerIfDue() {", to: "func forgetAccount() {")
        assertOrder(refresh, "refreshTask?.cancel()", before: "refreshTask = Task",
                    "the latest request replaces a retry that is waiting")
    }

    func testSigningOutEndsTheRefreshOfTheOldAccount() throws {
        let service = try code("QAudionApp/Services/ContactBlockService.swift")
        let forget = try slice(service, from: "func forgetAccount() {", to: "func setBlocked(")
        XCTAssertTrue(forget.contains("refreshTask?.cancel()"))
        assertOrder(forget, "coordinator.forgetSession()", before: "BlockedContactsStore.clear()",
                    "the answers still owed to the old account are discarded before the list is wiped")
        XCTAssertTrue(service.contains("case .failed(.accountChanged):"),
                      "an account that left gets no retry offer for the next one")
    }

    // MARK: - Foreground alerts and group calls

    func testAForegroundAlertFromABlockedPeerIsNotPresented() throws {
        let service = try code("QAudionApp/Services/NotificationCenterService.swift")
        let present = try slice(service, from: "willPresent notification: UNNotification", to: "private func isCallInFlight()")
        XCTAssertTrue(present.contains(
            "BlockPolicy.suppressesNotification(userInfo: alertInfo, blocked: BlockedContactsStore.loadBlockedIds())"))
        assertOrder(present, "BlockPolicy.suppressesNotification(", before: "return []",
                    "a suppressed alert presents nothing: no banner, list entry, sound or badge")
        assertOrder(present, "return []", before: "MissedCallAlertPolicy.foreground(",
                    "the block decides before the normal presentation rules")
    }

    func testEveryGroupCallSourceGoesThroughTheCreatorDecisionAndNoRosterIsConsulted() throws {
        let app = try code("QAudionApp/AppState.swift")
        // WebSocket invite, PushKit group push and notification action all end in `presentIncomingGroupCall`.
        let present = try slice(app, from: "func presentIncomingGroupCall(", to: "if isGroupCallHandled(invite.callId) {")
        XCTAssertTrue(present.contains("if !groupCallRingsForCreator(invite.creatorId) {"))
        XCTAssertTrue(present.contains("block drop=1 kind=grpcall"))
        XCTAssertTrue(present.contains("return false"))
        let helper = try slice(app, from: "func groupCallRingsForCreator(", to: "func presentIncomingGroupCall(")
        XCTAssertTrue(helper.contains(
            "BlockPolicy.ringsForGroupCall(creatorId: creatorId, blocked: BlockedContactsStore.loadBlockedIds())"))
        // A blocked creator never rings, so there is no local-roster exception: no registry, no member list, no user id
        // of our own, and the invite's group id is never consulted.
        XCTAssertFalse(helper.contains("GroupRegistry"), "no registry lookup")
        XCTAssertFalse(helper.contains("localGroupMembers"))
        XCTAssertFalse(helper.contains("selfId"))
        XCTAssertFalse(helper.contains("groupId"), "the group id of the invite is never consulted")
        XCTAssertFalse(helper.contains("invite."), "the decision reads the creator and the blocked list only")
        // The WS callback, the notification action and the push path all reach `presentIncomingGroupCall`.
        XCTAssertGreaterThanOrEqual(count("presentIncomingGroupCall(", in: app), 4)
    }

    func testAGroupPushOfABlockedCreatorIsReportedAsAGenericPlaceholderAndEndedAtOnce() throws {
        let app = try code("QAudionApp/AppState.swift")
        let report = try slice(app, from: "private func prepareVoipGroupReport(", to: "private func prepareVoipOpaqueReport(")
        assertOrder(report, "groupCallRingsForCreator(payload.creatorId)", before: "prepareIncomingPushGroupCall(",
                    "a blocked creator leaves no trace: the check comes before the invite is built")
        XCTAssertTrue(report.contains(
            "if !groupCallRingsForCreator(payload.creatorId) { return prepareBlockedVoipGroupReport(payload) }"),
                      "the blocked report is returned unconditionally when the call does not ring")
        let blocked = try slice(app, from: "private func prepareBlockedVoipGroupReport(", to: "private func prepareVoipGroupReport(")
        XCTAssertTrue(blocked.contains("PushKitProvider.blockedCallerSpec()"))
        assertOrder(blocked, "ghostPlaceholderCallIds.recordEnded(spec.uuid)", before: "return spec",
                    "the placeholder is unanswerable before it reaches CallKit")
        XCTAssertFalse(blocked.contains("prepareIncomingPushGroupCall("), "nothing about the call is registered")
        XCTAssertFalse(blocked.contains("groupCallKitId"))
        XCTAssertFalse(blocked.contains("creatorName"), "the creator's name never reaches the system screen")
        // The spec has an end reason, so the group branch of the push handler does not ring or wake the socket.
        let finish = try slice(app, from: "func finishVoipPushReport(", to: "case .opaque:")
        XCTAssertTrue(finish.contains("case .group: guard spec.endReason == nil else { return }"))
    }

    // MARK: - The privacy screen shows the real list

    func testThePrivacyScreenShowsTheRealBlockedListNotTheLegacySettingsCopy() throws {
        let screen = try code("QAudionApp/Views/Settings/PrivacySettingsScreen.swift")
        XCTAssertFalse(screen.contains("container.viewModel.blockedUserIds"), "the legacy settings list is not displayed")
        XCTAssertTrue(screen.contains("BlockedUsersPrivacySection()"))
        let section = try slice(screen, from: "private struct BlockedUsersPrivacySection: View {", to: "SettingsSectionHeader(")
        XCTAssertTrue(section.contains("BlockedContactsStore.loadBlockedIds().count"))
        XCTAssertTrue(screen.contains("publisher(for: .blockedContactsDidChange)"),
                      "the count follows a block, an unblock or the reload of the server's list")
    }

    func testATypingIndicatorOfABlockedContactNeverShowsAndNothingIsSentToThemOnItsOwn() throws {
        let app = try code("QAudionApp/AppState.swift")
        let typing = try slice(app, from: "private func handleTypingIndicator(", to: "NotificationCenter.default.post(")
        XCTAssertTrue(typing.contains("if BlockedContactsStore.isBlocked(senderId) { return }"))
        let avatar = try slice(app, from: "private func maybeAnnounceAvatarTo(", to: "avatarAnnounceCoordinator.maybeAnnounce(")
        XCTAssertTrue(avatar.contains("if BlockedContactsStore.isBlocked(peerId) { return }"))
    }
}
