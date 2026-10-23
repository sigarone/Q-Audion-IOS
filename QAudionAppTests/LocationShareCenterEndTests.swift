import XCTest
@testable import QAudionApp
import QAudionEngine

/// The app side of live location sharing against the contract (WIRE_SPEC 14.6.1 rules 2, 7, 8 and 10, 14.6.2, 14.6.6; docs/LOCATION_SHARING.md
/// 1.3, 1.4): every trigger that ends a share (the conversation cleared or deleted from the chat list, "delete for me", delete for
/// everyone, a blocked peer, a changed identity key, the permission revoked, the remote switch off, a logout, the end time), the
/// disappearing-message timer that starts when a share ends, the recovery after a restart, a stop that arrives while the start is being
/// sent, `msg_sent` handling, and one whole share from the start to a restart.
///
/// Runs against `LocationCenterFixture`: fake rows, a journal and receiver stores in memory, a socket that is up, the stop recorded. No
/// database, no keychain, no network, no location manager.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class LocationShareCenterEndTests: XCTestCase {

    private var fx: LocationCenterFixture!
    private var center: LocationShareCenter { fx.center }
    private var peer: String { LocationCenterFixture.peerId }

    override func setUp() {
        super.setUp()
        fx = LocationCenterFixture()
    }

    override func tearDown() {
        fx.tearDown()
        fx = nil
        super.tearDown()
    }

    // MARK: Triggers that end a share

    func test_clearingTheConversationEndsTheSentShareAndTheReceivedOne() throws {
        let own = try fx.startAcknowledgedShare()
        let inbound = fx.receiveStart(id: "recv-1")
        XCTAssertEqual(inbound.decision, .record)
        XCTAssertEqual(fx.received("recv-1")?.state, .active)

        center.conversationCleared(peerUserId: peer)

        XCTAssertTrue(center.activeShares.isEmpty, "the strip and the chip are gone")
        XCTAssertEqual(fx.stopTargets(), [own.id], "one loc_stop for the sent share")
        XCTAssertEqual(fx.stops.first?.held, true)
        XCTAssertEqual(fx.frames.count, 1, "the final frame of the sent share goes at once, while the socket is up")
        let view = try XCTUnwrap(fx.received("recv-1"))
        XCTAssertEqual(view.state, .ended)
        XCTAssertTrue(view.noCard, "no card is left for a received share that was cleared")
        // The ids of the start stay: the same start again is a duplicate.
        let live = try liveStart(of: inbound)
        let first = try position(of: inbound)
        let again = center.receivers[peer]?.receiveStart(clientMsgId: "recv-1", live: live, position: first, now: LocationShareCenter.nowUnix())
        XCTAssertEqual(again, .dropped(.startDuplicate))
    }

    func test_deletingTheConversationFromTheListEndsTheShares() throws {
        // The real list container over the real conversation store: the wiring of `deleteConversation` is what is tested.
        let store = ConversationStore()
        let conversation = Conversation(id: UUID(), peerUserId: peer, peerDisplayName: "Test", lastMessagePreview: nil,
                                        lastActivity: Date(), unreadCount: 0, pinned: false, kind: .oneToOne)
        store.upsertConversation(conversation)
        addTeardownBlock { store.deleteConversation(id: conversation.id) }
        guard store.loadConversations().contains(where: { $0.id == conversation.id }) else {
            throw XCTSkip("the test host has no usable conversation store")
        }
        let own = try fx.startAcknowledgedShare()
        _ = fx.receiveStart(id: "recv-1")

        let container = ConversationListContainer(store: store)
        container.deleteConversation(conversationId: conversation.id)

        XCTAssertFalse(store.loadConversations().contains(where: { $0.id == conversation.id }), "the conversation is gone")
        XCTAssertTrue(center.activeShares.isEmpty, "the sent share ended with the conversation")
        XCTAssertEqual(fx.stopTargets(), [own.id])
        XCTAssertEqual(fx.received("recv-1")?.state, .ended, "and so did the received one")
        XCTAssertEqual(fx.received("recv-1")?.noCard, true)
    }

    func test_deleteForMeOfAReceivedStartEndsItsShareAndKeepsTheIds() throws {
        let inbound = fx.receiveStart(id: "recv-1")
        center.rowDeletedForMe(clientMsgId: "recv-1", peerUserId: peer)
        let view = try XCTUnwrap(fx.received("recv-1"))
        XCTAssertEqual(view.state, .ended)
        XCTAssertTrue(view.noCard)
        XCTAssertTrue(fx.stops.isEmpty, "a received share sends nothing when its row is deleted")
        let live = try liveStart(of: inbound)
        let first = try position(of: inbound)
        let again = center.receivers[peer]?.receiveStart(clientMsgId: "recv-1", live: live, position: first, now: LocationShareCenter.nowUnix())
        XCTAssertEqual(again, .dropped(.startDuplicate))
    }

    func test_deleteForMeOfAnOwnStartEndsTheShareWithTheFinalFrameOnTheNextTick() throws {
        let own = try fx.startAcknowledgedShare()
        center.rowDeletedForMe(clientMsgId: own.id, peerUserId: peer)
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertEqual(fx.stopTargets(), [own.id], "the stop goes at once")
        XCTAssertEqual(fx.frames.count, 0, "the final frame waits for the next tick")
        center.tick(startClientMsgId: own.id)
        XCTAssertEqual(fx.frames.count, 1)
    }

    func test_deleteForEveryoneEndsTheOwnShareAndTheReceivedOne() throws {
        let own = try fx.startAcknowledgedShare()
        center.ownRowDeletedForEveryone(clientMsgId: own.id)
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertEqual(fx.stopTargets(), [own.id])

        _ = fx.receiveStart(id: "recv-1")
        center.handleDeleteForEveryone(senderId: peer, target: "recv-1")
        let view = try XCTUnwrap(fx.received("recv-1"))
        XCTAssertEqual(view.state, .ended)
        XCTAssertEqual(view.reason, .deleted)
        XCTAssertTrue(view.noCard)
    }

    func test_aDeleteForEveryoneThatOvertakesItsStartLeavesNoCardAndNoRow() throws {
        center.handleDeleteForEveryone(senderId: peer, target: "future-1")
        let inbound = fx.receiveStart(id: "future-1")
        XCTAssertEqual(inbound.decision, .skipRow, "the start is handled by the delete path: no row, no live-share card")
        XCTAssertNil(fx.rows.rows["future-1"])
        XCTAssertEqual(fx.received("future-1")?.reason, .deleted)
    }

    func test_blockingThePeerEndsTheSentShareAndTheReceivedOne() throws {
        let own = try fx.startAcknowledgedShare()
        _ = fx.receiveStart(id: "recv-1")
        center.blockListChanged(blockedNow: [peer])
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertEqual(fx.stopTargets(), [own.id])
        XCTAssertEqual(fx.received("recv-1")?.state, .ended)
        XCTAssertEqual(fx.received("recv-1")?.reason, .blocked)
        // Frames and stops from a blocked sender are dropped, and a new start is ignored until the peer is unblocked.
        XCTAssertEqual(fx.receiveStart(id: "recv-2").decision, .record)
        XCTAssertNil(fx.received("recv-2"), "a start from a blocked peer creates no share")
        center.blockListChanged(blockedNow: [])
        XCTAssertEqual(fx.receiveStart(id: "recv-3").decision, .record)
        XCTAssertEqual(fx.received("recv-3")?.state, .active)
    }

    func test_aChangedIdentityKeyEndsTheSentShare() throws {
        let own = try fx.startAcknowledgedShare()
        center.peerIdentityChanged(peerUserId: peer)
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertEqual(fx.stopTargets(), [own.id])
        XCTAssertEqual(fx.frames.count, 1, "the final frame goes at once")
    }

    func test_aChangedIdentityKeyOfAnotherPeerDoesNotTouchTheShare() throws {
        _ = try fx.startAcknowledgedShare()
        center.peerIdentityChanged(peerUserId: "c0ffee00-0000-4000-8000-000000000009")
        XCTAssertEqual(center.activeShares.count, 1)
        XCTAssertTrue(fx.stops.isEmpty)
    }

    func test_aRevokedPermissionEndsTheShares() throws {
        let own = try fx.startAcknowledgedShare()
        center.authorizationOverride = false
        center.authorizationChanged()
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertEqual(fx.stopTargets(), [own.id])
    }

    func test_theRemoteSwitchTurnedOffEndsTheShares() throws {
        let own = try fx.startAcknowledgedShare()
        LocationShareCenter.featureOverride = false
        center.flagsRefreshed()
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertEqual(fx.stopTargets(), [own.id])
    }

    func test_aLogoutEndsTheSharesAndForgetsEverything() throws {
        let own = try fx.startAcknowledgedShare()
        _ = fx.receiveStart(id: "recv-1")
        center.accountLeft()
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertTrue(center.runs.isEmpty)
        XCTAssertTrue(center.waitingForEcho.isEmpty)
        XCTAssertTrue(center.receivers.isEmpty)
        XCTAssertNil(center.connectionToken)
        XCTAssertEqual(fx.stopTargets(), [own.id])
        XCTAssertEqual(fx.stops.first?.held, false, "the stop of a logout is dropped if it cannot go at once, never held for the next account")
    }

    func test_theEndTimeEndsTheShareWithTheStopAndTheFinalFrameAndStartsTheTimer() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock
        let own = try fx.startAcknowledgedShare(duration: 900, timerSeconds: 3_600)
        XCTAssertEqual(own.startedAt, LocationCenterFixture.clock)
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 900
        center.tick(startClientMsgId: own.id)
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertEqual(fx.stopTargets(), [own.id])
        XCTAssertEqual(fx.frames.count, 1, "the final frame goes at once when the end time is reached")
        XCTAssertNil(center.connectionToken)
        // The row follows the timer of the conversation from the moment the share ended.
        XCTAssertEqual(fx.rows.expiry(of: own.id), Date(timeIntervalSince1970: Double(LocationCenterFixture.clock + 900 + 3_600)))
        // Nothing is left to tick.
        center.tick(startClientMsgId: own.id)
        XCTAssertEqual(fx.frames.count, 1)
    }

    // MARK: The timer of an ended share

    func test_aStartCreatedEndedFollowsTheTimerOnceItsRowIsWritten() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock
        // The sender's clock says the start is a day old: the share is over on arrival (expired).
        let inbound = fx.receiveStart(id: "late-1", startedAt: LocationCenterFixture.clock - 100_000, duration: 900, timerSeconds: 3_600)
        XCTAssertEqual(inbound.decision, .record, "a start created ended still has its row")
        XCTAssertEqual(fx.received("late-1")?.reason, .expired)
        XCTAssertEqual(fx.rows.expiry(of: "late-1"), Date(timeIntervalSince1970: Double(LocationCenterFixture.clock + 3_600)),
                       "the timer runs from the end of the share, which is the moment it was found over")
        // Idempotent: another sweep changes nothing.
        let writes = fx.rows.expiryWrites
        center.sweepEndedExpiries()
        center.refreshReceivers()
        XCTAssertEqual(fx.rows.expiryWrites, writes)
    }

    func test_aConversationWithoutATimerLeavesTheRowAlone() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock
        _ = fx.receiveStart(id: "late-1", startedAt: LocationCenterFixture.clock - 100_000, duration: 900, timerSeconds: nil)
        XCTAssertNil(fx.rows.expiry(of: "late-1"))
        _ = fx.receiveStart(id: "late-2", startedAt: LocationCenterFixture.clock - 100_000, duration: 900, timerSeconds: -1)
        XCTAssertNil(fx.rows.expiry(of: "late-2"), "view-once is not a timer")
    }

    func test_aRowThatIsNotThereYetIsWaitedForAndThenGivenUp() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock
        _ = fx.receiveStart(id: "late-1", startedAt: LocationCenterFixture.clock - 100_000, duration: 900, writeRow: false)
        XCTAssertFalse(center.expirySettled.contains("late-1"), "no row yet: tried again later")
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 60
        center.sweepEndedExpiries()
        XCTAssertFalse(center.expirySettled.contains("late-1"))
        // The row is written a moment later.
        fx.rows.add(clientMsgId: "late-1", peerUserId: peer, outgoing: false, plaintext: "x", timerSeconds: 600)
        center.inboundStartRecorded()
        XCTAssertEqual(fx.rows.expiry(of: "late-1"), Date(timeIntervalSince1970: Double(LocationCenterFixture.clock + 600)))
        XCTAssertTrue(center.expirySettled.contains("late-1"))

        // A row that never comes is given up after the grace time.
        _ = fx.receiveStart(id: "late-2", startedAt: LocationCenterFixture.clock - 100_000, duration: 900, writeRow: false)
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 60 + LocationShareCenter.rowGraceSeconds + 1
        center.sweepEndedExpiries()
        XCTAssertTrue(center.expirySettled.contains("late-2"))
    }

    func test_aShareThatEndedWhileTheAppWasClosedGetsItsTimerAtLaunch() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock
        let inbound = fx.receiveStart(id: "recv-1", duration: 900, timerSeconds: 3_600)
        XCTAssertEqual(inbound.decision, .record)
        XCTAssertNil(fx.rows.expiry(of: "recv-1"), "a live row is exempt from the timer while the share runs")

        // The app is closed; the share's end time passes; the app starts again.
        fx.simulateRestart()
        fx.knownPeers = [peer]
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 5_000
        center.start()

        XCTAssertEqual(fx.purgeCalls, [LocationCenterFixture.clock + 5_000], "the ids that need no keeping are forgotten at launch")
        XCTAssertEqual(fx.received("recv-1")?.reason, .expired)
        XCTAssertEqual(fx.rows.expiry(of: "recv-1"), Date(timeIntervalSince1970: Double(LocationCenterFixture.clock + 5_000 + 3_600)))
    }

    func test_aShareDeletedForMeNeverGivesItsRowATimer() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock
        _ = fx.receiveStart(id: "recv-1", duration: 900, timerSeconds: 3_600)
        center.rowDeletedForMe(clientMsgId: "recv-1", peerUserId: peer)
        center.sweepEndedExpiries()
        XCTAssertNil(fx.rows.expiry(of: "recv-1"), "no card is left for it, and the row is the delete path's")
    }

    // MARK: Restart recovery (rule 10)

    private func writeOwnRow(_ id: String, timerSeconds: Int? = 3_600) throws -> String {
        let secrets = LocationShareSecrets.generate()
        let fix = LocationFix(latitude: 45.4642110, longitude: 9.1899820, horizontalAccuracy: 12, elapsedMs: 3_000, approximate: false)
        guard case .success(let body) = LocationCodec.buildLiveStart(fix: fix, sid: secrets.sid, key: secrets.key,
                                                                     startedAt: LocationCenterFixture.clock, duration: 900) else {
            throw LocationFixtureError.startRefused
        }
        fx.rows.add(clientMsgId: id, peerUserId: peer, outgoing: true, plaintext: body, timerSeconds: timerSeconds)
        fx.rows.outbox.insert(id)
        return body
    }

    func test_aStartThatNeverLeftIsWithdrawnAtRestartAndNothingIsSent() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 100
        _ = try writeOwnRow("own-1")
        fx.journal.write(LocationShareJournalEntry(startClientMsgId: "own-1", phase: .queued, stopSent: false))
        center.start()
        XCTAssertNil(fx.rows.rows["own-1"], "the row, which holds the key, is removed")
        XCTAssertFalse(fx.rows.outbox.contains("own-1"))
        XCTAssertTrue(fx.stops.isEmpty)
        XCTAssertTrue(fx.frames.isEmpty, "a restarted process builds no frame")
        XCTAssertTrue(fx.journal.entries().isEmpty)
        XCTAssertFalse(center.startBeingSent(clientMsgId: "own-1"), "a send that was being prepared finds the start withdrawn")
        XCTAssertTrue(center.interruptedNotice)
    }

    func test_aStartThatLeftButWasNotAcknowledgedIsSentAgainAndItsStopWaitsForTheEcho() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 100
        let body = try writeOwnRow("own-1")
        fx.journal.write(LocationShareJournalEntry(startClientMsgId: "own-1", phase: .sent, stopSent: false))
        center.start()
        XCTAssertEqual(fx.rows.requeued, ["own-1"], "the row goes back to the outbox, under the same client message id")
        XCTAssertEqual(fx.rows.plaintext(of: "own-1"), body, "the row still holds what the outbox must send")
        XCTAssertTrue(fx.stops.isEmpty, "no stop before the echo")
        XCTAssertTrue(fx.frames.isEmpty)
        XCTAssertNotNil(center.waitingForEcho["own-1"])
        XCTAssertTrue(center.startBeingSent(clientMsgId: "own-1"), "the outbox may send it")

        center.handleMsgSent(clientMsgId: "own-1", serverMsgId: "srv-1") { _, _ in }
        XCTAssertEqual(fx.stopTargets(), ["own-1"], "the echo releases the stop")
        XCTAssertNil(center.waitingForEcho["own-1"])
        XCTAssertFalse((fx.rows.plaintext(of: "own-1") ?? "").contains("\"k\""), "after the echo the row holds no key")
        XCTAssertNotNil(fx.rows.expiry(of: "own-1"), "the share is over: its row follows the timer")
        XCTAssertTrue(fx.frames.isEmpty)
    }

    func test_anAcknowledgedStartIsStoppedAtRestartAndItsRowFollowsTheTimer() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 100
        _ = try writeOwnRow("own-1")
        fx.journal.write(LocationShareJournalEntry(startClientMsgId: "own-1", phase: .echoed, stopSent: false))
        center.start()
        XCTAssertEqual(fx.stopTargets(), ["own-1"])
        XCTAssertEqual(fx.stops.first?.held, true)
        XCTAssertTrue(fx.frames.isEmpty, "no final frame either: the key died with the process")
        let text = try XCTUnwrap(fx.rows.plaintext(of: "own-1"))
        XCTAssertTrue(LocationRowForm.isLocalLiveForm(text), "the row is rewritten to its local form")
        XCTAssertEqual(fx.rows.expiry(of: "own-1"), Date(timeIntervalSince1970: Double(LocationCenterFixture.clock + 100 + 3_600)))
        XCTAssertTrue(fx.journal.entries().isEmpty)
    }

    func test_aShareWhoseStopAlreadyWentSendsNoSecondStopAtRestart() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 100
        _ = try writeOwnRow("own-1")
        fx.journal.write(LocationShareJournalEntry(startClientMsgId: "own-1", phase: .echoed, stopSent: true))
        center.start()
        XCTAssertTrue(fx.stops.isEmpty)
        XCTAssertTrue(fx.frames.isEmpty)
    }

    // MARK: A stop while the start is being sent (rule 2)

    func test_aStopWhileTheSendIsInFlightIsHeldForTheEchoAndStillSendsTheStop() throws {
        let own = try fx.startShare()
        XCTAssertTrue(fx.handOver(own), "the bytes are about to be handed to the socket")
        center.stopShare(startClientMsgId: own.id, reason: "user", final: .onTick)
        XCTAssertTrue(center.activeShares.isEmpty, "the user sees the share end at once")
        XCTAssertNotNil(fx.rows.rows[own.id], "the start may have left: it is not withdrawn")
        XCTAssertTrue(fx.rows.removedRows.isEmpty)
        XCTAssertTrue(fx.stops.isEmpty, "no stop before the echo")
        XCTAssertNotNil(center.waitingForEcho[own.id])
        center.tick(startClientMsgId: own.id)
        XCTAssertTrue(fx.frames.isEmpty, "and no frame for a start that was not acknowledged")

        fx.echo(own)
        XCTAssertEqual(fx.stopTargets(), [own.id], "the echo releases the stop: the peer is not left with a live card")
        XCTAssertNil(center.waitingForEcho[own.id])
        XCTAssertTrue(LocationRowForm.isLocalLiveForm(fx.rows.plaintext(of: own.id) ?? ""), "the row no longer holds the key")
    }

    func test_aStopBeforeTheHandOverWithdrawsTheStartAndTheSendBeingPreparedSendsNothing() throws {
        let own = try fx.startShare()
        center.stopShare(startClientMsgId: own.id, reason: "user", final: .onTick)
        XCTAssertNil(fx.rows.rows[own.id], "the row, which holds the key, is removed")
        XCTAssertFalse(fx.rows.outbox.contains(own.id))
        XCTAssertTrue(fx.stops.isEmpty, "nothing was announced, so nothing is stopped")
        XCTAssertNil(center.waitingForEcho[own.id], "a withdrawn start is not parked to wait for an echo")
        XCTAssertNil(center.peerByStart[own.id])
        // The send that was already sealing the start reaches its hand-over now: it must not send it.
        XCTAssertFalse(fx.handOver(own))
    }

    func test_aHandOverThatFailsBeforeAnyByteTakesTheStartBack() throws {
        let own = try fx.startShare()
        fx.handOver(own)
        center.startNotSent(clientMsgId: own.id)
        center.stopShare(startClientMsgId: own.id, reason: "user", final: .onTick)
        XCTAssertNil(fx.rows.rows[own.id], "the start never left: it is withdrawn")
        XCTAssertTrue(fx.stops.isEmpty)
    }

    func test_aHandOverThatFailsAfterTheShareEndedWithdrawsTheStartAndSendsNoStop() throws {
        let own = try fx.startShare()
        fx.handOver(own)
        center.stopShare(startClientMsgId: own.id, reason: "user", final: .onTick)
        XCTAssertNotNil(center.waitingForEcho[own.id])
        center.startNotSent(clientMsgId: own.id)
        XCTAssertNil(center.waitingForEcho[own.id])
        XCTAssertNil(fx.rows.rows[own.id])
        XCTAssertFalse(fx.rows.outbox.contains(own.id))
        fx.echo(own)
        XCTAssertTrue(fx.stops.isEmpty, "no echo can come for a start that never left")
    }

    func test_aSendThatFailedForGoodEndsTheShareAndWithdrawsTheStart() throws {
        let own = try fx.startShare()
        fx.handOver(own)
        center.startFailed(clientMsgId: own.id)
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertNil(fx.rows.rows[own.id], "the row that holds the key goes")
        XCTAssertTrue(fx.stops.isEmpty)
        XCTAssertFalse(fx.handOver(own))
    }

    // MARK: Starting a share

    func test_aRefusedStartLeavesTheRunningShareAsItIs() throws {
        let first = try fx.startAcknowledgedShare()
        var dispatched = false
        let refused = center.startLive(reading: fx.reading(age: 300), duration: 900, peerUserId: peer, conversationId: UUID()) { _, _, _ in
            dispatched = true
        }
        if case .failure(.refused(.age)) = refused {} else { XCTFail("a stale fix was accepted") }
        XCTAssertFalse(dispatched)
        XCTAssertEqual(center.activeShares.map { $0.id }, [first.id], "the share that runs is still running")
        XCTAssertTrue(fx.stops.isEmpty)
        XCTAssertTrue(fx.frames.isEmpty)

        // A start that can go ends the previous one first.
        let second = try fx.startShare()
        XCTAssertEqual(center.activeShares.map { $0.id }, [second.id])
        XCTAssertEqual(fx.stopTargets(), [first.id])
    }

    // MARK: No location manager without a share

    func test_noLocationManagerIsMadeWhenNoShareEverRan() throws {
        LocationService.discardInstanceForTests()
        XCTAssertFalse(LocationService.hasInstance)
        LocationShareCenter.featureOverride = false
        center.flagsRefreshed()
        center.authorizationChanged()
        center.accountLeft()
        center.blockListChanged(blockedNow: [peer])
        center.conversationCleared(peerUserId: peer)
        XCTAssertFalse(LocationService.hasInstance, "ending shares that never ran must not make a CLLocationManager")
    }

    // MARK: msg_sent

    func test_msgSentBindsTheServerIdOnlyToAnOutgoingRowAndEchoesOnlyAShareItKnows() throws {
        var bound: [String] = []
        let bind: (String, String) -> Void = { client, server in bound.append(client + ">" + server) }

        // A service message: it has no row, so nothing is bound and nothing is retried.
        center.handleMsgSent(clientMsgId: "svc-1", serverMsgId: "srv-1", bindServerId: bind)
        XCTAssertTrue(bound.isEmpty)
        XCTAssertTrue(center.echoedStarts.isEmpty)

        // An inbound row with this id is not ours to bind either.
        fx.rows.add(clientMsgId: "in-1", peerUserId: peer, outgoing: false, plaintext: "x")
        center.handleMsgSent(clientMsgId: "in-1", serverMsgId: "srv-2", bindServerId: bind)
        XCTAssertTrue(bound.isEmpty)

        // The start of a share: bound, and the echo reaches the sender.
        let own = try fx.startShare()
        fx.handOver(own)
        center.handleMsgSent(clientMsgId: own.id, serverMsgId: "srv-3", bindServerId: bind)
        XCTAssertEqual(bound, [own.id + ">srv-3"])
        XCTAssertTrue(center.echoedStarts.contains(own.id))

        // An outgoing message that is not a share (a pin, a text): bound, and the center ignores the echo.
        fx.rows.add(clientMsgId: "out-1", peerUserId: peer, outgoing: true, plaintext: "ciao")
        center.handleMsgSent(clientMsgId: "out-1", serverMsgId: "srv-4", bindServerId: bind)
        XCTAssertEqual(bound.count, 2)
        XCTAssertFalse(center.echoedStarts.contains("out-1"))
        XCTAssertNil(center.waitingForEcho["out-1"])
    }

    // MARK: Recognition on the bytes

    func test_aBodyIsRecognisedOnTheBytesAsDecrypted() throws {
        let secrets = LocationShareSecrets.generate()
        let fix = LocationFix(latitude: 45.4642110, longitude: 9.1899820, horizontalAccuracy: 12, elapsedMs: 3_000, approximate: false)
        guard case .success(let body) = LocationCodec.buildLiveStart(fix: fix, sid: secrets.sid, key: secrets.key,
                                                                     startedAt: LocationShareCenter.nowUnix(), duration: 900) else {
            return XCTFail("the builder refused")
        }
        // A valid version-1 start with an unknown member whose text is not valid UTF-8.
        var bytes = Data(body.utf8.dropLast())
        bytes.append(contentsOf: Array(#","x":""#.utf8))
        bytes.append(0xFF)
        bytes.append(contentsOf: Array(#""}"#.utf8))
        XCTAssertNil(String(data: bytes, encoding: .utf8), "the body is not valid UTF-8")
        // A text built from it by repairing the bad byte (what `String(decoding:)` does) would be a valid start...
        let repaired = String(decoding: bytes, as: UTF8.self)
        guard case .location(.live) = LocationCodec.recognize(repaired, channel: .chat) else {
            return XCTFail("the repaired text should look like a valid start")
        }
        // ...but the body that arrived is bad_location: no share, no key.
        let decision = center.handleInboundBody(bytes, senderId: peer, clientMsgId: "bad-utf8", viaMesh: false)
        XCTAssertEqual(decision, .record, "the write boundary turns the row into its placeholder")
        XCTAssertNil(fx.received("bad-utf8"), "no share is created for a body that is not valid UTF-8")
        XCTAssertNil(center.receivers[peer]?.share(id: "bad-utf8", now: LocationShareCenter.nowUnix()))
    }

    // MARK: A whole share

    private func forbiddenInLogs(_ started: LocationCenterFixture.Started) -> [String] {
        ["454642110", "91899820", "45.4642", "9.1899", started.sid.base64EncodedString(), started.key.base64EncodedString()]
    }

    func test_aWholeShareFromTheStartToARestartLogsNoPositionAndNoKey() throws {
        LocationShareCenter.nowOverride = LocationCenterFixture.clock
        let logsFrom = Date()
        var secrets: [LocationCenterFixture.Started] = []

        // Share 1: start, hand-over, echo, three ticks, a stop on the next tick.
        let first = try fx.startShare(duration: 3_600, timerSeconds: 7_200)
        secrets.append(first)
        XCTAssertTrue(fx.handOver(first))
        guard case .location(.live(let liveStart, let livePosition)) = LocationCodec.recognize(first.body, channel: .chat) else {
            return XCTFail("the start is not a valid live start")
        }
        let remote = try LocationShareReceiver(selfId: peer, peerId: LocationCenterFixture.selfId, store: InMemoryLocationShareStore(),
                                               now: LocationCenterFixture.clock)
        XCTAssertEqual(remote.receiveStart(clientMsgId: first.id, live: liveStart, position: livePosition, now: LocationCenterFixture.clock), .applied)
        center.tick(startClientMsgId: first.id)
        XCTAssertTrue(fx.frames.isEmpty, "no frame before the echo")
        fx.echo(first)
        XCTAssertTrue(LocationRowForm.isLocalLiveForm(fx.rows.plaintext(of: first.id) ?? ""), "the echo rewrites the row without the key")
        for step in 1...3 {
            LocationShareCenter.nowOverride = LocationCenterFixture.clock + Int64(30 * step)
            center.tick(startClientMsgId: first.id)
        }
        XCTAssertEqual(fx.frames.count, 3, "one frame per tick")
        for (index, frame) in fx.frames.enumerated() {
            XCTAssertEqual(remote.receiveFrame(payload: frame.payload, now: LocationCenterFixture.clock + Int64(30 * (index + 1))), .applied)
        }
        center.stopShare(startClientMsgId: first.id, reason: "user", final: .onTick)
        XCTAssertEqual(fx.stopTargets(), [first.id])
        LocationShareCenter.nowOverride = LocationCenterFixture.clock + 120
        center.tick(startClientMsgId: first.id)
        XCTAssertEqual(fx.frames.count, 4, "the final frame goes on the next tick")
        XCTAssertEqual(remote.receiveFrame(payload: fx.frames[3].payload, now: LocationCenterFixture.clock + 120), .applied)
        XCTAssertEqual(remote.share(id: first.id, now: LocationCenterFixture.clock + 120)?.reason, .stopped)
        XCTAssertEqual(fx.rows.expiry(of: first.id), Date(timeIntervalSince1970: Double(LocationCenterFixture.clock + 120 + 7_200)))

        // Share 2: handed to the socket, and the process dies before the echo.
        let second = try fx.startShare(duration: 3_600, timerSeconds: 7_200)
        secrets.append(second)
        XCTAssertTrue(fx.handOver(second))
        let framesBefore = fx.frames.count
        fx.simulateRestart()
        center.start()
        XCTAssertEqual(fx.rows.requeued, [second.id])
        XCTAssertEqual(fx.stops.count, 1, "no stop before the echo")
        fx.echo(second)
        XCTAssertEqual(fx.stopTargets(), [first.id, second.id])
        XCTAssertEqual(fx.frames.count, framesBefore, "a restarted process builds no frame")

        // Whatever was logged along the way carries no position, no key and no share id.
        let lines: [String] = RuntimeLogSink.shared.snapshotEntries.filter { $0.timestamp >= logsFrom }.map { $0.message }
        XCTAssertTrue(lines.contains { $0.contains("loc event=start") }, "the capture sees the log lines of the share")
        for started in secrets {
            for needle in forbiddenInLogs(started) {
                XCTAssertFalse(lines.contains { $0.contains(needle) }, "a log line carries \"\(needle.prefix(6))...\"")
            }
        }
    }

    // MARK: Helpers

    private func liveStart(of inbound: LocationCenterFixture.Inbound) throws -> LocationLiveStart {
        guard case .location(.live(let start, _)) = LocationCodec.recognize(inbound.body, channel: .chat) else {
            throw LocationFixtureError.startRefused
        }
        return start
    }

    private func position(of inbound: LocationCenterFixture.Inbound) throws -> LocationPosition {
        guard case .location(.live(_, let position)) = LocationCodec.recognize(inbound.body, channel: .chat) else {
            throw LocationFixtureError.startRefused
        }
        return position
    }
}
