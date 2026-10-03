import XCTest
@testable import QAudionEngine

/// R-KCMAC-ROUNDS (WIRE_SPEC §3.7.1, K-round of 2026-10-03): every undecided round is kept with its own expected peer
/// MAC and judged by content; a MAC that matches no pending round is held and never ends the call by itself; a decided
/// round's MAC is a duplicate; the pending and held sets are bounded. The ids K1-a ... K1-j are the shared test ids of
/// the three clients.
final class KcMacRoundBookTests: XCTestCase {

    /// A synthetic round context: a distinct `K_kc` and transcript per label, and this side's role in that round.
    private func context(_ label: String, initiator: Bool) -> KcMacRound {
        KcMacRound(
            kcKey: KeyConfirmation.deriveKcKey(sessionKey: Data(label.utf8) + Data(repeating: 0x5A, count: 32)),
            transcript: Data("transcript-\(label)".utf8),
            isInitiator: initiator)
    }

    private func pendingRound(_ number: Int, initiator: Bool = true) -> KcMacRoundBook.PendingRound {
        KcMacRoundBook.PendingRound(round: number, context: context("round-\(number)", initiator: initiator))
    }

    /// The `KCMAC:` payload the PEER sends for `round`: `role || MAC`.
    private func peerPayload(_ round: KcMacRoundBook.PendingRound, role: UInt8? = nil) -> String {
        (Data([role ?? round.peerRole]) + round.expectedPeerMac).base64EncodedString()
    }

    /// A well-formed payload that is the MAC of no round.
    private func stranger(_ seed: UInt8) -> String {
        (Data([0x01]) + Data(repeating: seed, count: 32)).base64EncodedString()
    }

    // MARK: - Payload format (step 1)

    func testTheExpectedMacIsTheComplementOfOurRoleInThatRound() {
        let asInit = pendingRound(1, initiator: true)
        XCTAssertEqual(asInit.peerRole, 0x02)
        XCTAssertEqual(asInit.expectedPeerMac, KeyConfirmation.macResp(kcKey: context("round-1", initiator: true).kcKey,
                                                                      transcript: context("round-1", initiator: true).transcript))
        let asResp = pendingRound(2, initiator: false)
        XCTAssertEqual(asResp.peerRole, 0x01)
        XCTAssertEqual(asResp.expectedPeerMac, KeyConfirmation.macInit(kcKey: context("round-2", initiator: false).kcKey,
                                                                      transcript: context("round-2", initiator: false).transcript))
    }

    func testOnlyTheExactCanonicalFortyFourCharacterPayloadIsWellFormed() throws {
        let good = stranger(7)
        XCTAssertEqual(good.count, 44)
        XCTAssertNotNil(KcMacRoundBook.parse(payload: good))
        XCTAssertNil(KcMacRoundBook.parse(payload: String(good.dropLast())), "43 characters")
        XCTAssertNil(KcMacRoundBook.parse(payload: good + "A"), "45 characters")
        XCTAssertNil(KcMacRoundBook.parse(payload: good + "\n"), "trailing whitespace")
        XCTAssertNil(KcMacRoundBook.parse(payload: String(good.dropLast()) + "!"), "not base64")
        XCTAssertNil(KcMacRoundBook.parse(payload: Data(count: 32).base64EncodedString()), "32 bytes")
        XCTAssertNil(KcMacRoundBook.parse(payload: Data(count: 34).base64EncodedString()), "34 bytes")
        XCTAssertNil(KcMacRoundBook.parse(payload: ""))
        let parsed = try XCTUnwrap(KcMacRoundBook.parse(payload: good))
        XCTAssertEqual(parsed.role, 0x01)
        XCTAssertEqual(parsed.mac, Data(repeating: 7, count: 32))
    }

    /// K1-d: a malformed payload is dropped at once, is never held and never judged.
    func testAMalformedPayloadIsNeverJudgedNorHeld() {
        var book = KcMacRoundBook()
        _ = book.arm(pendingRound(1), nowMs: 0)
        XCTAssertEqual(book.receive(payload: "not base64!", nowMs: 10), .malformed)
        XCTAssertEqual(book.receive(payload: Data(count: 34).base64EncodedString(), nowMs: 10), .malformed)
        XCTAssertEqual(book.heldCount, 0)
        XCTAssertEqual(book.pendingRounds, [1])
    }

    // MARK: - K1-a: a re-sent MAC of round N after N+1 was armed

    func testTheMacOfRoundNStillVerifiesRoundNAfterRoundNPlusOneWasArmed() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1)
        let r2 = pendingRound(2)
        _ = book.arm(r1, nowMs: 0)
        _ = book.arm(r2, nowMs: 5_000)
        XCTAssertEqual(book.pendingRounds, [1, 2], "arming N+1 does not cancel, decide or shorten N")
        XCTAssertEqual(book.receive(payload: peerPayload(r1), nowMs: 6_000), .decided(.verified(round: 1)))
        XCTAssertEqual(book.pendingRounds, [2], "round 2 is untouched")
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 7_000), .decided(.verified(round: 2)))
        XCTAssertEqual(book.pendingCount, 0)
    }

    /// The arming order does not matter: the newer round's MAC may arrive first.
    func testAttributionIsByContentWhateverTheArmingOrder() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1)
        let r2 = pendingRound(2, initiator: false)
        _ = book.arm(r1, nowMs: 0)
        _ = book.arm(r2, nowMs: 1_000)
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 2_000), .decided(.verified(round: 2)))
        XCTAssertEqual(book.receive(payload: peerPayload(r1), nowMs: 3_000), .decided(.verified(round: 1)))
    }

    // MARK: - K1-b: a superseded round is still judged

    func testASupersededRoundStaysPendingUntilItsOwnWindowEnds() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1)
        let r2 = pendingRound(2)
        _ = book.arm(r1, nowMs: 0)
        _ = book.arm(r2, nowMs: 5_000)
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 6_000), .decided(.verified(round: 2)))
        // The MAC of round 1 never came: round 1 is still pending and its own window decides.
        XCTAssertTrue(book.isPending(round: 1))
        XCTAssertTrue(book.expire(round: 1), "the window of round 1 ended while it was pending: kcmac_mismatch")
        XCTAssertFalse(book.expire(round: 1), "nothing left to expire")
        XCTAssertFalse(book.expire(round: 2), "a verified round does not expire")
    }

    // MARK: - K1-c: a later round's MAC is held while one round is pending

    func testTheMacOfALaterRoundIsHeldAndJudgedWhenThatRoundIsArmed() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1)
        let r2 = pendingRound(2)
        _ = book.arm(r1, nowMs: 0)
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 1_000), .held,
                       "it matches no pending round: held, never judged wrong against round 1")
        XCTAssertEqual(book.pendingRounds, [1])
        let armed = book.arm(r2, nowMs: 2_000)
        XCTAssertFalse(armed.overflow)
        XCTAssertEqual(armed.verdicts, [.verified(round: 2)])
        XCTAssertEqual(book.heldCount, 0)
        XCTAssertEqual(book.receive(payload: peerPayload(r1), nowMs: 3_000), .decided(.verified(round: 1)))
        XCTAssertEqual(book.pendingCount, 0)
    }

    // MARK: - K1-d: a MAC that matches nothing never ends the call by itself

    func testAMacThatMatchesNothingIsHeldAndNeverJudged() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1)
        _ = book.arm(r1, nowMs: 0)
        XCTAssertEqual(book.receive(payload: stranger(0x42), nowMs: 100), .held, "garbage")
        let reflected = (Data([0x01]) + KeyConfirmation.macInit(kcKey: context("round-1", initiator: true).kcKey,
                                                                transcript: context("round-1", initiator: true).transcript))
            .base64EncodedString()
        XCTAssertEqual(book.receive(payload: reflected, nowMs: 200), .held, "our own MAC reflected back")
        XCTAssertEqual(book.receive(payload: "junk", nowMs: 300), .malformed)
        XCTAssertEqual(book.pendingRounds, [1], "nothing was decided")
        XCTAssertEqual(book.receive(payload: peerPayload(r1), nowMs: 10_000), .decided(.verified(round: 1)),
                       "the correct MAC at 10 s still verifies")
    }

    // MARK: - K1-e: the right MAC with the wrong role byte ends the call at once

    func testTheRightMacWithTheWrongRoleByteIsAMismatch() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1)
        _ = book.arm(r1, nowMs: 0)
        XCTAssertEqual(book.receive(payload: peerPayload(r1, role: 0x01), nowMs: 10), .decided(.mismatch(round: 1)))
        XCTAssertFalse(book.isPending(round: 1))
    }

    func testAHeldMacWithTheWrongRoleByteIsAMismatchWhenItsRoundIsArmed() {
        var book = KcMacRoundBook()
        let r2 = pendingRound(2)
        XCTAssertEqual(book.receive(payload: peerPayload(r2, role: 0x01), nowMs: 0), .held)
        XCTAssertEqual(book.arm(r2, nowMs: 1_000).verdicts, [.mismatch(round: 2)])
    }

    // MARK: - K1-f: a duplicate of a decided round while a later round is pending

    func testADuplicateOfADecidedRoundIsDroppedAndTheLaterRoundIsUntouched() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1)
        let r2 = pendingRound(2)
        _ = book.arm(r1, nowMs: 0)
        XCTAssertEqual(book.receive(payload: peerPayload(r1), nowMs: 1_000), .decided(.verified(round: 1)))
        _ = book.arm(r2, nowMs: 2_000)
        XCTAssertEqual(book.receive(payload: peerPayload(r1), nowMs: 3_000), .duplicate)
        XCTAssertEqual(book.pendingRounds, [2])
        XCTAssertEqual(book.heldCount, 0, "a duplicate is never held")
    }

    /// A copy with a different role byte is the same MAC: still a duplicate, never a mismatch of a later round.
    func testADuplicateIsRecognisedByTheMacBytes() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1)
        _ = book.arm(r1, nowMs: 0)
        _ = book.receive(payload: peerPayload(r1), nowMs: 1)
        XCTAssertEqual(book.receive(payload: peerPayload(r1, role: 0x01), nowMs: 2), .duplicate)
    }

    // MARK: - K1-g: the held set

    func testNineMacsThatMatchNothingHoldEightAndDropTheNinth() {
        var book = KcMacRoundBook()
        for seed in 1...8 {
            XCTAssertEqual(book.receive(payload: stranger(UInt8(seed)), nowMs: 0), .held)
        }
        XCTAssertEqual(KcMacRoundBook.maxHeldMacs, 8)
        XCTAssertEqual(book.receive(payload: stranger(9), nowMs: 0), .heldDropped)
        XCTAssertEqual(book.heldCount, 8)
    }

    func testACopyOfAHeldMacIsDroppedAndKeepsItsOriginalReceiptTime() {
        var book = KcMacRoundBook()
        let r2 = pendingRound(2)
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 0), .held)
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 25_000), .heldDropped)
        XCTAssertEqual(book.heldCount, 1)
        // The original time counts: at 31 s the held MAC is stale and is not matched at arming.
        XCTAssertEqual(book.arm(r2, nowMs: 31_000).verdicts, [])
    }

    func testAHeldMacOlderThanThirtySecondsIsNotMatchedAtArming() {
        XCTAssertEqual(KcMacRoundBook.heldFreshMs, 30_000)
        var stale = KcMacRoundBook()
        let r2 = pendingRound(2)
        XCTAssertEqual(stale.receive(payload: peerPayload(r2), nowMs: 0), .held)
        XCTAssertEqual(stale.arm(r2, nowMs: 30_000).verdicts, [], "30 s old: not less than 30 s ago")
        XCTAssertEqual(stale.heldCount, 0, "dropped silently")
        XCTAssertTrue(stale.isPending(round: 2), "a held MAC never decides or extends a window by itself")

        var fresh = KcMacRoundBook()
        XCTAssertEqual(fresh.receive(payload: peerPayload(r2), nowMs: 0), .held)
        XCTAssertEqual(fresh.arm(r2, nowMs: 29_999).verdicts, [.verified(round: 2)])
    }

    func testAStaleHeldMacDoesNotTakeASlot() {
        var book = KcMacRoundBook()
        for seed in 1...8 {
            XCTAssertEqual(book.receive(payload: stranger(UInt8(seed)), nowMs: 0), .held)
        }
        XCTAssertEqual(book.receive(payload: stranger(20), nowMs: 31_000), .held, "the eight old ones are stale")
        XCTAssertEqual(book.heldCount, 1)
    }

    /// At arming the round is inserted first, then the held MACs are offered again: a held MAC of the round being
    /// armed verifies it, and one that still matches nothing stays held with its original time.
    func testArmingInsertsTheRoundBeforeOfferingTheHeldMacsAgain() {
        var book = KcMacRoundBook()
        let r2 = pendingRound(2)
        let r3 = pendingRound(3)
        XCTAssertEqual(book.receive(payload: peerPayload(r3), nowMs: 0), .held)
        XCTAssertEqual(book.receive(payload: peerPayload(r2), nowMs: 1_000), .held)
        let armed = book.arm(r2, nowMs: 2_000)
        XCTAssertEqual(armed.verdicts, [.verified(round: 2)])
        XCTAssertEqual(book.heldCount, 1, "round 3's MAC still matches nothing: held")
        XCTAssertEqual(book.arm(r3, nowMs: 3_000).verdicts, [.verified(round: 3)])
    }

    // MARK: - K1-h: the pending set is bounded

    func testASeventeenthPendingRoundIsAnOverflow() {
        var book = KcMacRoundBook()
        for number in 1...KcMacRoundBook.maxPendingRounds {
            XCTAssertFalse(book.arm(pendingRound(number), nowMs: number).overflow)
        }
        XCTAssertEqual(KcMacRoundBook.maxPendingRounds, 16)
        XCTAssertEqual(book.pendingCount, 16)
        XCTAssertTrue(book.arm(pendingRound(17), nowMs: 17).overflow)
        XCTAssertEqual(book.pendingCount, 16, "nothing changed")
        XCTAssertFalse(book.isPending(round: 17))
        // The same round armed again is a replacement, not a seventeenth round.
        XCTAssertFalse(book.arm(pendingRound(5), nowMs: 18).overflow)
        XCTAssertEqual(book.pendingCount, 16)
    }

    // MARK: - K1-i: an early MAC with no round pending

    func testAnEarlyMacWithNoRoundPendingIsHeldAndJudgedAtArming() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1, initiator: false)
        XCTAssertEqual(book.receive(payload: peerPayload(r1), nowMs: 0), .held)
        XCTAssertEqual(book.pendingCount, 0)
        XCTAssertEqual(book.arm(r1, nowMs: 14_000).verdicts, [.verified(round: 1)])
        XCTAssertEqual(book.pendingCount, 0)
    }

    // MARK: - K1-j: round 1 overlapping a rekey

    func testTheCallersRoundOneMacArrivingAfterRoundTwoWasArmedVerifiesRoundOne() {
        var book = KcMacRoundBook()
        let r1 = pendingRound(1, initiator: true)
        let r2 = pendingRound(2, initiator: false)
        _ = book.arm(r1, nowMs: 0)
        _ = book.arm(r2, nowMs: 10_000)
        XCTAssertEqual(book.receive(payload: peerPayload(r1), nowMs: 25_000), .decided(.verified(round: 1)))
        XCTAssertEqual(book.pendingRounds, [2], "round 2 is untouched")
    }

    // MARK: - Decided MACs are bounded

    func testDecidedMacsAreRememberedForTheWholeCallBoundedAt256() {
        XCTAssertEqual(KcMacRoundBook.maxDecidedMacs, 256)
        var book = KcMacRoundBook()
        var first: KcMacRoundBook.PendingRound?
        for number in 1...300 {
            let round = KcMacRoundBook.PendingRound(
                round: number, expectedPeerMac: Data(repeating: UInt8(number & 0xFF), count: 31) + Data([UInt8(number >> 8)]),
                peerRole: 0x02)
            if number == 1 { first = round }
            _ = book.arm(round, nowMs: number)
            XCTAssertEqual(book.receive(payload: peerPayload(round), nowMs: number), .decided(.verified(round: number)))
        }
        XCTAssertEqual(book.decidedCount, 256)
        // The newest decided MAC is still a duplicate; the 44 oldest were dropped, so the first one is not.
        XCTAssertEqual(book.receive(payload: peerPayload(first!), nowMs: 400), .held)
    }
}
