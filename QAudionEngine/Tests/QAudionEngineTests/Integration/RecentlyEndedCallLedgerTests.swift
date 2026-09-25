import XCTest
@testable import QAudionEngine

/// W-GHOSTCALL (2026-09-25) — pins the memory the cancel-push handler and the
/// answer path use to refuse a call that has already ended (incident e3acecd7).
/// The clock is injected through `now:`, so no test sleeps. Same style as
/// `CallKitCallLedgerTests`.
final class RecentlyEndedCallLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Defaults

    func test_defaults_areTwoMinutesAndSixteenEntries() {
        XCTAssertEqual(RecentlyEndedCallLedger.defaultTtl, 120)
        XCTAssertEqual(RecentlyEndedCallLedger.defaultCapacity, 16)
        let ledger = RecentlyEndedCallLedger()
        XCTAssertEqual(ledger.ttl, 120)
        XCTAssertEqual(ledger.capacity, 16)
    }

    // MARK: - Membership

    func test_unknownUuid_isNotRecentlyEnded() {
        let ledger = RecentlyEndedCallLedger()
        XCTAssertFalse(ledger.wasRecentlyEnded(UUID(), now: t0))
    }

    func test_recordedUuid_isRecentlyEnded_thenOthersAreNot() {
        var ledger = RecentlyEndedCallLedger()
        let ended = UUID()
        ledger.recordEnded(ended, now: t0)
        XCTAssertTrue(ledger.wasRecentlyEnded(ended, now: t0))
        XCTAssertTrue(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(0.6)),
                      "the incident gap (hangup -> re-report) was 0.6 s")
        XCTAssertFalse(ledger.wasRecentlyEnded(UUID(), now: t0))
    }

    // MARK: - TTL (injected clock)

    func test_entryExpires_atExactlyTtl_andNotBefore() {
        var ledger = RecentlyEndedCallLedger(ttl: 120)
        let ended = UUID()
        ledger.recordEnded(ended, now: t0)
        XCTAssertTrue(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(119.999)))
        XCTAssertFalse(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(120)),
                       "the window is half-open: age == ttl is expired")
        XCTAssertFalse(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(3_600)))
    }

    func test_customTtl_isHonoured() {
        var ledger = RecentlyEndedCallLedger(ttl: 10)
        let ended = UUID()
        ledger.recordEnded(ended, now: t0)
        XCTAssertTrue(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(9)))
        XCTAssertFalse(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(10)))
    }

    func test_recordingAgain_refreshesTheTimestamp() {
        var ledger = RecentlyEndedCallLedger(ttl: 120)
        let ended = UUID()
        ledger.recordEnded(ended, now: t0)
        // endCall and handleRemoteCallHangup can both record the same call.
        ledger.recordEnded(ended, now: t0.addingTimeInterval(100))
        XCTAssertEqual(ledger.count, 1)
        XCTAssertTrue(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(200)),
                      "100 s after the SECOND record, not 200 s after the first")
        XCTAssertFalse(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(220)))
    }

    /// A wall clock stepped backwards must keep the entry, never lose it: the
    /// safe direction is "treat it as recent" (a placeholder report), not
    /// "treat a dead call as alive".
    func test_clockStepBackwards_keepsTheEntryRecent() {
        var ledger = RecentlyEndedCallLedger(ttl: 120)
        let ended = UUID()
        ledger.recordEnded(ended, now: t0)
        XCTAssertTrue(ledger.wasRecentlyEnded(ended, now: t0.addingTimeInterval(-30)))
    }

    // MARK: - Pruning

    func test_prune_dropsExpiredAndKeepsFresh() {
        var ledger = RecentlyEndedCallLedger(ttl: 120)
        let old = UUID()
        let fresh = UUID()
        ledger.recordEnded(old, now: t0)
        ledger.recordEnded(fresh, now: t0.addingTimeInterval(100))
        XCTAssertEqual(ledger.count, 2)
        ledger.prune(now: t0.addingTimeInterval(130))
        XCTAssertEqual(ledger.count, 1)
        XCTAssertFalse(ledger.wasRecentlyEnded(old, now: t0.addingTimeInterval(130)))
        XCTAssertTrue(ledger.wasRecentlyEnded(fresh, now: t0.addingTimeInterval(130)))
    }

    func test_recordEnded_prunesExpiredEntriesAsAWhole() {
        var ledger = RecentlyEndedCallLedger(ttl: 120)
        ledger.recordEnded(UUID(), now: t0)
        ledger.recordEnded(UUID(), now: t0.addingTimeInterval(1))
        ledger.recordEnded(UUID(), now: t0.addingTimeInterval(1_000))
        XCTAssertEqual(ledger.count, 1, "the two expired entries went when the third was recorded")
    }

    // MARK: - Capacity

    func test_capacity_evictsTheOldestEntry() {
        var ledger = RecentlyEndedCallLedger(ttl: 120, capacity: 3)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        ledger.recordEnded(a, now: t0)
        ledger.recordEnded(b, now: t0.addingTimeInterval(1))
        ledger.recordEnded(c, now: t0.addingTimeInterval(2))
        ledger.recordEnded(d, now: t0.addingTimeInterval(3))
        let now = t0.addingTimeInterval(4)
        XCTAssertEqual(ledger.count, 3)
        XCTAssertFalse(ledger.wasRecentlyEnded(a, now: now), "the oldest is the one evicted")
        XCTAssertTrue(ledger.wasRecentlyEnded(b, now: now))
        XCTAssertTrue(ledger.wasRecentlyEnded(c, now: now))
        XCTAssertTrue(ledger.wasRecentlyEnded(d, now: now))
    }

    func test_capacity_belowOneIsClampedToOne() {
        var ledger = RecentlyEndedCallLedger(ttl: 120, capacity: 0)
        XCTAssertEqual(ledger.capacity, 1)
        let a = UUID(), b = UUID()
        ledger.recordEnded(a, now: t0)
        ledger.recordEnded(b, now: t0.addingTimeInterval(1))
        XCTAssertEqual(ledger.count, 1)
        XCTAssertTrue(ledger.wasRecentlyEnded(b, now: t0.addingTimeInterval(2)))
    }

    // MARK: - Value semantics

    /// The placeholder ledger and the ended ledger are two separate instances
    /// of this type; copying one must never alias the other.
    func test_copies_areIndependent() {
        var original = RecentlyEndedCallLedger()
        let a = UUID()
        original.recordEnded(a, now: t0)
        var copy = original
        let b = UUID()
        copy.recordEnded(b, now: t0)
        XCTAssertTrue(copy.wasRecentlyEnded(a, now: t0))
        XCTAssertFalse(original.wasRecentlyEnded(b, now: t0))
    }
}
