import XCTest
@testable import QAudionEngine

/// The WebSocket side of a group call (spec section 2): what the manager sends and
/// how it routes `group_call_update`, `group_call_ended` and `group_call_media_*`.
final class GroupCallManagerTests: XCTestCase {

    private let callId = ControllerHarness.callId

    private func makeManager() -> (BCryptoGroupCallManager, () -> [(type: String, data: [String: Any])]) {
        let ws = BCryptoWebSocketClient(config: BackendConfig(serverUrl: "https://example.invalid"))
        let manager = BCryptoGroupCallManager(ws: ws, selfUserId: "user-self", nameResolver: { $0 })
        let box = LockedBox<[(type: String, data: [String: Any])]>([])
        manager.sendOverride = { type, data in box.mutate { $0.append((type, data)) } }
        return (manager, { box.value })
    }

    // MARK: outbound

    func testCreateSendsNoCapabilityFieldsAndTheGroupContext() {
        let (manager, sent) = makeManager()
        let id = manager.createGroupCall(recipients: ["user-b"], callType: "video", groupId: "g", groupName: "n",
                                         promotedFromCallId: "p")
        XCTAssertNotNil(id)
        let message = sent().first
        XCTAssertEqual(message?.type, "group_call_create")
        let data = message?.data ?? [:]
        XCTAssertEqual(data["call_id"] as? String, id)
        XCTAssertEqual(data["recipients"] as? [String], ["user-b"])
        XCTAssertEqual(data["call_type"] as? String, "video")
        XCTAssertEqual(data["promoted_from_call_id"] as? String, "p")
        XCTAssertNil(data["supports_group_sender_keys"], "v2 has no capability negotiation")
        XCTAssertNil(data["supports_raw_key_aes256"])
        XCTAssertEqual(manager.state, .creating)
    }

    func testMediaRefreshMessage() {
        let (manager, sent) = makeManager()
        manager.requestMediaRefresh(callId: callId)
        XCTAssertEqual(sent().map { $0.type }, ["group_call_media_refresh"])
        XCTAssertEqual(sent()[0].data["call_id"] as? String, callId)
        XCTAssertEqual(sent()[0].data.count, 1, "nothing but the call id")
    }

    func testMediaJoinRejoinAndDeclineMessages() {
        let (manager, sent) = makeManager()
        manager.requestMediaJoin(callId: callId)
        manager.requestMediaRejoin(callId: callId, reason: String(repeating: "x", count: 40))
        manager.declineGroupCall(callId: callId)
        XCTAssertEqual(sent().map { $0.type }, ["group_call_media_join", "group_call_media_rejoin", "group_call_decline"])
        XCTAssertEqual(sent()[0].data["call_id"] as? String, callId)
        XCTAssertEqual((sent()[1].data["reason"] as? String)?.count, 24, "the rejoin reason is a short code, never free text")
        XCTAssertEqual(sent()[2].data["call_id"] as? String, callId)
    }

    // MARK: group_call_update

    func testUpdateBuildsTheRosterEpochAndNotifies() {
        let (manager, _) = makeManager()
        manager.joinGroupCall(callId: callId)
        let updates = LockedBox<[GroupCallWire.Update]>([])
        manager.onGroupUpdate = { update in updates.mutate { $0.append(update) } }
        let roster = LockedBox<[String]>([])
        manager.onParticipantsChanged = { list in roster.mutate { $0 = list.map { $0.id } } }
        manager.handleGroupCallUpdate(data: [
            "call_id": callId, "participants": ["user-self", "user-b"], "sender_key_epoch": 7,
            "media": ["node_id": "node-a", "pseudonyms": ["user-self": GroupCallFixtures.pseudoA, "user-b": GroupCallFixtures.pseudoB]],
        ])
        XCTAssertEqual(manager.state, .active)
        XCTAssertEqual(manager.senderKeyEpoch, 7)
        XCTAssertEqual(roster.value, ["user-self", "user-b"])
        XCTAssertEqual(updates.value.first?.pseudonyms["user-b"], GroupCallFixtures.pseudoB)
        XCTAssertEqual(updates.value.first?.nodeId, "node-a")
    }

    func testUpdateOfAnotherCallIsDropped() {
        let (manager, _) = makeManager()
        manager.joinGroupCall(callId: callId)
        let updates = LockedBox(0)
        manager.onGroupUpdate = { _ in updates.mutate { $0 += 1 } }
        manager.handleGroupCallUpdate(data: ["call_id": "other", "participants": ["user-b"], "sender_key_epoch": 1])
        XCTAssertEqual(updates.value, 0)
        XCTAssertEqual(manager.state, .creating)
    }

    /// The server sends `group_call_update` to EVERY device of a participant: a device that is not
    /// in the call (another device of the same account joined it) must not turn `.active` with a
    /// phantom roster, which refuses every later `createGroupCall`.
    func testAnUpdateWhileNoCallIsActiveIsDroppedAndDoesNotBlockTheNextCreate() {
        let (manager, _) = makeManager()
        let updates = LockedBox(0)
        manager.onGroupUpdate = { _ in updates.mutate { $0 += 1 } }
        let states = LockedBox<[BCryptoGroupCallManager.State]>([])
        manager.onStateChanged = { state in states.mutate { $0.append(state) } }
        manager.handleGroupCallUpdate(data: ["call_id": callId, "participants": ["user-self", "user-b"], "sender_key_epoch": 3])
        XCTAssertEqual(updates.value, 0)
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(manager.participants.isEmpty)
        XCTAssertEqual(states.value, [])
        XCTAssertNotNil(manager.createGroupCall(recipients: ["user-b"]), "the manager is still free for a new call")
    }

    // MARK: group_call_ended

    func testEndedForTheActiveCallEndsItAndReportsTheReason() {
        let (manager, _) = makeManager()
        manager.joinGroupCall(callId: callId)
        let ended = LockedBox<[String]>([])
        manager.onActiveCallEnded = { id, reason in ended.mutate { $0 = [id, reason] } }
        manager.onRingEnded = { _, _ in XCTFail("an active call is not a ring") }
        manager.handleGroupCallEnded(data: ["call_id": callId, "reason": "ended"])
        XCTAssertEqual(ended.value, [callId, "ended"])
        XCTAssertEqual(manager.state, .ended)
        XCTAssertNil(manager.callId)
    }

    /// `ring_timeout` / `declined` are about a RING: the invitee presses Accept a moment before the
    /// server's timer fires, joins, and the notice for the ring arrives with the live call id. It must
    /// not tear the call down (the server then still processes the join, which would leave a ghost
    /// participant).
    func testRingOnlyEndReasonsDoNotEndTheCallWeAreIn() {
        let (manager, _) = makeManager()
        manager.joinGroupCall(callId: callId)
        manager.onActiveCallEnded = { _, _ in XCTFail("a ring notice is not the end of the call") }
        for reason in ["ring_timeout", "declined"] {
            manager.handleGroupCallEnded(data: ["call_id": callId, "reason": reason])
        }
        manager.handleGroupCallEnded(data: ["reason": "ring_timeout"])
        XCTAssertEqual(manager.state, .creating)
        XCTAssertEqual(manager.callId, callId)
    }

    func testEndedAndAnUnknownReasonStillEndTheActiveCall() {
        for reason in ["ended", "some_future_reason"] {
            let (manager, _) = makeManager()
            manager.joinGroupCall(callId: callId)
            let ended = LockedBox<[String]>([])
            manager.onActiveCallEnded = { id, why in ended.mutate { $0 = [id, why] } }
            manager.handleGroupCallEnded(data: ["call_id": callId, "reason": reason])
            XCTAssertEqual(ended.value, [callId, reason])
            XCTAssertEqual(manager.state, .ended)
        }
    }

    /// Another live device of the account holds the seat (server D24): for the call this device is
    /// joining or in, `answered_elsewhere` is its end HERE, locally, without a `group_call_leave`
    /// (a leave is per account and would remove the seat from under the device that holds it). The
    /// same goes for its `group_call_media_unavailable` form.
    func testAnsweredElsewhereEndsTheCallWeAreInLocallyAndSendsNoLeave() {
        for viaMedia in [false, true] {
            let (manager, sent) = makeManager()
            manager.joinGroupCall(callId: callId)
            let ended = LockedBox<[String]>([])
            manager.onActiveCallEnded = { id, why in ended.mutate { $0 = [id, why] } }
            manager.onMediaUnavailable = { _, _ in XCTFail("not a media failure: it is the end of the call here") }
            if viaMedia {
                manager.handleMediaUnavailable(data: ["call_id": callId, "reason": "answered_elsewhere"])
            } else {
                manager.handleGroupCallEnded(data: ["call_id": callId, "reason": "answered_elsewhere"])
            }
            XCTAssertEqual(ended.value, [callId, "answered_elsewhere"])
            XCTAssertEqual(manager.state, .ended)
            XCTAssertNil(manager.callId)
            XCTAssertFalse(sent().contains { $0.type == "group_call_leave" }, "the holder keeps the seat")
        }
    }

    func testAnsweredElsewhereDismissesTheRingOfACallWeAreNotIn() {
        let (manager, _) = makeManager()
        let ring = LockedBox<[String]>([])
        manager.onRingEnded = { id, reason in ring.mutate { $0 = [id, reason] } }
        manager.handleGroupCallEnded(data: ["call_id": "ringing-call", "reason": "answered_elsewhere"])
        XCTAssertEqual(ring.value, ["ringing-call", "answered_elsewhere"])
    }

    /// The delayed `.ended -> .idle` reset must not overwrite a call started inside its second.
    func testTheDelayedIdleResetNeverOverwritesACallJoinedInsideIt() async throws {
        let (manager, _) = makeManager()
        manager.endedResetDelaySeconds = 0.15
        let states = LockedBox<[BCryptoGroupCallManager.State]>([])
        manager.onStateChanged = { state in states.mutate { $0.append(state) } }
        manager.joinGroupCall(callId: callId)
        manager.leaveGroupCall()
        XCTAssertEqual(manager.state, .ended)
        manager.joinGroupCall(callId: "22222222-3333-4444-5555-666666666666")
        XCTAssertEqual(manager.state, .creating)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(manager.state, .creating, "a stale idle reset would have overwritten the new call")
        XCTAssertEqual(manager.callId, "22222222-3333-4444-5555-666666666666")
        XCTAssertFalse(states.value.contains(.idle))
    }

    func testTheIdleResetStillHappensWhenNothingElseDid() async throws {
        let (manager, _) = makeManager()
        manager.endedResetDelaySeconds = 0.1
        manager.joinGroupCall(callId: callId)
        manager.leaveGroupCall()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(manager.state, .idle)
    }

    func testAServerErrorIsPassedOnWithItsCodeAndAnEmptyCallIdIsNone() {
        let (manager, _) = makeManager()
        let seen = LockedBox<[String]>([])
        manager.onServerError = { code, id in seen.mutate { $0.append("\(code)|\(id ?? "-")") } }
        manager.handleServerError(code: "entitlement_required", callId: callId)
        manager.handleServerError(code: "?", callId: "")
        manager.handleServerError(code: "?", callId: nil)
        XCTAssertEqual(seen.value, ["entitlement_required|\(callId)", "?|-", "?|-"])
    }

    func testEndedForACallWeNeverJoinedIsARingGoingAway() {
        let (manager, _) = makeManager()
        let ring = LockedBox<[String]>([])
        manager.onRingEnded = { id, reason in ring.mutate { $0 = [id, reason] } }
        manager.onActiveCallEnded = { _, _ in XCTFail("not the active call") }
        manager.handleGroupCallEnded(data: ["call_id": "ringing-call", "reason": "ring_timeout"])
        XCTAssertEqual(ring.value, ["ringing-call", "ring_timeout"])
    }

    // MARK: group_call_media_*

    func testMediaReadyOnlyForTheActiveCallAndOnlyWhenWellFormed() {
        let (manager, _) = makeManager()
        manager.joinGroupCall(callId: callId)
        let seen = LockedBox(0)
        manager.onMediaReady = { _ in seen.mutate { $0 += 1 } }
        var good = GroupCallFixtures.readyDictionary()
        good["call_id"] = callId
        manager.handleMediaReady(data: good)
        XCTAssertEqual(seen.value, 1)
        // Another call, a plain ws:// url and a pseudonym that is not 128-bit hex are all refused.
        var other = good; other["call_id"] = "other"
        var insecure = good; insecure["ws_url"] = "ws://media.example.invalid/janus"
        var weak = good; weak["pseudonym"] = "short"
        manager.handleMediaReady(data: other)
        manager.handleMediaReady(data: insecure)
        manager.handleMediaReady(data: weak)
        XCTAssertEqual(seen.value, 1)
    }

    func testMediaTokenIsRoutedOnlyForTheActiveCallAndOnlyWhenWellFormed() {
        let (manager, _) = makeManager()
        manager.joinGroupCall(callId: callId)
        let tokens = LockedBox<[String]>([])
        manager.onMediaToken = { token in tokens.mutate { $0.append(token.sessionToken) } }
        manager.handleMediaToken(data: ["call_id": callId, "session_token": "fresh-1", "ttl_s": 600])
        manager.handleMediaToken(data: ["call_id": "other", "session_token": "fresh-2", "ttl_s": 600])
        manager.handleMediaToken(data: ["call_id": callId, "ttl_s": 600])
        XCTAssertEqual(tokens.value, ["fresh-1"])
    }

    func testMediaUnavailableAndMovedAreRoutedByCallId() {
        let (manager, _) = makeManager()
        manager.joinGroupCall(callId: callId)
        let events = LockedBox<[String]>([])
        manager.onMediaUnavailable = { id, reason in events.mutate { $0.append("unavailable:\(id.prefix(4)):\(reason)") } }
        manager.onMediaMoved = { id, node in events.mutate { $0.append("moved:\(id.prefix(4)):\(node)") } }
        manager.handleMediaUnavailable(data: ["call_id": callId, "reason": "full"])
        manager.handleMediaUnavailable(data: ["call_id": "other", "reason": "full"])
        manager.handleMediaMoved(data: ["call_id": callId, "node_id": "node-b"])
        manager.handleMediaMoved(data: ["call_id": "other", "node_id": "node-b"])
        XCTAssertEqual(events.value, ["unavailable:1111:full", "moved:1111:node-b"])
    }

    // MARK: local mute

    func testSetLocalMutedIsIdempotentAndFollowsTheGivenState() {
        let (manager, _) = makeManager()
        _ = manager.createGroupCall(recipients: ["user-b"])
        let notifications = LockedBox(0)
        manager.onParticipantsChanged = { _ in notifications.mutate { $0 += 1 } }
        XCTAssertTrue(manager.setLocalMuted(true))
        XCTAssertTrue(manager.setLocalMuted(true), "a second call changes nothing")
        XCTAssertEqual(notifications.value, 1)
        XCTAssertTrue(manager.participants.first { $0.id == "user-self" }?.isMuted ?? false)
        XCTAssertFalse(manager.setLocalMuted(false))
        XCTAssertEqual(notifications.value, 2)
    }

    // MARK: speaking

    func testSetSpeakingMarksParticipantsAndNotifiesOnlyOnChange() {
        let (manager, _) = makeManager()
        manager.joinGroupCall(callId: callId)
        manager.handleGroupCallUpdate(data: ["call_id": callId, "participants": ["user-self", "user-b"], "sender_key_epoch": 1])
        let notifications = LockedBox(0)
        manager.onParticipantsChanged = { _ in notifications.mutate { $0 += 1 } }
        manager.setSpeaking(["user-b"])
        manager.setSpeaking(["user-b"])
        XCTAssertEqual(notifications.value, 1)
        XCTAssertTrue(manager.participants.first { $0.id == "user-b" }?.isSpeaking ?? false)
    }
}
