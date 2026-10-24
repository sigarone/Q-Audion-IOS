import XCTest
@testable import QAudionEngine

/// The lone-call backstop (spec 30) and the ringing list (spec 31) as the controller applies
/// them: the timer is fired by hand through `ManualAloneScheduler`, nothing here sleeps.
final class GroupCallLoneAndRingingTests: XCTestCase {

    private let me = ControllerHarness.selfUser
    private let peerB = ControllerHarness.peerB
    private let peerC = ControllerHarness.peerC

    // MARK: 30 - lone call

    func testSpec30_aCreatorWithNobodyKnownToRingEndsTheCallAfterTheBackstop() {
        let h = ControllerHarness()
        XCTAssertNotNil(h.controller.createCall(invitees: [peerB]))
        XCTAssertEqual(h.alone.scheduledSeconds, [50], "the creator is alone from the moment it creates")
        XCTAssertEqual(h.controller.currentRoster, [me])
        h.alone.fire()
        XCTAssertTrue(h.sentTypes.contains("group_call_end"), "the creator ends a call it is alone in")
        XCTAssertFalse(h.sentTypes.contains("group_call_leave"))
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertTrue(h.diagLines.contains("grp alone phase=1 ms=50000"))
        XCTAssertTrue(h.diagLines.contains("grp alone phase=4 ms=50000"))
    }

    func testSpec30_aRingingInviteeKeepsTheCallUpAndTheEndOfTheRingStartsTheTimer() {
        let h = ControllerHarness()
        let id = h.controller.createCall(invitees: [peerB]) ?? ""
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me], withMedia: false, callId: id, ringing: [peerB]))
        XCTAssertEqual(h.alone.armed, 0, "somebody still rings")
        XCTAssertEqual(h.controller.currentRinging, [peerB])
        // The ring ends (declined, or timed out) and nobody else is there: alone from now.
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me], withMedia: false, callId: id, ringing: []))
        XCTAssertEqual(h.alone.armed, 1)
        h.alone.fire()
        XCTAssertTrue(h.sentTypes.contains("group_call_end"))
        XCTAssertEqual(h.controller.state, .idle)
    }

    func testSpec30_aJoinCancelsTheTimer() {
        let h = ControllerHarness()
        let id = h.controller.createCall(invitees: [peerB]) ?? ""
        XCTAssertEqual(h.alone.armed, 1)
        h.manager.onGroupUpdate?(h.update(epoch: 2, members: [me, peerB], withMedia: false, callId: id, ringing: []))
        XCTAssertEqual(h.alone.armed, 0)
        h.alone.fire()
        XCTAssertFalse(h.sentTypes.contains("group_call_end"))
        XCTAssertNotEqual(h.controller.state, .idle)
        XCTAssertTrue(h.diagLines.contains("grp alone phase=2 ms=50000"))
        h.controller.leave()
    }

    func testSpec30_aCallPromotedFromAOneToOneCallIsNotLoneWhileThePromotionIsPending() {
        let h = ControllerHarness()
        _ = h.controller.createCall(invitees: [peerB], promotedFromCallId: "one-to-one-call")
        XCTAssertEqual(h.alone.armed, 0, "a hand-over is pending")
        h.controller.setPromotionPending(false)
        XCTAssertEqual(h.alone.armed, 1, "the hand-over is over and nobody joined")
        h.controller.setPromotionPending(true)
        XCTAssertEqual(h.alone.armed, 0)
        h.controller.leave()
    }

    func testSpec30_aJoinerThatIsLeftAloneLeavesAfterTheBackstop() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        XCTAssertEqual(h.alone.armed, 0, "the roster is not known before the first update")
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [peerB, me], withMedia: false, ringing: []))
        XCTAssertEqual(h.alone.armed, 0)
        h.manager.onGroupUpdate?(h.update(epoch: 2, members: [me], withMedia: false, ringing: []))
        XCTAssertEqual(h.alone.armed, 1)
        h.alone.fire()
        XCTAssertTrue(h.sentTypes.contains("group_call_leave"), "a joiner leaves, it does not end the call for anyone")
        XCTAssertFalse(h.sentTypes.contains("group_call_end"))
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertTrue(h.diagLines.contains("grp alone phase=3 ms=50000"))
    }

    func testSpec30_aServerWithoutTheRingingListLeavesTheCreatorToTheBackstop() {
        let h = ControllerHarness()
        let id = h.controller.createCall(invitees: [peerB]) ?? ""
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me], withMedia: false, callId: id, ringing: nil))
        XCTAssertNil(h.controller.currentRinging)
        XCTAssertEqual(h.alone.armed, 1, "an older server: nobody is known to ring")
        h.controller.leave()
    }

    func testSpec30_endingTheCallCancelsTheTimer() {
        let h = ControllerHarness()
        _ = h.controller.createCall(invitees: [peerB])
        XCTAssertEqual(h.alone.armed, 1)
        h.controller.leave()
        XCTAssertEqual(h.alone.armed, 0)
        h.alone.fire()
        XCTAssertFalse(h.sentTypes.contains("group_call_end"))
    }

    func testSpec30_theServersAloneEndTakesTheCallDownLikeAnyOtherEnd() {
        let h = ControllerHarness()
        _ = h.controller.createCall(invitees: [peerB])
        h.manager.handleGroupCallEnded(data: ["call_id": h.manager.callId ?? "", "reason": "alone"])
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.alone.armed, 0)
    }

    // MARK: 31 - ringing list

    func testSpec31_theRingingListIsReportedWithoutAnEpochBumpAndEmptiedAtTheEnd() {
        let h = ControllerHarness()
        let id = h.controller.createCall(invitees: [peerB, peerC]) ?? ""
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me], withMedia: false, callId: id, ringing: [peerB, peerC]))
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me], withMedia: false, callId: id, ringing: [peerB, peerC]))
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me], withMedia: false, callId: id, ringing: [peerC]))
        XCTAssertEqual(h.ringingReports, [[peerB, peerC], [peerC]], "reported on a change only, the epoch stays 1")
        XCTAssertEqual(h.controller.currentRinging, [peerC])
        XCTAssertTrue(h.diagLines.contains("grp ringing n=2 roster=1"))
        XCTAssertTrue(h.diagLines.contains("grp ringing n=1 roster=1"))
        h.controller.leave()
        XCTAssertEqual(h.ringingReports.last, [], "the screen is told the ringing tiles are gone")
        XCTAssertNil(h.controller.currentRinging)
    }

    func testSpec31_anUpdateWithoutTheFieldIsNoRingingList() {
        let h = ControllerHarness()
        h.controller.join(callId: ControllerHarness.callId)
        h.manager.onGroupUpdate?(h.update(epoch: 1, members: [me, peerB], withMedia: false, ringing: [peerC]))
        h.manager.onGroupUpdate?(h.update(epoch: 2, members: [me, peerB], withMedia: false, ringing: nil))
        XCTAssertNil(h.controller.currentRinging)
        XCTAssertEqual(h.ringingReports, [[peerC], []])
        h.controller.leave()
    }
}
