import XCTest
@testable import QAudionEngine

/// BLOCK — the rules for a contact the user blocked (`BlockPolicy`) and the one function that blocks, unblocks and
/// reloads the list (`ContactBlockCoordinator`), driven with a fake server and an in-memory list.
///
/// What this proves: who is considered blocked, which private service payloads, group calls and local notifications a
/// block suppresses (and what it deliberately lets through: the sender keys of a group the user is already in, the
/// key of a group call the user is in, the traffic of a call already live), how the creator's roster is cut when the
/// server leaves members out, and that the local list never says "blocked" while the server does not. What it cannot prove: that the app's receive paths call these rules (the
/// wiring is pinned by `ContactBlockWiringTests`) or how the screens behave on a phone.
@MainActor
final class ContactBlockingTests: XCTestCase {

    // MARK: - Fakes

    private struct Refused: Error {}

    /// A server that keeps a blocked list, can be told to refuse each request, and can hold `blockContact`
    /// until the test opens a gate. Its state is only touched on the main actor (the requests hop there to
    /// record themselves), so the test can read it without a race.
    private final class FakeContactsApi: ContactsApi, @unchecked Sendable {
        var serverBlocked: [BlockedContact] = []
        var blockCalls: [String] = []
        var unblockCalls: [String] = []
        var listCalls = 0
        var refuseBlock = false
        var refuseUnblock = false
        var refuseList = false
        var blockGate: Gate?
        /// Holds `getBlockedContacts` after it recorded itself, until the test opens it.
        var listGate: Gate?

        func discoverContacts(phoneHashes: [String]) async throws -> [DiscoveredContact] { [] }
        func addContact(userId: String) async throws {}
        func removeContact(userId: String) async throws {}
        func listContacts() async throws -> [DiscoveredContact] { [] }
        func syncContacts(entries: [SyncContactEntry]) async throws {}

        func blockContact(userId: String) async throws {
            await MainActor.run { self.blockCalls.append(userId) }
            if let gate = blockGate { await gate.wait() }
            if refuseBlock { throw Refused() }
            await MainActor.run {
                if !self.serverBlocked.contains(where: { $0.userId == userId }) {
                    self.serverBlocked.append(BlockedContact(userId: userId))
                }
            }
        }

        func unblockContact(userId: String) async throws {
            await MainActor.run { self.unblockCalls.append(userId) }
            if refuseUnblock { throw Refused() }
            await MainActor.run { self.serverBlocked.removeAll { $0.userId == userId } }
        }

        func getBlockedContacts() async throws -> [BlockedContact] {
            await MainActor.run { self.listCalls += 1 }
            if let gate = listGate { await gate.wait() }
            if refuseList { throw Refused() }
            return await MainActor.run { self.serverBlocked }
        }
    }

    /// Suspends `wait()` until `release()`; safe from any thread.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    c.resume()
                } else {
                    continuation = c
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            opened = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    private final class MemoryList: BlockedListStorage {
        var ids = Set<String>()
        func blockedIds() -> Set<String> { ids }
        func insert(_ userId: String) { ids.insert(userId) }
        func remove(_ userId: String) {
            let key = BlockPolicy.normalized(userId)
            ids = ids.filter { BlockPolicy.normalized($0) != key }
        }
        func replaceAll(_ new: Set<String>) { ids = new }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func make(
        api: FakeContactsApi?, list: MemoryList = MemoryList(), clock: Clock = Clock()
    ) -> (ContactBlockCoordinator, MemoryList) {
        let coordinator = ContactBlockCoordinator(
            api: { api }, storage: list, now: { clock.now })
        return (coordinator, list)
    }

    // MARK: - BlockPolicy.isBlocked

    func testASenderInTheListIsBlockedAndOthersAreNot() {
        let blocked: Set<String> = ["u-1", "u-2"]
        XCTAssertTrue(BlockPolicy.isBlocked("u-1", in: blocked))
        XCTAssertFalse(BlockPolicy.isBlocked("u-3", in: blocked))
    }

    func testIdentifiersCompareTrimmedAndCaseInsensitively() {
        let blocked: Set<String> = ["B0D7BA30-655B-420D-A4ED-8848EFC51C98"]
        XCTAssertTrue(BlockPolicy.isBlocked("b0d7ba30-655b-420d-a4ed-8848efc51c98", in: blocked))
        XCTAssertTrue(BlockPolicy.isBlocked("  B0D7BA30-655B-420D-A4ED-8848EFC51C98\n", in: blocked))
        XCTAssertTrue(BlockPolicy.isBlocked("X", in: ["  x "]))
    }

    func testAnAbsentOrEmptySenderIsNeverBlocked() {
        XCTAssertFalse(BlockPolicy.isBlocked(nil, in: ["u-1"]))
        XCTAssertFalse(BlockPolicy.isBlocked("", in: ["u-1", ""]))
        XCTAssertFalse(BlockPolicy.isBlocked("   ", in: ["u-1", "  "]))
        XCTAssertFalse(BlockPolicy.isBlocked("u-1", in: []))
    }

    func testNormalizedSetDropsEmptyEntries() {
        XCTAssertEqual(BlockPolicy.normalizedSet([" A ", "", "b", "B"]), ["a", "b"])
    }

    // MARK: - BlockPolicy.dropsServicePayload

    private func keyEnvelope(_ type: String, group: String) -> String {
        "{\"qa_grp\":1,\"t\":\"\(type)\",\"g\":\"\(group)\",\"e\":1,\"seed\":\"AAAA\",\"idx\":0}"
    }

    private func groupEnvelope(_ type: String, group: String = "ab12cd34") -> String {
        "{\"qa_grp\":1,\"t\":\"\(type)\",\"g\":\"\(group)\"}"
    }

    func testAServicePayloadFromASenderWhoIsNotBlockedIsNeverDropped() {
        let payloads = [
            "", "{}", "plain text", keyEnvelope("sender_key_init", group: "ab12"),
            groupEnvelope("group_invite"), groupEnvelope("member_added"),
        ]
        for raw in payloads {
            XCTAssertFalse(
                BlockPolicy.dropsServicePayload(senderBlocked: false, payload: raw, isKnownGroup: { _ in false }),
                raw)
        }
    }

    func testEverythingAPrivateBlockedSenderSendsOnTheServiceChannelIsDropped() {
        // reactions, edits, deletes, picture announcements, screenshot requests, timers, resend requests
        let payloads = [
            "{\"qa_ctl\":1,\"t\":\"ss_req\"}",
            "{\"qa_ctl\":1,\"t\":\"decrypt_nack\",\"target\":\"x\"}",
            "{\"qa_ctl\":1,\"t\":\"ephemeral_timer\",\"timer_sec\":10}",
            "{}", "not json", "",
        ]
        for raw in payloads {
            XCTAssertTrue(
                BlockPolicy.dropsServicePayload(senderBlocked: true, payload: raw, isKnownGroup: { _ in true }),
                raw)
        }
    }

    func testASenderKeyOfAGroupTheUserIsInPassesFromABlockedSender() {
        // Without it the blocked person's later messages in a group both are in could not be read.
        for type in ["sender_key_init", "sender_key_rotate"] {
            XCTAssertFalse(
                BlockPolicy.dropsServicePayload(
                    senderBlocked: true, payload: keyEnvelope(type, group: "ab12cd34"),
                    isKnownGroup: { $0 == "ab12cd34" }),
                "\(type) of a group the user is already in")
        }
    }

    func testTheGroupIsLookedUpByTheEnvelopesOwnGroupId() {
        var asked: [String] = []
        _ = BlockPolicy.dropsServicePayload(
            senderBlocked: true, payload: keyEnvelope("sender_key_rotate", group: "cd34ef56"),
            isKnownGroup: { asked.append($0); return true })
        XCTAssertEqual(asked, ["cd34ef56"])
        // A sender who is not blocked is never looked up.
        asked = []
        _ = BlockPolicy.dropsServicePayload(
            senderBlocked: false, payload: keyEnvelope("sender_key_rotate", group: "cd34ef56"),
            isKnownGroup: { asked.append($0); return true })
        XCTAssertTrue(asked.isEmpty)
    }

    func testASenderKeyOfAGroupTheUserIsNotInIsDropped() {
        for type in ["sender_key_init", "sender_key_rotate"] {
            XCTAssertTrue(
                BlockPolicy.dropsServicePayload(
                    senderBlocked: true, payload: keyEnvelope(type, group: "ab12cd34"),
                    isKnownGroup: { _ in false }),
                "\(type) must not reach a group the user has no part in")
            XCTAssertTrue(
                BlockPolicy.dropsServicePayload(
                    senderBlocked: true, payload: keyEnvelope(type, group: "ab12cd34"),
                    isKnownGroup: { $0 == "ffffffff" }),
                "another known group does not vouch for this one")
        }
    }

    func testEveryOtherGroupEnvelopeOfABlockedSenderIsDroppedEvenForAKnownGroup() {
        // Invites, member changes, removals and leaves are not key material: from a blocked sender they are dropped
        // whether or not the group is known.
        for type in ["group_invite", "member_added", "member_removed", "member_left", "group_member_added",
                     "group_member_removed", "group_invite_decline", "something_new"] {
            XCTAssertTrue(
                BlockPolicy.dropsServicePayload(
                    senderBlocked: true, payload: groupEnvelope(type), isKnownGroup: { _ in true }),
                "\(type) is not group key material")
        }
    }

    func testAMalformedOrForeignKeyEnvelopeOfABlockedSenderIsDropped() {
        let payloads = [
            "{\"qa_grp\":2,\"t\":\"sender_key_init\",\"g\":\"ab12cd34\"}",      // the group-call envelope family
            "{\"qa_grp\":0,\"t\":\"sender_key_init\",\"g\":\"ab12cd34\"}",
            "{\"t\":\"sender_key_init\",\"g\":\"ab12cd34\"}",                    // no marker
            "{\"qa_grp\":1,\"t\":\"sender_key_init\"}",                          // no group
            "{\"qa_grp\":1,\"t\":\"sender_key_init\",\"g\":\"  \"}",             // empty group
            "{\"qa_grp\":1,\"t\":\"sender_key_init\",\"g\":12}",                 // group is not a string
            "{\"qa_grp\":1,\"g\":\"ab12cd34\"}",                                 // no type
            "[\"qa_grp\"]",
        ]
        for raw in payloads {
            XCTAssertNil(BlockPolicy.groupKeyGroupId(inServicePayload: raw), raw)
            XCTAssertTrue(
                BlockPolicy.dropsServicePayload(senderBlocked: true, payload: raw, isKnownGroup: { _ in true }), raw)
        }
        XCTAssertEqual(BlockPolicy.groupKeyGroupId(inServicePayload: keyEnvelope("sender_key_init", group: "ab12")), "ab12")
        XCTAssertEqual(BlockPolicy.groupKeyTypes, ["sender_key_init", "sender_key_rotate"])
    }

    // MARK: - BlockPolicy group join

    func testAGroupJoinThroughABlockedActorIsRefused() {
        let blocked: Set<String> = ["u-1"]
        XCTAssertTrue(BlockPolicy.refusesGroupJoin(by: ["u-1"], blocked: blocked))
        XCTAssertTrue(BlockPolicy.refusesGroupJoin(by: ["U-2", "  U-1 "], blocked: blocked),
                      "the sender of the envelope or the admin it names: either one is enough, case and spaces aside")
        XCTAssertFalse(BlockPolicy.refusesGroupJoin(by: ["u-2", "u-3"], blocked: blocked))
    }

    func testAGroupJoinWithNoActorOrNothingBlockedIsNotRefused() {
        XCTAssertFalse(BlockPolicy.refusesGroupJoin(by: [], blocked: ["u-1"]))
        XCTAssertFalse(BlockPolicy.refusesGroupJoin(by: ["", "  "], blocked: ["u-1", ""]),
                       "an empty id (a snapshot has no actor) is never blocked")
        XCTAssertFalse(BlockPolicy.refusesGroupJoin(by: ["u-1"], blocked: []))
    }

    // MARK: - BlockPolicy group calls

    func testAGroupCallOfACreatorWhoIsNotBlockedRings() {
        XCTAssertTrue(BlockPolicy.ringsForGroupCall(creatorId: "u-2", blocked: ["u-1"]))
        XCTAssertTrue(BlockPolicy.ringsForGroupCall(creatorId: "u-2", blocked: []),
                      "a call created by someone else rings, even when a blocked contact takes part in it")
    }

    func testAGroupCallOfABlockedCreatorNeverRings() {
        // The decision has two inputs, the creator and the blocked list: no roster, no shared group, no group id
        // of the invite. A blocked creator who shares a group with the user gets nothing from it.
        XCTAssertFalse(BlockPolicy.ringsForGroupCall(creatorId: "u-1", blocked: ["u-1"]))
        XCTAssertFalse(BlockPolicy.ringsForGroupCall(creatorId: "  U-1 ", blocked: ["u-1"]),
                       "ids compare trimmed and case-insensitively")
    }

    func testAnInviteWithNoCreatorCannotBeMatchedAgainstTheBlockedList() {
        XCTAssertTrue(BlockPolicy.ringsForGroupCall(creatorId: "", blocked: ["u-1", ""]))
    }

    // MARK: - BlockPolicy shared groups and the frame that does not open

    func testTwoPeopleShareAGroupOnlyWhenOneGroupHoldsBoth() {
        XCTAssertTrue(BlockPolicy.sharesGroup(
            selfId: "me", otherId: "u-1", groupMembers: [["u-3"], ["me", "U-1 ", "u-3"]]))
        XCTAssertTrue(BlockPolicy.sharesGroup(
            selfId: "ME", otherId: "  u-1", groupMembers: [["u-1", "me"]]), "trimmed and case-insensitive")
        XCTAssertFalse(BlockPolicy.sharesGroup(
            selfId: "me", otherId: "u-1", groupMembers: [["u-1", "u-3"], ["me", "u-3"]]),
            "the two are in different groups")
        XCTAssertFalse(BlockPolicy.sharesGroup(selfId: "me", otherId: "u-1", groupMembers: []))
        XCTAssertFalse(BlockPolicy.sharesGroup(selfId: "", otherId: "u-1", groupMembers: [["u-1", ""]]),
                       "without knowing who the user is nothing is shared")
        XCTAssertFalse(BlockPolicy.sharesGroup(selfId: "me", otherId: " ", groupMembers: [["me", " "]]))
    }

    func testAFrameThatDoesNotOpenIsSettledForABlockedSenderExceptAControlFrameFromAGroupMate() {
        // Not blocked: never settled here.
        XCTAssertFalse(BlockPolicy.settlesUndecryptableFrame(
            senderBlocked: false, isControl: true, sharesKnownGroup: { true }))
        XCTAssertFalse(BlockPolicy.settlesUndecryptableFrame(
            senderBlocked: false, isControl: false, sharesKnownGroup: { false }))
        // Blocked, chat class: always settled, the group is not even asked.
        var asked = 0
        XCTAssertTrue(BlockPolicy.settlesUndecryptableFrame(
            senderBlocked: true, isControl: false, sharesKnownGroup: { asked += 1; return true }))
        XCTAssertEqual(asked, 0)
        // Blocked, control class: settled unless the sender shares a group with the user.
        XCTAssertTrue(BlockPolicy.settlesUndecryptableFrame(
            senderBlocked: true, isControl: true, sharesKnownGroup: { asked += 1; return false }))
        XCTAssertFalse(BlockPolicy.settlesUndecryptableFrame(
            senderBlocked: true, isControl: true, sharesKnownGroup: { asked += 1; return true }),
            "a control frame from a blocked co-member keeps the normal retry path")
        XCTAssertEqual(asked, 2)
    }

    // MARK: - BlockPolicy group-call control and the live one-to-one call

    func testTheKeyOfAGroupCallIsAcceptedFromABlockedSenderOnlyForACallTheUserIsIn() {
        XCTAssertTrue(BlockPolicy.acceptsGroupCallControl(
            senderBlocked: false, callId: nil, liveCallIds: []), "not blocked: nothing to decide")
        XCTAssertTrue(BlockPolicy.acceptsGroupCallControl(
            senderBlocked: false, callId: "call-9", liveCallIds: []))
        XCTAssertTrue(BlockPolicy.acceptsGroupCallControl(
            senderBlocked: true, callId: "Call-1", liveCallIds: ["other", " call-1 "]),
            "the call the user is in, ids compared trimmed and case-insensitively")
        XCTAssertFalse(BlockPolicy.acceptsGroupCallControl(
            senderBlocked: true, callId: "call-2", liveCallIds: ["call-1"]), "another call")
        XCTAssertFalse(BlockPolicy.acceptsGroupCallControl(
            senderBlocked: true, callId: "call-1", liveCallIds: []), "the user is in no group call")
        XCTAssertFalse(BlockPolicy.acceptsGroupCallControl(
            senderBlocked: true, callId: nil, liveCallIds: ["call-1"]), "an envelope that names no call")
        XCTAssertFalse(BlockPolicy.acceptsGroupCallControl(
            senderBlocked: true, callId: "  ", liveCallIds: ["", "  "]))
    }

    func testTheCallIdOfAGroupCallEnvelopeComesFromTheRealEnvelope() throws {
        let ack = GroupKeyEnvelope.ack(callId: "call-7", epoch: 3).encode()
        XCTAssertEqual(BlockPolicy.groupCallControlCallId(ofEnvelope: try XCTUnwrap(ack)), "call-7")
        let nack = GroupKeyEnvelope.nack(callId: "call-8", epoch: 1).encode()
        XCTAssertEqual(BlockPolicy.groupCallControlCallId(ofEnvelope: try XCTUnwrap(nack)), "call-8")
        // Not a valid group-call envelope: no call id, so a blocked sender's envelope is not accepted.
        XCTAssertNil(BlockPolicy.groupCallControlCallId(ofEnvelope: "not json"))
        XCTAssertNil(BlockPolicy.groupCallControlCallId(ofEnvelope: "{\"qa_grp\":1,\"t\":\"sender_key_init\",\"g\":\"ab\"}"))
        XCTAssertNil(BlockPolicy.groupCallControlCallId(ofEnvelope: "{\"qa_grp\":2,\"t\":\"bogus\",\"g\":\"c\",\"e\":1}"))
    }

    func testTheOtherEndOfTheLiveCallIsRecognised() {
        XCTAssertTrue(BlockPolicy.isLiveCallPeer("u-1", livePeerId: "u-1"))
        XCTAssertTrue(BlockPolicy.isLiveCallPeer("  U-1", livePeerId: "u-1 "), "trimmed and case-insensitive")
        XCTAssertFalse(BlockPolicy.isLiveCallPeer("u-1", livePeerId: "u-2"))
        XCTAssertFalse(BlockPolicy.isLiveCallPeer("u-1", livePeerId: nil), "no call is live")
        XCTAssertFalse(BlockPolicy.isLiveCallPeer("", livePeerId: ""), "an empty id is nobody")
        XCTAssertFalse(BlockPolicy.isLiveCallPeer(" ", livePeerId: nil))
    }

    // MARK: - GroupAddRefusal: the creator's side

    func testCouldNotAddIsReadFromTheReplyFieldAndNothingElse() {
        XCTAssertEqual(GroupAddRefusal.couldNotAdd(fromReply: ["u-1", " U-2 ", "u-1", "", 7, "u-3"] as [Any]),
                       ["u-1", "U-2", "u-3"], "strings only, trimmed, once each")
        XCTAssertEqual(GroupAddRefusal.couldNotAdd(fromReply: nil), [])
        XCTAssertEqual(GroupAddRefusal.couldNotAdd(fromReply: "u-1"), [], "a field that is not an array")
        XCTAssertEqual(GroupAddRefusal.couldNotAdd(fromReply: [] as [Any]), [])
        XCTAssertEqual(GroupAddRefusal.couldNotAdd(fromReply: [["id": "u-1"]] as [Any]), [])
    }

    func testTheReplyOfAGroupCreateIsParsedFromRealJson() throws {
        let json = "{\"group_id\":\"g\",\"members\":[\"me\",\"u-2\"],\"could_not_add\":[\"u-1\",\"u-3\"]}"
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(GroupAddRefusal.couldNotAdd(fromReply: object["could_not_add"]), ["u-1", "u-3"])
        let plain = "{\"group_id\":\"g\",\"members\":[\"me\"]}"
        let none = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])
        XCTAssertEqual(GroupAddRefusal.couldNotAdd(fromReply: none["could_not_add"]), [])
    }

    func testTheRosterIsCutToTheMembersWhoAreIn() {
        let outcome = GroupAddRefusal.outcome(
            requested: ["me", "u-1", "u-2", "u-3"], refused: ["U-1", "u-3"], selfId: "me")
        XCTAssertEqual(outcome.kept, ["me", "u-2"], "original order and spelling")
        XCTAssertEqual(outcome.dropped, ["u-1", "u-3"], "spelled as requested")
        XCTAssertTrue(outcome.notifies)
    }

    func testTheCreatorIsNeverCutAndNobodyIsNotifiedWhenNobodyAskedForIsOut() {
        let self1 = GroupAddRefusal.outcome(requested: ["me", "u-1"], refused: ["me"], selfId: "ME")
        XCTAssertEqual(self1.kept, ["me", "u-1"])
        XCTAssertFalse(self1.notifies)
        let unknown = GroupAddRefusal.outcome(requested: ["me", "u-1"], refused: ["u-9"], selfId: "me")
        XCTAssertEqual(unknown.kept, ["me", "u-1"])
        XCTAssertFalse(unknown.notifies, "a refused id nobody asked for changes nothing and says nothing")
        let clean = GroupAddRefusal.outcome(requested: ["me", "u-1"], refused: [], selfId: "me")
        XCTAssertEqual(clean.kept, ["me", "u-1"])
        XCTAssertFalse(clean.notifies)
    }

    func testTheAdminListIsCutTheSameWay() {
        let admins = GroupAddRefusal.outcome(requested: ["me", "u-1"], refused: ["u-1"], selfId: "me")
        XCTAssertEqual(admins.kept, ["me"])
    }

    func testOnlyAForbiddenAnswerIsTheAddRefusal() {
        XCTAssertTrue(GroupAddRefusal.isAddRefusal(statusCode: 403))
        XCTAssertEqual(GroupAddRefusal.addRefusedStatus, 403)
        for status in [200, 201, 401, 404, 409, 410, 422, 500] {
            XCTAssertFalse(GroupAddRefusal.isAddRefusal(statusCode: status), "\(status)")
        }
    }

    // MARK: - BlockPolicy notifications

    func testAPrivateMessageOrCallNotificationOfABlockedContactIsSuppressed() {
        let blocked: Set<String> = ["u-1"]
        let message: [AnyHashable: Any] = ["conversationId": "c", "peerUserId": "U-1"]
        let call: [AnyHashable: Any] = ["call_id": "x", "peer_id": "u-1", "has_video": "0"]
        XCTAssertTrue(BlockPolicy.suppressesNotification(userInfo: message, blocked: blocked))
        XCTAssertTrue(BlockPolicy.suppressesNotification(userInfo: call, blocked: blocked))
    }

    func testANotificationOfAnotherContactOrWithNoPeerIsNotSuppressed() {
        let blocked: Set<String> = ["u-1"]
        XCTAssertFalse(BlockPolicy.suppressesNotification(userInfo: ["peerUserId": "u-2"], blocked: blocked))
        XCTAssertFalse(BlockPolicy.suppressesNotification(userInfo: [:], blocked: blocked))
        XCTAssertFalse(BlockPolicy.suppressesNotification(userInfo: ["peerUserId": ""], blocked: blocked))
    }

    func testGroupMessageNotificationsAreNotSuppressedEvenWhenTheSenderIsBlocked() {
        let blocked: Set<String> = ["u-1"]
        let groupMessage: [AnyHashable: Any] = ["groupId": "ab12", "peerUserId": "u-1"]
        let wireStyle: [AnyHashable: Any] = ["group_id": "ab12", "peer_id": "u-1"]
        XCTAssertNil(BlockPolicy.oneToOnePeer(ofNotification: groupMessage))
        XCTAssertNil(BlockPolicy.oneToOnePeer(ofNotification: wireStyle))
        XCTAssertFalse(BlockPolicy.suppressesNotification(userInfo: groupMessage, blocked: blocked))
        XCTAssertFalse(BlockPolicy.suppressesNotification(userInfo: wireStyle, blocked: blocked))
    }

    func testAGroupCallAlertOfABlockedCreatorIsSuppressedWhateverElseItCarries() {
        let blocked: Set<String> = ["u-1"]
        // The local notification: the creator is also `peer_id`, the group id is present.
        let local: [AnyHashable: Any] = [
            "type": "incoming_group_call", "call_id": "x", "creator_id": "u-1", "peer_id": "u-1", "group_id": "ab12",
        ]
        // The pushed alert: `creator_id`, and a `caller_id` that names somebody else.
        let pushed: [AnyHashable: Any] = [
            "type": "incoming_group_call", "creator_id": "U-1", "caller_id": "u-2", "group_id": "ab12",
        ]
        // An empty creator falls back to the next key that names somebody.
        let fallback: [AnyHashable: Any] = ["type": "incoming_group_call", "creator_id": "", "peer_id": "u-1"]
        XCTAssertEqual(BlockPolicy.oneToOnePeer(ofNotification: local), "u-1")
        XCTAssertEqual(BlockPolicy.oneToOnePeer(ofNotification: pushed), "U-1")
        XCTAssertEqual(BlockPolicy.oneToOnePeer(ofNotification: fallback), "u-1")
        for info in [local, pushed, fallback] {
            XCTAssertTrue(BlockPolicy.suppressesNotification(userInfo: info, blocked: blocked), "\(info)")
        }
    }

    func testAGroupCallAlertOfAnotherCreatorIsNotSuppressedEvenWhenABlockedContactIsInTheCall() {
        let blocked: Set<String> = ["u-1"]
        let alert: [AnyHashable: Any] = [
            "type": "incoming_group_call", "creator_id": "u-2", "peer_id": "u-2", "group_id": "ab12",
        ]
        XCTAssertFalse(BlockPolicy.suppressesNotification(userInfo: alert, blocked: blocked))
        XCTAssertFalse(BlockPolicy.suppressesNotification(
            userInfo: ["type": "incoming_group_call", "group_id": "ab12"], blocked: blocked),
            "an alert that names nobody is not suppressed")
    }

    func testTheCallAlertTheServerPushesNamesItsCallerAsCallerId() {
        // The foreground presentation of a pushed call alert (`willPresent`) reads the caller from `caller_id`.
        let blocked: Set<String> = ["u-1"]
        let alert: [AnyHashable: Any] = ["call_id": "x", "caller_id": "U-1", "has_video": "0"]
        XCTAssertEqual(BlockPolicy.oneToOnePeer(ofNotification: alert), "U-1")
        XCTAssertTrue(BlockPolicy.suppressesNotification(userInfo: alert, blocked: blocked))
        XCTAssertFalse(BlockPolicy.suppressesNotification(
            userInfo: ["call_id": "x", "caller_id": "u-2"], blocked: blocked))
    }

    func testAnEmptyIdDoesNotHideALaterKeyOfTheSameNotification() {
        // One helper serves the foreground alert, the local banner and the Answer tap: an empty `peer_id` must not
        // stop it before `caller_id`.
        let blocked: Set<String> = ["u-1"]
        let empty: [AnyHashable: Any] = ["call_id": "x", "peer_id": "", "caller_id": "u-1"]
        let blank: [AnyHashable: Any] = ["call_id": "x", "peer_id": "   ", "caller_id": "u-1"]
        XCTAssertEqual(BlockPolicy.oneToOnePeer(ofNotification: empty), "u-1")
        XCTAssertEqual(BlockPolicy.oneToOnePeer(ofNotification: blank), "u-1")
        XCTAssertTrue(BlockPolicy.suppressesNotification(userInfo: empty, blocked: blocked))
        XCTAssertTrue(BlockPolicy.suppressesNotification(userInfo: blank, blocked: blocked))
    }

    // MARK: - Block and unblock: the server first, the local list after it accepted

    func testBlockAsksTheServerAndThenStoresLocally() async {
        let api = FakeContactsApi()
        let (coordinator, list) = make(api: api)
        let outcome = await coordinator.setBlocked(true, userId: "u-1")
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(api.blockCalls, ["u-1"])
        XCTAssertEqual(list.ids, ["u-1"])
    }

    func testABlockTheServerRefusesLeavesNoLocalBlockedState() async {
        let api = FakeContactsApi()
        api.refuseBlock = true
        api.refuseList = true
        let (coordinator, list) = make(api: api)
        let outcome = await coordinator.setBlocked(true, userId: "u-1")
        XCTAssertEqual(outcome, .failed(.requestFailed))
        XCTAssertTrue(list.ids.isEmpty, "the app must never claim a block the server does not have")
    }

    func testAnUnblockTheServerRefusesKeepsTheContactBlocked() async {
        let api = FakeContactsApi()
        api.serverBlocked = [BlockedContact(userId: "u-1")]
        api.refuseUnblock = true
        api.refuseList = true
        let list = MemoryList()
        list.ids = ["u-1"]
        let (coordinator, _) = make(api: api, list: list)
        let outcome = await coordinator.setBlocked(false, userId: "u-1")
        XCTAssertEqual(outcome, .failed(.requestFailed))
        XCTAssertEqual(list.ids, ["u-1"])
    }

    func testAnUnblockOfAContactTheServerDoesNotHoldAsBlockedCountsAsDone() async {
        // The request is refused (nothing to unblock), but the server's own list shows the wanted state.
        let api = FakeContactsApi()
        api.refuseUnblock = true
        let list = MemoryList()
        list.ids = ["u-1"]   // a stale local copy
        let (coordinator, _) = make(api: api, list: list)
        let outcome = await coordinator.setBlocked(false, userId: "u-1")
        XCTAssertEqual(outcome, .applied)
        XCTAssertTrue(list.ids.isEmpty)
    }

    func testABlockTheServerAlreadyHasCountsAsDone() async {
        let api = FakeContactsApi()
        api.refuseBlock = true
        api.serverBlocked = [BlockedContact(userId: "u-1")]
        let (coordinator, list) = make(api: api)
        let outcome = await coordinator.setBlocked(true, userId: "u-1")
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(list.ids, ["u-1"])
    }

    func testUnblockRemovesTheLocalEntryEvenWhenTheCaseDiffers() async {
        let api = FakeContactsApi()
        api.serverBlocked = [BlockedContact(userId: "U-1")]
        let list = MemoryList()
        list.ids = ["U-1"]
        let (coordinator, _) = make(api: api, list: list)
        let outcome = await coordinator.setBlocked(false, userId: "u-1")
        XCTAssertEqual(outcome, .applied)
        XCTAssertTrue(list.ids.isEmpty)
    }

    func testWithoutASignedInBackendNothingChanges() async {
        let (coordinator, list) = make(api: nil)
        let outcome = await coordinator.setBlocked(true, userId: "u-1")
        XCTAssertEqual(outcome, .failed(.noConnection))
        XCTAssertTrue(list.ids.isEmpty)
    }

    func testAnEmptyUserIdIsRefusedBeforeAnyRequest() async {
        let api = FakeContactsApi()
        let (coordinator, list) = make(api: api)
        let outcome = await coordinator.setBlocked(true, userId: "  ")
        XCTAssertEqual(outcome, .failed(.invalidUser))
        XCTAssertTrue(api.blockCalls.isEmpty)
        XCTAssertTrue(list.ids.isEmpty)
    }

    func testRequestsRunOneAtATimeInTheOrderTheyWereAsked() async {
        let api = FakeContactsApi()
        let gate = Gate()
        api.blockGate = gate
        let (coordinator, list) = make(api: api)
        let first = Task { @MainActor in await coordinator.setBlocked(true, userId: "u-1") }
        let inFlight = await waitUntil { api.blockCalls.count == 1 }
        XCTAssertTrue(inFlight, "the block must reach the server")
        let second = Task { @MainActor in await coordinator.setBlocked(false, userId: "u-1") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(api.unblockCalls.isEmpty, "the unblock must wait for the block that was asked first")
        gate.release()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .applied)
        XCTAssertEqual(secondOutcome, .applied)
        XCTAssertEqual(api.blockCalls, ["u-1"])
        XCTAssertEqual(api.unblockCalls, ["u-1"])
        XCTAssertTrue(api.serverBlocked.isEmpty)
        XCTAssertTrue(list.ids.isEmpty, "the later unblock wins, on the server and locally")
    }

    /// Polls `condition` (on the main actor) until it holds or `timeout` seconds pass.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    // MARK: - Reload from the server

    func testRefreshReplacesTheLocalListByTheServers() async {
        let api = FakeContactsApi()
        api.serverBlocked = [BlockedContact(userId: "b"), BlockedContact(userId: "c")]
        let list = MemoryList()
        list.ids = ["a", "b"]
        let (coordinator, _) = make(api: api, list: list)
        let refreshed = await coordinator.refreshFromServer()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(list.ids, ["b", "c"])
    }

    func testAFailedRefreshKeepsTheLocalList() async {
        let api = FakeContactsApi()
        api.refuseList = true
        let list = MemoryList()
        list.ids = ["a"]
        let (coordinator, _) = make(api: api, list: list)
        let refreshed = await coordinator.refreshFromServer()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(list.ids, ["a"])
        XCTAssertNil(coordinator.lastRefresh)
    }

    func testRefreshWithoutABackendDoesNothing() async {
        let list = MemoryList()
        list.ids = ["a"]
        let (coordinator, _) = make(api: nil, list: list)
        let refreshed = await coordinator.refreshFromServer()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(list.ids, ["a"])
    }

    func testRefreshIfDueAsksTheServerAtMostOncePerInterval() async {
        let api = FakeContactsApi()
        let clock = Clock()
        let (coordinator, _) = make(api: api, clock: clock)
        let first = await coordinator.refreshFromServerIfDue(minInterval: 60)
        XCTAssertTrue(first)
        clock.now = clock.now.addingTimeInterval(30)
        let tooSoon = await coordinator.refreshFromServerIfDue(minInterval: 60)
        XCTAssertFalse(tooSoon)
        XCTAssertEqual(api.listCalls, 1)
        clock.now = clock.now.addingTimeInterval(31)
        let due = await coordinator.refreshFromServerIfDue(minInterval: 60)
        XCTAssertTrue(due)
        XCTAssertEqual(api.listCalls, 2)
    }

    func testAFailedRefreshDoesNotStartTheInterval() async {
        let api = FakeContactsApi()
        api.refuseList = true
        let (coordinator, _) = make(api: api)
        let failed = await coordinator.refreshFromServerIfDue(minInterval: 60)
        XCTAssertFalse(failed)
        api.refuseList = false
        let retried = await coordinator.refreshFromServerIfDue(minInterval: 60)
        XCTAssertTrue(retried, "a failure must not hold the next attempt back")
    }

    func testForgettingTheSessionLetsTheNextAccountRefreshAtOnce() async {
        let api = FakeContactsApi()
        let (coordinator, _) = make(api: api)
        let first = await coordinator.refreshFromServerIfDue(minInterval: 3600)
        XCTAssertTrue(first)
        coordinator.forgetSession()
        let second = await coordinator.refreshFromServerIfDue(minInterval: 3600)
        XCTAssertTrue(second)
        XCTAssertEqual(api.listCalls, 2)
    }

    // MARK: - An account that left: what it still has in flight is discarded

    func testARefreshAnsweredAfterTheAccountLeftPutsNothingBackAndStartsNoInterval() async {
        let api = FakeContactsApi()
        api.serverBlocked = [BlockedContact(userId: "old-account-contact")]
        let gate = Gate()
        api.listGate = gate
        let (coordinator, list) = make(api: api)
        let pending = Task { @MainActor in await coordinator.refreshFromServer() }
        let inFlight = await waitUntil { api.listCalls == 1 }
        XCTAssertTrue(inFlight, "the refresh must reach the server")
        // Sign-out: the list is wiped and the old account's request is still out.
        list.ids = []
        coordinator.forgetSession()
        gate.release()
        let refreshed = await pending.value
        XCTAssertFalse(refreshed, "the answer belongs to the account that left")
        XCTAssertTrue(list.ids.isEmpty, "the old account's list must not come back")
        XCTAssertNil(coordinator.lastRefresh, "and must not hold the next account's refresh back")
        // The next account refreshes at once.
        api.listGate = nil
        api.serverBlocked = [BlockedContact(userId: "new-account-contact")]
        let next = await coordinator.refreshFromServerIfDue(minInterval: 3600)
        XCTAssertTrue(next)
        XCTAssertEqual(list.ids, ["new-account-contact"])
    }

    func testABlockAnsweredAfterTheAccountLeftChangesNothingLocally() async {
        let api = FakeContactsApi()
        let gate = Gate()
        api.blockGate = gate
        let (coordinator, list) = make(api: api)
        let pending = Task { @MainActor in await coordinator.setBlocked(true, userId: "u-1") }
        let inFlight = await waitUntil { api.blockCalls.count == 1 }
        XCTAssertTrue(inFlight, "the block must reach the server")
        coordinator.forgetSession()
        gate.release()
        let outcome = await pending.value
        XCTAssertEqual(outcome, .failed(.accountChanged))
        XCTAssertTrue(list.ids.isEmpty, "the next account must not inherit the block")
    }

    func testARequestQueuedBeforeSignOutNeverReachesTheServerForTheNextAccount() async {
        let api = FakeContactsApi()
        let gate = Gate()
        api.blockGate = gate
        let (coordinator, list) = make(api: api)
        let first = Task { @MainActor in await coordinator.setBlocked(true, userId: "u-1") }
        let inFlight = await waitUntil { api.blockCalls.count == 1 }
        XCTAssertTrue(inFlight)
        let queued = Task { @MainActor in await coordinator.setBlocked(false, userId: "u-1") }
        try? await Task.sleep(nanoseconds: 100_000_000)   // let it take its place in the queue
        XCTAssertTrue(api.unblockCalls.isEmpty, "it waits for the block asked first")
        coordinator.forgetSession()
        gate.release()
        let firstOutcome = await first.value
        let queuedOutcome = await queued.value
        XCTAssertEqual(firstOutcome, .failed(.accountChanged))
        XCTAssertEqual(queuedOutcome, .failed(.accountChanged))
        XCTAssertTrue(api.unblockCalls.isEmpty, "a request asked by the account that left is not sent for the next one")
        XCTAssertTrue(list.ids.isEmpty)
    }

    func testABlockAskedAfterTheNewAccountSignedInWorksNormally() async {
        let api = FakeContactsApi()
        let (coordinator, list) = make(api: api)
        coordinator.forgetSession()
        let outcome = await coordinator.setBlocked(true, userId: "u-1")
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(list.ids, ["u-1"])
    }

    // MARK: - Refresh with retry

    /// Records the waits of `refreshFromServerWithRetry` without really waiting.
    private final class Waits {
        var seconds: [TimeInterval] = []
    }

    func testARefreshThatFailsIsRetriedAfterTheDelayAndLoadsTheList() async {
        let api = FakeContactsApi()
        api.refuseList = true
        api.serverBlocked = [BlockedContact(userId: "b")]
        let (coordinator, list) = make(api: api)
        let waits = Waits()
        let ok = await coordinator.refreshFromServerWithRetry(retryDelays: [5, 15, 45]) { seconds in
            waits.seconds.append(seconds)
            api.refuseList = false   // the network is back by the time the retry runs
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(waits.seconds, [5])
        XCTAssertEqual(api.listCalls, 2)
        XCTAssertEqual(list.ids, ["b"])
        XCTAssertNotNil(coordinator.lastRefresh)
    }

    func testARefreshThatKeepsFailingGivesUpAfterTheLastDelayAndKeepsTheList() async {
        let api = FakeContactsApi()
        api.refuseList = true
        let list = MemoryList()
        list.ids = ["a"]
        let (coordinator, _) = make(api: api, list: list)
        let waits = Waits()
        let ok = await coordinator.refreshFromServerWithRetry(retryDelays: [1, 2]) { seconds in
            waits.seconds.append(seconds)
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(waits.seconds, [1, 2])
        XCTAssertEqual(api.listCalls, 3, "the first attempt and one per delay")
        XCTAssertEqual(list.ids, ["a"])
        XCTAssertNil(coordinator.lastRefresh)
    }

    func testARefreshWaitsForTheBackendToAppear() async {
        // At sign-in the backend may not exist yet: that counts as a failed attempt, not as "nothing to do".
        let api = FakeContactsApi()
        api.serverBlocked = [BlockedContact(userId: "b")]
        var current: FakeContactsApi?
        let list = MemoryList()
        let coordinator = ContactBlockCoordinator(api: { current }, storage: list, now: { Date(timeIntervalSince1970: 1_000_000) })
        let waits = Waits()
        let ok = await coordinator.refreshFromServerWithRetry(retryDelays: [5, 15]) { seconds in
            waits.seconds.append(seconds)
            current = api
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(waits.seconds, [5])
        XCTAssertEqual(list.ids, ["b"])
    }

    func testAFreshListIsNotFetchedAgainAndNothingWaits() async {
        let api = FakeContactsApi()
        let (coordinator, _) = make(api: api)
        let first = await coordinator.refreshFromServerWithRetry()
        XCTAssertTrue(first)
        let waits = Waits()
        let again = await coordinator.refreshFromServerWithRetry { seconds in waits.seconds.append(seconds) }
        XCTAssertTrue(again, "fresh counts as loaded")
        XCTAssertEqual(api.listCalls, 1)
        XCTAssertTrue(waits.seconds.isEmpty)
    }

    func testTheRetryStopsWhenTheAccountLeavesWhileItWaits() async {
        let api = FakeContactsApi()
        api.refuseList = true
        let (coordinator, _) = make(api: api)
        let waits = Waits()
        let ok = await coordinator.refreshFromServerWithRetry(retryDelays: [1, 2, 3]) { seconds in
            waits.seconds.append(seconds)
            coordinator.forgetSession()   // sign-out while the retry sleeps
            api.refuseList = false
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(waits.seconds, [1], "no further attempt for an account that left")
        XCTAssertEqual(api.listCalls, 1)
    }

    func testTheRetryStopsWhenItsTaskIsCancelled() async {
        let api = FakeContactsApi()
        api.refuseList = true
        let (coordinator, _) = make(api: api)
        let task = Task { @MainActor in
            await coordinator.refreshFromServerWithRetry(retryDelays: [1, 1, 1]) { _ in }
        }
        task.cancel()   // the task cannot have started: this function has not suspended since it was created
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(api.listCalls, 0)
    }
}
