import XCTest
@testable import QAudionEngine

/// What the group controller and the manager do for a promoted 1:1 call (docs/GROUP_CALLS_V2_SPEC.md
/// 28 to 31, GROUP_CALLS_V2 2.7): the order of what the creator sends, the audio-only join with the
/// microphone held until the roster has been checked, the roster rule, the one exit of the creator, and
/// the id comparison. The harness fires the lone-call timer by hand, nothing here sleeps.
final class GroupPromotionControllerTests: XCTestCase {

    private let me = ControllerHarness.selfUser
    private let peerB = ControllerHarness.peerB
    private let peerC = ControllerHarness.peerC

    private let promotedGroup = "9f86d081-884c-4d63-9b2f-0a1b2c3d4e5f"
    private let tokenData = "6b86b273-ff34-4ce1-9b49-85d6e7f8a9b0|GRPPROMO:AAAA"

    // MARK: what the creator sends

    func testTheTokenGoesOutOnTheSameSocketBeforeTheCreateAndTheCreateUsesTheMintedId() {
        let h = ControllerHarness()
        let id = h.controller.createCall(
            invitees: [peerB], promotedFromCallId: "6b86b273-ff34-4ce1-9b49-85d6e7f8a9b0", groupCallId: promotedGroup,
            preCreateOpaque: BCryptoGroupCallManager.PreCreateOpaque(recipientId: peerB, data: tokenData))
        XCTAssertEqual(id, promotedGroup, "the call id is the one the token names")
        XCTAssertEqual(Array(h.sentTypes.prefix(2)), ["opaque_message", "group_call_create"], "token first, then the create")
        let opaque = h.sent[0].data
        XCTAssertEqual(opaque["recipient_id"] as? String, peerB)
        XCTAssertEqual(opaque["data"] as? String, tokenData, "a literal string, not base64 of it")
        let create = h.sent[1].data
        XCTAssertEqual(create["call_id"] as? String, promotedGroup)
        XCTAssertEqual(create["promoted_from_call_id"] as? String, "6b86b273-ff34-4ce1-9b49-85d6e7f8a9b0")
        XCTAssertEqual(create["recipients"] as? [String], [peerB])
        h.controller.leave()
    }

    func testACallCreatedWithoutATokenSendsNoOpaqueMessage() {
        let h = ControllerHarness()
        let id = h.controller.createCall(invitees: [peerB])
        XCTAssertNotNil(id)
        XCTAssertFalse(h.sentTypes.contains("opaque_message"))
        XCTAssertEqual(h.sentTypes.first, "group_call_create")
        h.controller.leave()
    }

    func testTheManagerSendsAnOpaqueStringOnTheSameFunnelAsTheGroupFrames() {
        let h = ControllerHarness()
        h.manager.sendOpaqueString(recipientId: peerB, data: tokenData)
        XCTAssertEqual(h.sentTypes, ["opaque_message"])
        XCTAssertEqual(h.sent[0].data["data"] as? String, tokenData)
    }

    // MARK: the audio-only join with the microphone held

    private func autoJoinRule() -> GroupAutoJoinGuard {
        GroupAutoJoinGuard(creatorUserId: peerB, invitees: [me, peerC], selfUserId: me)
    }

    /// The last microphone call the link received (other calls, like the publisher filter refresh, may follow it).
    private func lastMic(_ link: FakeMediaLink) -> String? {
        return link.calls.last { $0.hasPrefix("mic=") }
    }

    private func linkOf(_ h: ControllerHarness, firstRosterListsMe: Bool) async -> FakeMediaLink? {
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: firstRosterListsMe ? [peerB, me] : [peerB], withMedia: false,
                                          ringing: firstRosterListsMe ? [peerC] : [me, peerC]))
        h.manager.onMediaReady?(h.ready())
        _ = await h.waitUntil { !h.backend.links.isEmpty && h.backend.links[0].calls.contains { $0.hasPrefix("start") } }
        return h.backend.links.first
    }

    func testTheJoinIsAudioOnlyWithTheCameraOff() async throws {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: false, autoJoinGuard: autoJoinRule())
        XCTAssertFalse(h.controller.callWantsVideo)
        let made = await linkOf(h, firstRosterListsMe: false)
        let link = try XCTUnwrap(made)
        XCTAssertTrue(link.calls.contains("start video=false"), "no video track is published: \(link.calls)")
        XCTAssertFalse(link.calls.contains { $0.hasPrefix("camera=true") })
        h.controller.leave()
    }

    func testTheMicrophoneStaysOffUntilTheFirstPassingRosterThatListsThisDevice() async throws {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: false, autoJoinGuard: autoJoinRule())
        XCTAssertTrue(h.controller.isMicrophoneHeld)
        XCTAssertFalse(h.controller.isMuted, "the state of the 1:1 leg is kept for the release, nothing is muted for the user")
        let made = await linkOf(h, firstRosterListsMe: false)
        let link = try XCTUnwrap(made)
        XCTAssertEqual(link.calls.first, "mic=false", "the publisher is built with the microphone off: \(link.calls)")
        XCTAssertFalse(link.calls.contains("mic=true"))
        XCTAssertTrue(h.controller.isMicrophoneHeld, "a roster that does not list this device does not release it")
        h.manager.onGroupUpdate?(h.update(epoch: 2, members: [peerB, me], withMedia: false, ringing: [peerC]))
        XCTAssertFalse(h.controller.isMicrophoneHeld)
        XCTAssertEqual(lastMic(link), "mic=true", "the 1:1 leg was not muted: the microphone follows it")
        h.controller.leave()
    }

    func testAMutedOneToOneCallStaysMutedAfterTheRelease() async throws {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: true, autoJoinGuard: autoJoinRule())
        let made = await linkOf(h, firstRosterListsMe: false)
        let link = try XCTUnwrap(made)
        h.manager.onGroupUpdate?(h.update(epoch: 2, members: [peerB, me], withMedia: false, ringing: [peerC]))
        XCTAssertFalse(h.controller.isMicrophoneHeld)
        XCTAssertTrue(h.controller.isMuted)
        XCTAssertFalse(link.calls.contains("mic=true"), "never opened: \(link.calls)")
        XCTAssertEqual(lastMic(link), "mic=false")
        h.controller.leave()
    }

    func testAnUnmuteTapDuringTheHoldIsRememberedNotApplied() async throws {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: true, autoJoinGuard: autoJoinRule())
        let made = await linkOf(h, firstRosterListsMe: false)
        let link = try XCTUnwrap(made)
        h.controller.setMuted(false)
        XCTAssertFalse(link.calls.contains("mic=true"), "the hold wins: \(link.calls)")
        h.manager.onGroupUpdate?(h.update(epoch: 2, members: [peerB, me], withMedia: false, ringing: [peerC]))
        XCTAssertEqual(lastMic(link), "mic=true", "released with the user's choice")
        h.controller.leave()
    }

    /// The values `onMicrophoneHeldChanged` reported, in order.
    private final class HeldReports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testTheHoldIsReportedWhenItBeginsAndWhenItEnds() async throws {
        let h = ControllerHarness()
        let reports = HeldReports()
        h.controller.onMicrophoneHeldChanged = { reports.add($0) }
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: false, autoJoinGuard: autoJoinRule())
        XCTAssertEqual(reports.all, [true], "the screen shows the microphone as held from the join")
        _ = await linkOf(h, firstRosterListsMe: false)
        XCTAssertEqual(reports.all, [true], "a roster that does not list this device changes nothing")
        h.manager.onGroupUpdate?(h.update(epoch: 2, members: [peerB, me], withMedia: false, ringing: [peerC]))
        XCTAssertEqual(reports.all, [true, false])
        h.controller.leave()
        XCTAssertEqual(reports.all, [true, false], "nothing is held at the end, so nothing more is reported")
    }

    func testALeftCallEndsTheHoldTheScreenShows() async throws {
        let h = ControllerHarness()
        let reports = HeldReports()
        h.controller.onMicrophoneHeldChanged = { reports.add($0) }
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: false, autoJoinGuard: autoJoinRule())
        h.controller.leave()
        XCTAssertEqual(reports.all, [true, false])
        XCTAssertFalse(h.controller.isMicrophoneHeld)
    }

    func testAnOrdinaryJoinReportsNoHold() async throws {
        let h = ControllerHarness()
        let reports = HeldReports()
        h.controller.onMicrophoneHeldChanged = { reports.add($0) }
        _ = await h.joinAndConnect()
        h.controller.leave()
        XCTAssertEqual(reports.all, [])
    }

    func testEveryGroupCallIdThisDeviceMintsIsInLowerCase() throws {
        let h = ControllerHarness()
        let minted = try XCTUnwrap(h.controller.createCall(invitees: [peerB]))
        XCTAssertEqual(minted, minted.lowercased())
        XCTAssertTrue(GroupCallIds.isCanonical(minted))
        XCTAssertEqual(h.sent.last { $0.type == "group_call_create" }?.data["call_id"] as? String, minted)
        h.controller.leave()
    }

    func testAnOrdinaryJoinHoldsNothing() async throws {
        let h = ControllerHarness()
        let made = await h.joinAndConnect()
        let link = try XCTUnwrap(made)
        XCTAssertFalse(h.controller.isMicrophoneHeld)
        XCTAssertEqual(link.calls.first, "mic=true")
        h.controller.leave()
    }

    // MARK: the roster rule

    func testARosterOutsideTheTokenIsRefusedBeforeAnythingSeesIt() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: false, autoJoinGuard: autoJoinRule())
        var refused: [Int] = []
        h.controller.onAutoJoinRosterRefused = { refused.append($0) }
        var applied = 0
        h.controller.onUpdateApplied = { _, _ in applied += 1 }
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [peerB, me, "user-stranger"], withMedia: false))
        XCTAssertEqual(refused, [1])
        XCTAssertEqual(applied, 0, "the update was not applied")
        XCTAssertEqual(h.controller.currentRoster, [], "nothing stored")
        XCTAssertTrue(h.control.isEmpty, "no media key left for that epoch")
        XCTAssertTrue(h.controller.isMicrophoneHeld, "the microphone was never enabled for it")
    }

    func testAnInviteeStillRingingOutsideTheTokenIsRefusedToo() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: false, autoJoinGuard: autoJoinRule())
        var refused: [Int] = []
        h.controller.onAutoJoinRosterRefused = { refused.append($0) }
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [peerB, me], withMedia: false, ringing: ["user-stranger"]))
        XCTAssertEqual(refused, [1])
    }

    func testARosterWithinTheTokenIsAppliedAndEveryLaterOneIsCheckedToo() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: false, autoJoinGuard: autoJoinRule())
        var refused: [Int] = []
        h.controller.onAutoJoinRosterRefused = { refused.append($0) }
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [peerB, me], withMedia: false, ringing: [peerC]))
        XCTAssertTrue(refused.isEmpty)
        XCTAssertEqual(h.controller.currentRoster, [peerB, me])
        h.manager.onGroupUpdate?(h.update(epoch: 2, members: [peerB, me, "user-stranger"], withMedia: false))
        XCTAssertEqual(refused, [1], "for the whole life of the call")
        XCTAssertEqual(h.controller.currentRoster, [peerB, me], "the refused update did not replace the roster")
        h.controller.leave()
    }

    func testTheGuardEndsWithTheCall() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId, video: false, startMuted: false, autoJoinGuard: autoJoinRule())
        h.controller.leave()
        XCTAssertFalse(h.controller.isMicrophoneHeld)
        h.controller.join(callId: ControllerHarness.callId)
        var refused: [Int] = []
        h.controller.onAutoJoinRosterRefused = { refused.append($0) }
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [peerB, me, "user-stranger"], withMedia: false))
        XCTAssertTrue(refused.isEmpty, "a later, ordinary call is not judged by the token of an earlier one")
        h.controller.leave()
    }

    // MARK: the hand-over decision reads the stored update

    func testTheUpdateAppliedCallbackSeesTheRosterAndTheRingingListAlreadyStored() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        var storedRoster: [[String]] = []
        var storedRinging: [[String]?] = []
        h.controller.onUpdateApplied = { [weak h] _, _ in
            storedRoster.append(h?.controller.currentRoster ?? [])
            storedRinging.append(h?.controller.currentRinging)
        }
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me, peerB], withMedia: false, ringing: [peerC]))
        XCTAssertEqual(storedRoster, [[me, peerB]])
        XCTAssertEqual(storedRinging.count, 1)
        XCTAssertEqual(storedRinging.first ?? nil, [peerC])
        h.controller.leave()
    }

    // MARK: one exit for the creator

    func testTheCreatorThatIsLastInTheCallEndsItAndEveryoneElseLeaves() {
        let alone = ControllerHarness()
        _ = alone.controller.createCall(invitees: [peerB])
        XCTAssertEqual(alone.controller.leaveOrEnd(), .endForAll)
        XCTAssertTrue(alone.sentTypes.contains("group_call_end"))
        XCTAssertFalse(alone.sentTypes.contains("group_call_leave"))
        XCTAssertEqual(alone.controller.state, .idle)

        let withOthers = ControllerHarness()
        let id = withOthers.controller.createCall(invitees: [peerB]) ?? ""
        withOthers.manager.onGroupUpdate?(withOthers.update(epoch: 2, members: [me, peerB], withMedia: false, callId: id, ringing: []))
        XCTAssertEqual(withOthers.controller.leaveOrEnd(), .leave)
        XCTAssertTrue(withOthers.sentTypes.contains("group_call_leave"))
        XCTAssertFalse(withOthers.sentTypes.contains("group_call_end"))

        let joiner = ControllerHarness()
        joiner.controller.join(callId: ControllerHarness.callId)
        XCTAssertEqual(joiner.controller.leaveOrEnd(), .leave)
        XCTAssertTrue(joiner.sentTypes.contains("group_call_leave"))
    }

    // MARK: ids without regard to case

    func testAnUpdateAndAnEndWithTheCallIdInAnotherCaseAreTheSameCall() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me, peerB], withMedia: false,
                                          callId: ControllerHarness.callId.uppercased()))
        XCTAssertEqual(h.controller.currentRoster, [me, peerB], "the upper-case spelling is the same call")
        var ended: [String] = []
        h.manager.onActiveCallEnded = { _, reason in ended.append(reason) }
        h.manager.handleGroupCallEnded(data: ["call_id": ControllerHarness.callId.uppercased(), "reason": "ended"])
        XCTAssertEqual(ended, ["ended"])
    }
}
