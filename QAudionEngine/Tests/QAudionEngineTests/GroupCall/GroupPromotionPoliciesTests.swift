import XCTest
@testable import QAudionEngine

/// The pure rules of the 1:1 promotion and of admission (docs/GROUP_CALLS_V2_SPEC.md 27-31).
/// Test names carry the clause they pin.
final class GroupPromotionPoliciesTests: XCTestCase {

    private let me = "user-self"
    private let peer = "user-b"
    private let other = "user-c"
    private let oneToOne = "9f8e7d6c-1111-2222-3333-444455556666"

    // MARK: 27 - a 1:1 call while a group call is live

    func testSpec27_noLiveGroupCallLetsTheOneToOneCallThrough() {
        XCTAssertEqual(GroupAdmissionPolicy.decide(groupState: .idle, isInCall: false), .proceed)
        XCTAssertEqual(GroupAdmissionPolicy.decide(groupState: .failed(reason: "media_error"), isInCall: false), .proceed,
                       "the failed state is the instant before idle: nothing is left to leave")
    }

    func testSpec27_aLiveGroupCallAsksToLeaveFirst() {
        XCTAssertEqual(GroupAdmissionPolicy.decide(groupState: .connecting(callId: "c"), isInCall: false), .confirmLeaveGroup)
        XCTAssertEqual(GroupAdmissionPolicy.decide(groupState: .active(callId: "c", participants: [me, peer]), isInCall: false),
                       .confirmLeaveGroup)
    }

    func testSpec27_anotherLiveOneToOneCallStillRefusesFirst() {
        XCTAssertEqual(GroupAdmissionPolicy.decide(groupState: .idle, isInCall: true), .refuseAlreadyInCall)
        XCTAssertEqual(GroupAdmissionPolicy.decide(groupState: .active(callId: "c", participants: [me, peer]), isInCall: true),
                       .refuseAlreadyInCall, "the promotion overlap (1:1 and group together) places no second 1:1 call")
    }

    func testSpec27_theCreatorEndsAGroupItIsAloneInEverybodyElseLeaves() {
        XCTAssertEqual(GroupExitPolicy.action(isCreator: true, participants: [me], selfId: me), .endForAll)
        XCTAssertEqual(GroupExitPolicy.action(isCreator: true, participants: [], selfId: me), .endForAll,
                       "a roster not known yet has nobody else in it")
        XCTAssertEqual(GroupExitPolicy.action(isCreator: true, participants: [me, peer], selfId: me), .leave,
                       "leaving keeps the call up for the people who are in it")
        XCTAssertEqual(GroupExitPolicy.action(isCreator: false, participants: [me], selfId: me), .leave)
        XCTAssertEqual(GroupExitPolicy.action(isCreator: false, participants: [me, peer], selfId: me), .leave)
        XCTAssertEqual(GroupExitPolicy.action(isCreator: true, participants: [me.uppercased()], selfId: me), .endForAll,
                       "the same account spelled in upper case is still this device")
    }

    // MARK: 28 - the self-promotion carve-out (the consent decision itself: GroupPromotionDecisionTests)

    private func selfPromotion(from: String? = nil, creator: String? = nil,
                               liveCall: String?? = nil, livePeer: String?? = nil) -> Bool {
        GroupPromotionPolicy.isSelfPromotion(
            promotedFromCallId: from ?? oneToOne,
            creatorId: creator ?? peer,
            liveOneToOneCallId: liveCall ?? oneToOne,
            liveOneToOnePeerId: livePeer ?? peer)
    }

    func testSpec28_anInviteThatContinuesTheLiveCallFromItsPeerIsASelfPromotion() {
        XCTAssertTrue(selfPromotion())
    }

    func testSpec28_theIdsAreComparedWithoutRegardToCase() {
        XCTAssertTrue(selfPromotion(from: oneToOne.uppercased()))
        XCTAssertTrue(selfPromotion(creator: peer.uppercased()))
        XCTAssertTrue(selfPromotion(liveCall: .some(oneToOne.uppercased()), livePeer: .some(peer.uppercased())))
    }

    func testSpec28_theInviteMustNameTheCallLiveHereRightNow() {
        XCTAssertFalse(selfPromotion(from: "another-call-id"))
        XCTAssertFalse(selfPromotion(from: ""))
        XCTAssertFalse(selfPromotion(liveCall: .some(nil)), "no 1:1 call is live")
        XCTAssertFalse(selfPromotion(liveCall: .some("")))
    }

    func testSpec28_theGroupCreatorMustBeThePeerOfThatLiveCall() {
        XCTAssertFalse(selfPromotion(creator: other))
        XCTAssertFalse(selfPromotion(creator: ""))
        XCTAssertFalse(selfPromotion(livePeer: .some(nil)))
        XCTAssertFalse(selfPromotion(livePeer: .some(other)))
    }

    // MARK: 30 - lone call

    func testSpec30_theBackstopIsFiftySeconds() {
        XCTAssertEqual(GroupAlonePolicy.backstopSeconds, 50)
        XCTAssertEqual(GroupAloneWatchdog().seconds, 50)
    }

    func testSpec30_aloneMeansOnlyThisDeviceNobodyRingingNoPromotionPending() {
        XCTAssertTrue(GroupAlonePolicy.isAlone(participants: [me], selfId: me, ringing: [], promotionPending: false))
        XCTAssertTrue(GroupAlonePolicy.isAlone(participants: [me], selfId: me, ringing: nil, promotionPending: false),
                      "a server that does not report the ringing list: nobody is known to ring")
        XCTAssertFalse(GroupAlonePolicy.isAlone(participants: [me], selfId: me, ringing: [peer], promotionPending: false))
        XCTAssertFalse(GroupAlonePolicy.isAlone(participants: [me, peer], selfId: me, ringing: [], promotionPending: false))
        XCTAssertFalse(GroupAlonePolicy.isAlone(participants: [me], selfId: me, ringing: [], promotionPending: true))
        XCTAssertFalse(GroupAlonePolicy.isAlone(participants: [], selfId: me, ringing: [], promotionPending: false),
                       "a roster not known yet is not a lone call")
        XCTAssertFalse(GroupAlonePolicy.isAlone(participants: [peer], selfId: me, ringing: [], promotionPending: false))
        XCTAssertTrue(GroupAlonePolicy.isAlone(participants: [me.uppercased()], selfId: me, ringing: [], promotionPending: false))
    }

    func testSpec30_theTimerArmsOnceAndFiresOnceWhileTheCallStaysAlone() {
        let clock = ManualAloneScheduler()
        let watchdog = GroupAloneWatchdog(scheduler: clock.scheduler)
        var fired = 0
        watchdog.onExpired = { fired += 1 }
        XCTAssertEqual(watchdog.update(alone: true), .armed)
        XCTAssertEqual(watchdog.update(alone: true), .unchanged, "another roster update keeps the original deadline")
        XCTAssertTrue(watchdog.isArmed)
        XCTAssertEqual(clock.scheduledSeconds, [50])
        clock.fire()
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(watchdog.isArmed)
        clock.fire()
        XCTAssertEqual(fired, 1, "it does not fire again by itself")
    }

    func testSpec30_aJoinOrAnotherParticipantOrARingingInviteeCancelsTheTimer() {
        let clock = ManualAloneScheduler()
        let watchdog = GroupAloneWatchdog(scheduler: clock.scheduler)
        var fired = 0
        watchdog.onExpired = { fired += 1 }
        XCTAssertEqual(watchdog.update(alone: true), .armed)
        XCTAssertEqual(watchdog.update(alone: false), .cancelled)
        XCTAssertEqual(watchdog.update(alone: false), .unchanged)
        XCTAssertEqual(clock.armed, 0)
        clock.fire()
        XCTAssertEqual(fired, 0)
        // Alone again: a fresh deadline.
        XCTAssertEqual(watchdog.update(alone: true), .armed)
        XCTAssertEqual(clock.scheduledSeconds, [50, 50])
    }

    func testSpec30_aTimerThatWasCancelledAndRearmedFiresOnlyForTheNewArming() {
        let clock = ManualAloneScheduler()
        let watchdog = GroupAloneWatchdog(scheduler: clock.scheduler)
        var fired = 0
        watchdog.onExpired = { fired += 1 }
        _ = watchdog.update(alone: true)
        watchdog.cancel()
        _ = watchdog.update(alone: true)
        XCTAssertEqual(clock.armed, 1)
        clock.fire()
        XCTAssertEqual(fired, 1)
    }

    // MARK: 29 - creator hand-over

    private func inputs(participants: [String] = [], ringing: [String]? = nil, oneToOneLive: Bool = true,
                        groupEnded: Bool = false, media: Bool = true, elapsed: Double = 5)
        -> GroupHandOverPolicy.Inputs {
        GroupHandOverPolicy.Inputs(peerId: peer, selfId: me, participants: participants.isEmpty ? [me] : participants,
                                   ringing: ringing, oneToOneLive: oneToOneLive, groupEnded: groupEnded,
                                   mediaConnected: media, elapsedSeconds: elapsed)
    }

    func testSpec29_theCapIsFiftySecondsAndTheMediaDeadlineThirty() {
        XCTAssertEqual(GroupHandOverPolicy.capSeconds, 50)
        XCTAssertEqual(GroupHandOverPolicy.mediaDeadlineSeconds, 30)
    }

    func testSpec29_theOneToOneCallIsKeptWhileThePeerIsStillRinging() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(ringing: [peer])), .wait)
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(ringing: [peer], elapsed: 49.9)), .wait)
    }

    func testSpec29_aThirdParticipantDoesNotHandOver() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, other], ringing: [peer])), .wait,
                       "only the 1:1 peer counts, not the first remote participant")
    }

    func testSpec29_thePeerInTheRosterHandsOver() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, peer], ringing: [])), .handOver(.peerJoined))
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, peer], ringing: nil)), .handOver(.peerJoined))
    }

    func testSpec29_thePeersInviteBeingOverHandsOverWhenSomebodyElseIsThereOrRinging() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, other], ringing: [])), .handOver(.peerInviteOver),
                       "declined or timed out: the peer is neither in the roster nor in the ringing list")
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me], ringing: [other])), .handOver(.peerInviteOver))
    }

    func testSpec29_thePeersInviteBeingOverWithTheCreatorAloneAndNobodyRingingAbortsAndKeepsTheOneToOneCall() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me], ringing: [])), .abortKeepOneToOne,
                       "nothing to hand the call over to: the 1:1 call stays, the group is left")
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me.uppercased()], ringing: [])), .abortKeepOneToOne)
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me], ringing: nil)), .wait,
                       "an unknown ringing list never says the invite is over")
    }

    func testSpec29_theAbortRuleNeverAppliesBeforeTheGroupMediaIsUp() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me], ringing: [], media: false, elapsed: 5)), .wait)
    }

    func testSpec29_theIdsOfTheRosterAreComparedWithoutRegardToCase() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, peer.uppercased()], ringing: [])), .handOver(.peerJoined))
        XCTAssertFalse(GroupHandOverPolicy.peerInviteOver(peerId: peer, participants: [me], ringing: [peer.uppercased()]))
    }

    func testSpec29_anUnknownRingingListNeverSaysTheInviteIsOver() {
        XCTAssertFalse(GroupHandOverPolicy.peerInviteOver(peerId: peer, participants: [me], ringing: nil))
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(ringing: nil)), .wait)
    }

    func testSpec29_theCapHandsOverEvenIfNothingElseHappened() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(ringing: [peer], elapsed: 50)), .handOver(.capReached))
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(ringing: nil, elapsed: 61)), .handOver(.capReached))
    }

    func testSpec29_theOneToOneCallEndingCompletesThePromotion() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(ringing: [peer], oneToOneLive: false)), .handOver(.oneToOneEnded))
    }

    func testSpec29_aGroupThatEndsMeanwhileAbortsAndKeepsTheOneToOneCall() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, peer], groupEnded: true)), .abort)
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(oneToOneLive: false, groupEnded: true)), .abort)
    }

    func testSpec29_theOneToOneCallIsNeverHungUpBeforeTheGroupMediaIsUp() {
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, peer], media: false, elapsed: 10)), .wait)
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, peer], media: false, elapsed: 49)),
                       .abandonMediaNotUp, "30 s without media: leave the group, keep the 1:1 call")
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, peer], media: false, elapsed: 30)), .abandonMediaNotUp)
        XCTAssertEqual(GroupHandOverPolicy.decide(inputs(participants: [me, peer], media: false, elapsed: 29.9)), .wait)
    }

    func testSpec29_theOneToOneCallEndingWithAnEmptyGroupLeavesTheGroup() {
        XCTAssertTrue(GroupHandOverPolicy.shouldLeaveGroupWhenOneToOneEnds(
            promotionPending: true, participants: [me], selfId: me, ringing: []))
        XCTAssertFalse(GroupHandOverPolicy.shouldLeaveGroupWhenOneToOneEnds(
            promotionPending: true, participants: [me], selfId: me, ringing: [other]), "somebody else still rings")
        XCTAssertFalse(GroupHandOverPolicy.shouldLeaveGroupWhenOneToOneEnds(
            promotionPending: true, participants: [me, peer], selfId: me, ringing: []))
        XCTAssertFalse(GroupHandOverPolicy.shouldLeaveGroupWhenOneToOneEnds(
            promotionPending: false, participants: [me], selfId: me, ringing: []), "no pending promotion: the existing rule")
        XCTAssertFalse(GroupHandOverPolicy.shouldLeaveGroupWhenOneToOneEnds(
            promotionPending: true, participants: [me], selfId: me, ringing: nil),
                       "an unknown ringing list: the lone timer decides")
        XCTAssertFalse(GroupHandOverPolicy.shouldLeaveGroupWhenOneToOneEnds(
            promotionPending: true, participants: [], selfId: me, ringing: []))
        XCTAssertTrue(GroupHandOverPolicy.shouldLeaveGroupWhenOneToOneEnds(
            promotionPending: true, participants: [me.uppercased()], selfId: me, ringing: []))
    }
}
