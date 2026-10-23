import XCTest
@testable import QAudionEngine

/// The start message of a live share while its send is in flight (WIRE_SPEC 14.6.1 rule 2): from the moment its bytes are handed to the
/// socket the start counts as left, so a stop that arrives during the send is held for the echo and never withdraws a start that then
/// leaves anyway; a hand-over that fails before any byte is written takes the start back. And the last fix goes with the key (rule 8).
final class LocationSenderInFlightTests: XCTestCase {

    private static let selfId = "b9d7540f-ece4-4b58-b03b-e0001e522085"
    private static let peerId = "a353aefc-1716-4516-9ffc-3f8d69ffe0b8"

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stopList: [String] = []
        private var withdrawnList: [String] = []
        var stops: [String] { lock.lock(); defer { lock.unlock() }; return stopList }
        var withdrawn: [String] { lock.lock(); defer { lock.unlock() }; return withdrawnList }
        func stop(_ id: String) { lock.lock(); stopList.append(id); lock.unlock() }
        func withdraw(_ id: String) { lock.lock(); withdrawnList.append(id); lock.unlock() }
    }

    private struct Fixture {
        let sender: LocationShareSender
        let recorder: Recorder
        let journal: InMemoryLocationShareJournal
        let effects: LocationShareSenderEffects
    }

    private func makeSender(id: String = "start-1") throws -> Fixture {
        let recorder = Recorder()
        let journal = InMemoryLocationShareJournal()
        let effects = LocationShareSenderEffects(sendStop: { id, _ in recorder.stop(id) }, withdrawStart: { recorder.withdraw($0) })
        let secrets = LocationShareSecrets.generate()
        let fix = LocationSenderFix(latE7: 454_642_110, lonE7: 91_899_820, accuracy: 12, approximate: false, capturedAt: 997)
        let sender = try XCTUnwrap(LocationShareSender(startClientMsgId: id, selfId: Self.selfId, peerId: Self.peerId, sid: secrets.sid,
                                                       shareKey: secrets.key, startedAt: 1_000, duration: 3_600, fix: fix,
                                                       effects: effects, journal: journal))
        return Fixture(sender: sender, recorder: recorder, journal: journal, effects: effects)
    }

    private func noWrite(_ sealed: LocationFrameCodec.Sealed) throws {}

    // MARK: A stop while the send is in flight

    func testAStopWhileTheSendIsInFlightIsHeldForTheEchoAndNeverWithdrawsTheStart() throws {
        let f = try makeSender()
        _ = f.sender.startLeftDevice()
        XCTAssertEqual(f.journal.entries().first?.phase, .sent, "the note says sent from the hand-over, before the send returns")

        let outcome = f.sender.stop(now: 1_005, final: .onTick, write: noWrite)
        XCTAssertEqual(outcome.stop, .deferred)
        XCTAssertFalse(outcome.outboxWithdrawn, "a start that may have left is not withdrawn")
        XCTAssertNil(outcome.frame, "no final frame for a start that was not acknowledged")
        XCTAssertFalse(outcome.keyHeld, "the key goes at once")
        XCTAssertTrue(f.recorder.stops.isEmpty, "no stop before the echo")
        XCTAssertTrue(f.recorder.withdrawn.isEmpty)

        let echo = f.sender.startAcknowledged(now: 1_010)
        XCTAssertEqual(echo.stop, .sent, "the echo releases the stop")
        XCTAssertEqual(f.recorder.stops, ["start-1"])
        XCTAssertTrue(f.journal.entries().isEmpty)
        // Once only.
        _ = f.sender.startAcknowledged(now: 1_011)
        XCTAssertEqual(f.recorder.stops, ["start-1"])
    }

    func testAStopBeforeTheHandOverWithdrawsTheStartAndTheLateHandOverChangesNothing() throws {
        let f = try makeSender()
        let outcome = f.sender.stop(now: 1_005, final: .onTick, write: noWrite)
        XCTAssertTrue(outcome.outboxWithdrawn)
        XCTAssertNil(outcome.stop)
        XCTAssertEqual(f.recorder.withdrawn, ["start-1"])
        // The send that was already being prepared reaches its hand-over after the withdrawal: it must not revive the share.
        _ = f.sender.startLeftDevice()
        XCTAssertTrue(f.journal.entries().isEmpty, "no note for a withdrawn start")
        let echo = f.sender.startAcknowledged(now: 1_010)
        XCTAssertNil(echo.stop)
        XCTAssertTrue(f.recorder.stops.isEmpty)
    }

    // MARK: A hand-over that failed

    func testAFailedHandOverOfARunningShareTakesTheStartBack() throws {
        let f = try makeSender()
        _ = f.sender.startLeftDevice()
        let back = f.sender.startNotSent()
        XCTAssertFalse(back.outboxWithdrawn, "the share is still running: the outbox owns the retry")
        XCTAssertEqual(f.journal.entries().first?.phase, .queued)
        // A stop now finds a start that never left: it is withdrawn and nothing is sent.
        let outcome = f.sender.stop(now: 1_020, final: .onTick, write: noWrite)
        XCTAssertTrue(outcome.outboxWithdrawn)
        XCTAssertNil(outcome.stop)
        XCTAssertEqual(f.recorder.withdrawn, ["start-1"])
        XCTAssertTrue(f.recorder.stops.isEmpty)
    }

    func testAFailedHandOverAfterTheShareEndedWithdrawsTheStartAndSendsNoStop() throws {
        let f = try makeSender()
        _ = f.sender.startLeftDevice()
        _ = f.sender.stop(now: 1_005, final: .onTick, write: noWrite)
        XCTAssertTrue(f.recorder.withdrawn.isEmpty)

        let back = f.sender.startNotSent()
        XCTAssertTrue(back.outboxWithdrawn)
        XCTAssertEqual(f.recorder.withdrawn, ["start-1"])
        XCTAssertTrue(f.journal.entries().isEmpty)
        // The echo of a start that never left cannot come; if one did, no stop is held for it any more.
        _ = f.sender.startAcknowledged(now: 1_030)
        XCTAssertTrue(f.recorder.stops.isEmpty)
        // And once only.
        _ = f.sender.startNotSent()
        XCTAssertEqual(f.recorder.withdrawn, ["start-1"])
    }

    func testAHandOverThatSucceededCannotBeTakenBackAfterTheEcho() throws {
        let f = try makeSender()
        _ = f.sender.startLeftDevice()
        _ = f.sender.startAcknowledged(now: 1_005)
        let late = f.sender.startNotSent()
        XCTAssertFalse(late.outboxWithdrawn)
        let outcome = f.sender.stop(now: 1_010, final: .now, write: noWrite)
        XCTAssertEqual(outcome.stop, .sent)
        XCTAssertEqual(f.recorder.stops, ["start-1"])
        XCTAssertTrue(f.recorder.withdrawn.isEmpty)
    }

    func testASecondAttemptAfterAFailedOneGoesTheSameWay() throws {
        let f = try makeSender()
        _ = f.sender.startLeftDevice()
        _ = f.sender.startNotSent()
        _ = f.sender.startLeftDevice()
        XCTAssertEqual(f.journal.entries().first?.phase, .sent)
        _ = f.sender.startAcknowledged(now: 1_005)
        var frames = 0
        let tick = f.sender.tick(now: 1_030) { _ in frames += 1 }
        XCTAssertNotNil(tick.frame)
        XCTAssertEqual(frames, 1)
    }

    /// A share that a previous process left may have left in that process: this process never takes it back.
    func testARecoveredSenderIsNeverTakenBackByAFailedHandOver() throws {
        let recorder = Recorder()
        let journal = InMemoryLocationShareJournal()
        let effects = LocationShareSenderEffects(sendStop: { id, _ in recorder.stop(id) }, withdrawStart: { recorder.withdraw($0) })
        let entry = LocationShareJournalEntry(startClientMsgId: "old", phase: .sent, stopSent: false)
        journal.write(entry)
        let recovered = LocationShareSender.recoverAfterRestart(entry: entry, now: 2_000, effects: effects, journal: journal)
        XCTAssertEqual(recovered.outcome.stop, .deferred)
        let back = recovered.sender.startNotSent()
        XCTAssertFalse(back.outboxWithdrawn)
        XCTAssertTrue(recorder.withdrawn.isEmpty)
        XCTAssertEqual(journal.entries().first?.phase, .sent)
        let echo = recovered.sender.startAcknowledged(now: 2_050)
        XCTAssertEqual(echo.stop, .sent, "the stop is still held for the echo and goes with it")
        XCTAssertEqual(recorder.stops, ["old"])
    }

    // MARK: The last fix goes with the key

    func testTheLastFixIsOverwrittenWhenTheShareEnds() throws {
        // Ended at once, with the socket up.
        let now = try makeSender(id: "a")
        _ = now.sender.startLeftDevice()
        _ = now.sender.startAcknowledged(now: 1_001)
        XCTAssertFalse(now.sender.heldFixIsWiped)
        _ = now.sender.stop(now: 1_010, final: .now, write: noWrite)
        XCTAssertTrue(now.sender.heldFixIsWiped)

        // Ended with the final frame on the next tick: the fix goes when the stop is made, not at the tick.
        let tickly = try makeSender(id: "b")
        _ = tickly.sender.startLeftDevice()
        _ = tickly.sender.startAcknowledged(now: 1_001)
        _ = tickly.sender.stop(now: 1_010, final: .onTick, write: noWrite)
        XCTAssertTrue(tickly.sender.heldFixIsWiped)
        XCTAssertNotNil(tickly.sender.tick(now: 1_030, write: noWrite).frame, "the final frame needs no position")

        // A start that never left.
        let queued = try makeSender(id: "c")
        _ = queued.sender.stop(now: 1_010, final: .onTick, write: noWrite)
        XCTAssertTrue(queued.sender.heldFixIsWiped)

        // A start held for the echo.
        let held = try makeSender(id: "d")
        _ = held.sender.startLeftDevice()
        _ = held.sender.stop(now: 1_010, final: .onTick, write: noWrite)
        XCTAssertTrue(held.sender.heldFixIsWiped)

        // The end time.
        let timed = try makeSender(id: "e")
        _ = timed.sender.startLeftDevice()
        _ = timed.sender.startAcknowledged(now: 1_001)
        _ = timed.sender.tick(now: 1_000 + 3_600, write: noWrite)
        XCTAssertTrue(timed.sender.heldFixIsWiped)
    }

    func testANewFixAfterTheEndIsNotKept() throws {
        let f = try makeSender()
        _ = f.sender.startLeftDevice()
        _ = f.sender.startAcknowledged(now: 1_001)
        _ = f.sender.stop(now: 1_010, final: .now, write: noWrite)
        f.sender.update(fix: LocationSenderFix(latE7: 1, lonE7: 2, accuracy: 3, approximate: false, capturedAt: 1_011))
        XCTAssertTrue(f.sender.heldFixIsWiped, "a fix that arrives after the end is dropped")
    }
}
