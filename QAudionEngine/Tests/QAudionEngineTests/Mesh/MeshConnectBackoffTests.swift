import XCTest
@testable import QAudionEngine

/// docs/mesh/MESH_LINK_SPEC.md section 3.5: after a failed outgoing attempt the same advertiser is left alone for
/// 15 s, doubling with every further consecutive failure up to 300 s, each value randomised by plus or minus 20 %;
/// an ANNOUNCE clears it; at most 64 identifiers are kept, the oldest dropped first; the table is emptied when the
/// antenna goes off.
final class MeshConnectBackoffTests: XCTestCase {

    private func table(jitter: Int = 0) -> MeshConnectBackoff {
        MeshConnectBackoff(jitter: { jitter })
    }

    // MARK: - Constants

    func testConstantsFollowTheSpecification() {
        XCTAssertEqual(MeshConnectBackoff.firstMs, 15_000)
        XCTAssertEqual(MeshConnectBackoff.maxMs, 300_000)
        XCTAssertEqual(MeshConnectBackoff.jitterRangePermille, 200)
        XCTAssertEqual(MeshConnectBackoff.capacity, 64)
    }

    // MARK: - The wait

    func testTheBaseDoublesFromFifteenSecondsUpToThreeHundred() {
        let bases = (1...9).map { MeshConnectBackoff.baseMs(afterFailures: $0) }
        XCTAssertEqual(bases, [15_000, 30_000, 60_000, 120_000, 240_000, 300_000, 300_000, 300_000, 300_000])
        // Absurd counts neither overflow nor leave the cap.
        XCTAssertEqual(MeshConnectBackoff.baseMs(afterFailures: 1_000_000), 300_000)
        // Zero or negative is treated as the first.
        XCTAssertEqual(MeshConnectBackoff.baseMs(afterFailures: 0), 15_000)
    }

    func testTheFirstFailureSetsFifteenSecondsAndCountsUp() {
        var t = table()
        let first = t.recordFailure("a", nowMs: 1_000)
        XCTAssertEqual(first, MeshConnectBackoff.Failure(failures: 1, waitMs: 15_000))
        XCTAssertEqual(t.failures("a"), 1)
        XCTAssertTrue(t.isBackedOff("a", nowMs: 1_000))
        XCTAssertEqual(t.remainingMs("a", nowMs: 1_000), 15_000)
    }

    func testConsecutiveFailuresDoubleUpToTheCap() {
        var t = table()
        var now: Int64 = 0
        var waits: [Int64] = []
        for _ in 1...8 {
            let f = t.recordFailure("a", nowMs: now)
            waits.append(f.waitMs)
            now += f.waitMs     // the next attempt happens as soon as the backoff expired
        }
        XCTAssertEqual(waits, [15_000, 30_000, 60_000, 120_000, 240_000, 300_000, 300_000, 300_000])
        XCTAssertEqual(t.failures("a"), 8)
    }

    func testTheRandomisationIsPlusOrMinusTwentyPercentOfEveryValue() {
        for (jitter, first, capped) in [(-200, Int64(12_000), Int64(240_000)),
                                        (0, Int64(15_000), Int64(300_000)),
                                        (200, Int64(18_000), Int64(360_000)),
                                        (100, Int64(16_500), Int64(330_000))] {
            var t = table(jitter: jitter)
            XCTAssertEqual(t.recordFailure("a", nowMs: 0).waitMs, first, "first, jitter \(jitter)")
            for _ in 2...5 { _ = t.recordFailure("a", nowMs: 0) }
            XCTAssertEqual(t.recordFailure("a", nowMs: 0).waitMs, capped, "sixth, jitter \(jitter)")
        }
    }

    func testAnOutOfRangeDrawIsClampedIntoTheRange() {
        var low = table(jitter: -900)
        XCTAssertEqual(low.recordFailure("a", nowMs: 0).waitMs, 12_000)
        var high = table(jitter: 900)
        XCTAssertEqual(high.recordFailure("a", nowMs: 0).waitMs, 18_000)
    }

    func testTheDefaultDrawStaysInsideTheRangeAndActuallyVaries() {
        var seenFirst: Set<Int64> = []
        for _ in 0..<300 {
            var t = MeshConnectBackoff()
            let first = t.recordFailure("a", nowMs: 0).waitMs
            XCTAssertTrue((12_000...18_000).contains(first), "first wait \(first)")
            seenFirst.insert(first)
            for _ in 2...6 { _ = t.recordFailure("a", nowMs: 0) }
            let capped = t.recordFailure("a", nowMs: 0).waitMs
            XCTAssertTrue((240_000...360_000).contains(capped), "capped wait \(capped)")
        }
        XCTAssertGreaterThan(seenFirst.count, 20, "the wait is randomised")
    }

    // MARK: - What counts as a failed attempt

    func testAnOutgoingLinkThatDiesBeforeItsFirstAnnounceIsAFailedAttempt() {
        // A connect timeout, a discovery or subscribe timeout (timeout), a refusal or a drop by the other side (remote),
        // before the first ANNOUNCE.
        for reason in ["timeout", "remote"] {
            XCTAssertTrue(MeshConnectBackoff.isFailedAttempt(outgoing: true, announceReceived: false, reason: reason), reason)
        }
    }

    func testALinkThatAnnouncedItselfIsNotAFailedAttempt() {
        for reason in ["timeout", "remote"] {
            XCTAssertFalse(MeshConnectBackoff.isFailedAttempt(outgoing: true, announceReceived: true, reason: reason), reason)
        }
    }

    func testAnIncomingLinkIsNeverAFailedAttempt() {
        for reason in ["timeout", "remote", "evicted"] {
            XCTAssertFalse(MeshConnectBackoff.isFailedAttempt(outgoing: false, announceReceived: false, reason: reason), reason)
        }
    }

    func testALinkClosedOnPurposeIsNotAFailedAttempt() {
        // The antenna stopped or a pause gave up the attempt; the malformed-input block.
        for reason in ["stop", "blocked"] {
            XCTAssertFalse(MeshConnectBackoff.isFailedAttempt(outgoing: true, announceReceived: false, reason: reason), reason)
        }
    }

    func testOnlyTheListedReasonsCountAsAFailedAttempt() {
        // A positive list: timeout and remote, nothing else, so a reason that appears later (or an eviction) is no failure.
        XCTAssertEqual(MeshConnectBackoff.failureReasons, ["timeout", "remote"])
        for reason in ["evicted", "decode", "ann_decrypt", "ann_parse", "other", ""] {
            XCTAssertFalse(MeshConnectBackoff.isFailedAttempt(outgoing: true, announceReceived: false, reason: reason), reason)
        }
    }

    // MARK: - Expiry, identifiers, clearing

    func testTheBackoffExpiresButTheHistoryStaysSoTheNextFailureDoubles() {
        var t = table()
        _ = t.recordFailure("a", nowMs: 0)
        XCTAssertTrue(t.isBackedOff("a", nowMs: 14_999))
        XCTAssertEqual(t.remainingMs("a", nowMs: 14_999), 1)
        XCTAssertFalse(t.isBackedOff("a", nowMs: 15_000))
        XCTAssertEqual(t.remainingMs("a", nowMs: 99_000), 0)
        let second = t.recordFailure("a", nowMs: 15_000)
        XCTAssertEqual(second, MeshConnectBackoff.Failure(failures: 2, waitMs: 30_000))
    }

    func testADifferentIdentifierIsADifferentAdvertiser() {
        var t = table()
        _ = t.recordFailure("a", nowMs: 0)
        XCTAssertFalse(t.isBackedOff("b", nowMs: 0))
        XCTAssertEqual(t.failures("b"), 0)
        XCTAssertEqual(t.recordFailure("b", nowMs: 0), MeshConnectBackoff.Failure(failures: 1, waitMs: 15_000))
        XCTAssertEqual(t.count, 2)
    }

    func testAnAnnounceClearsTheEntryOfThatIdentifierOnly() {
        var t = table()
        _ = t.recordFailure("a", nowMs: 0)
        _ = t.recordFailure("a", nowMs: 20_000)
        _ = t.recordFailure("b", nowMs: 0)
        t.clear("a")
        XCTAssertFalse(t.isBackedOff("a", nowMs: 20_000))
        XCTAssertEqual(t.failures("a"), 0)
        XCTAssertTrue(t.isBackedOff("b", nowMs: 1))
        // The history is over: the next failure is a first one again.
        XCTAssertEqual(t.recordFailure("a", nowMs: 30_000), MeshConnectBackoff.Failure(failures: 1, waitMs: 15_000))
        // Clearing an identifier that is not there does nothing.
        t.clear("zzz")
        XCTAssertEqual(t.count, 2)
    }

    func testTurningTheAntennaOffEmptiesTheTable() {
        var t = table()
        for i in 0..<10 { _ = t.recordFailure("k\(i)", nowMs: 0) }
        XCTAssertEqual(t.count, 10)
        t.removeAll()
        XCTAssertEqual(t.count, 0)
        XCTAssertFalse(t.isBackedOff("k0", nowMs: 0))
        XCTAssertEqual(t.recordFailure("k0", nowMs: 0).failures, 1)
    }

    // MARK: - 64 identifiers

    func testAtMostSixtyFourIdentifiersTheOldestDroppedFirst() {
        var t = table()
        for i in 0..<64 { _ = t.recordFailure("k\(i)", nowMs: Int64(i)) }
        XCTAssertEqual(t.count, 64)
        // A 65th identifier pushes the oldest (k0) out and nothing else.
        _ = t.recordFailure("new", nowMs: 100)
        XCTAssertEqual(t.count, 64)
        XCTAssertEqual(t.failures("k0"), 0)
        XCTAssertFalse(t.isBackedOff("k0", nowMs: 100))
        XCTAssertEqual(t.failures("k1"), 1)
        XCTAssertEqual(t.failures("new"), 1)
        // The next one takes k1.
        _ = t.recordFailure("newer", nowMs: 101)
        XCTAssertEqual(t.count, 64)
        XCTAssertEqual(t.failures("k1"), 0)
        XCTAssertEqual(t.failures("k2"), 1)
    }

    func testAFreshFailureMakesAnEntryNewerAndAnExistingOneNeverEvictsAnother() {
        var t = table()
        for i in 0..<64 { _ = t.recordFailure("k\(i)", nowMs: 0) }
        // Another failure of an identifier already in the table: no room is needed, nobody leaves.
        _ = t.recordFailure("k0", nowMs: 20_000)
        XCTAssertEqual(t.count, 64)
        XCTAssertEqual(t.failures("k0"), 2)
        XCTAssertEqual(t.failures("k1"), 1)
        // k0 is now the newest, so the oldest to go is k1.
        _ = t.recordFailure("new", nowMs: 20_001)
        XCTAssertEqual(t.failures("k0"), 2)
        XCTAssertEqual(t.failures("k1"), 0)
        XCTAssertEqual(t.count, 64)
    }
}
