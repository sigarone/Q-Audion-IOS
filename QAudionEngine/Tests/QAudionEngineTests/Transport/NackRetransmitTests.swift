import XCTest
@testable import QAudionEngine

/// Port of Android's `NackRetransmitTest.kt` — same discipline as this
/// directory's other pure-logic test files: no I/O, no real clock, every
/// branch pinned by an exact assertion.
final class NackRetransmitTests: XCTestCase {

    private func envelope(_ byte: UInt8, count: Int = 8) -> Data {
        Data(repeating: byte, count: count)
    }

    // MARK: - NackRetransmitRing

    func test_recordedFrame_isReturnedByLookup() {
        let ring = NackRetransmitRing(capacity: 4)
        ring.record(seq: 10, envelope: envelope(0xAA))
        XCTAssertEqual(envelope(0xAA), ring.lookup(seq: 10))
    }

    func test_lookup_forSeqNeverRecorded_returnsNil() {
        let ring = NackRetransmitRing(capacity: 4)
        ring.record(seq: 1, envelope: envelope(0x01))
        XCTAssertNil(ring.lookup(seq: 99))
    }

    func test_eviction_seqPushedOutByWraparound_isNoLongerFound() {
        let ring = NackRetransmitRing(capacity: 4)
        ring.record(seq: 0, envelope: envelope(0))
        ring.record(seq: 1, envelope: envelope(1))
        ring.record(seq: 2, envelope: envelope(2))
        ring.record(seq: 3, envelope: envelope(3))
        // seq=4 lands in the same slot as seq=0 (4 % 4 == 0), evicting it.
        ring.record(seq: 4, envelope: envelope(4))
        XCTAssertNil(ring.lookup(seq: 0), "evicted seq must not be returned")
        XCTAssertEqual(envelope(4), ring.lookup(seq: 4))
        XCTAssertEqual(envelope(1), ring.lookup(seq: 1))
    }

    func test_clear_removesEveryEntry() {
        let ring = NackRetransmitRing(capacity: 4)
        ring.record(seq: 0, envelope: envelope(0x11))
        ring.record(seq: 1, envelope: envelope(0x22))
        ring.clear()
        XCTAssertNil(ring.lookup(seq: 0))
        XCTAssertNil(ring.lookup(seq: 1))
    }

    // MARK: - NackRxTracker

    func test_accept_returnsTrue_forFirstDeliveryOfEachInOrderSeq() {
        let tracker = NackRxTracker()
        XCTAssertTrue(tracker.accept(0, nowMs: 0))
        XCTAssertTrue(tracker.accept(1, nowMs: 60))
        XCTAssertTrue(tracker.accept(2, nowMs: 120))
    }

    func test_accept_returnsFalse_forExactDuplicate() {
        let tracker = NackRxTracker()
        XCTAssertTrue(tracker.accept(5, nowMs: 0))
        XCTAssertFalse(tracker.accept(5, nowMs: 10))
    }

    func test_gap_notNackEligible_beforeAgingPastThreshold() {
        let tracker = NackRxTracker(nackAgeThresholdMs: 120)
        _ = tracker.accept(0, nowMs: 0)
        _ = tracker.accept(2, nowMs: 60) // seq=1 now pending, noticed at t=60
        XCTAssertTrue(tracker.gapsReadyToNack(nowMs: 100).isEmpty)
    }

    func test_gap_becomesNackEligible_exactlyOnceItAgesPastThreshold() {
        let tracker = NackRxTracker(nackAgeThresholdMs: 120)
        _ = tracker.accept(0, nowMs: 0)
        _ = tracker.accept(2, nowMs: 60)
        XCTAssertEqual([1], tracker.gapsReadyToNack(nowMs: 60 + 120))
    }

    func test_gap_alreadyOffered_isNeverOfferedTwice() {
        let tracker = NackRxTracker(nackAgeThresholdMs: 100)
        _ = tracker.accept(0, nowMs: 0)
        _ = tracker.accept(2, nowMs: 0)
        XCTAssertEqual([1], tracker.gapsReadyToNack(nowMs: 200))
        XCTAssertTrue(
            tracker.gapsReadyToNack(nowMs: 500).isEmpty,
            "the same gap must not be requested twice")
    }

    func test_lateArrivalOfMissingFrame_clearsItsOwnPendingGap() {
        let tracker = NackRxTracker(nackAgeThresholdMs: 100)
        _ = tracker.accept(0, nowMs: 0)
        _ = tracker.accept(2, nowMs: 0) // seq=1 now pending
        XCTAssertTrue(tracker.accept(1, nowMs: 50)) // arrives late, in order — deliverable
        XCTAssertTrue(
            tracker.gapsReadyToNack(nowMs: 500).isEmpty,
            "a gap that already arrived must not still be offered for NACK")
    }

    func test_hugeForwardJump_opensNoGaps() {
        let tracker = NackRxTracker(lookbackWindow: 4, nackAgeThresholdMs: 10)
        _ = tracker.accept(0, nowMs: 0)
        _ = tracker.accept(1, nowMs: 0)
        // The jump (10 - 1 = 9) exceeds lookbackWindow(4), so no gaps are
        // even opened for it — verifies the "huge forward jump allocates
        // nothing" guard instead of an unbounded gap list.
        _ = tracker.accept(10, nowMs: 0)
        XCTAssertTrue(tracker.gapsReadyToNack(nowMs: 1000).isEmpty)
    }

    func test_tooOldSeq_farBehindHighestSeq_isRejectedWithoutDisturbingState() {
        let tracker = NackRxTracker(lookbackWindow: 8)
        _ = tracker.accept(100, nowMs: 0)
        XCTAssertFalse(tracker.accept(1, nowMs: 0)) // 100 - 1 >= 8: too old
    }

    func test_reset_clearsHighestSeqPendingGapsAndDuplicateMemory() {
        let tracker = NackRxTracker(nackAgeThresholdMs: 0)
        _ = tracker.accept(0, nowMs: 0)
        _ = tracker.accept(2, nowMs: 0)
        tracker.reset()
        XCTAssertTrue(tracker.accept(0, nowMs: 1000), "fresh state: seq=0 is a legitimate first delivery again")
        XCTAssertTrue(tracker.gapsReadyToNack(nowMs: 1000).isEmpty)
    }

    // MARK: - NackResendRateLimiter

    func test_allowsUpToConfiguredLimit_withinOneWindow() {
        let limiter = NackResendRateLimiter(maxPerWindow: 3, windowMs: 1000)
        XCTAssertTrue(limiter.tryAcquire(nowMs: 0))
        XCTAssertTrue(limiter.tryAcquire(nowMs: 10))
        XCTAssertTrue(limiter.tryAcquire(nowMs: 20))
        XCTAssertFalse(limiter.tryAcquire(nowMs: 30), "a 4th resend within the same window must be denied")
    }

    func test_allowsAgain_onceWindowHasSlidPastEarlierGrants() {
        let limiter = NackResendRateLimiter(maxPerWindow: 1, windowMs: 1000)
        XCTAssertTrue(limiter.tryAcquire(nowMs: 0))
        XCTAssertFalse(limiter.tryAcquire(nowMs: 500))
        XCTAssertTrue(limiter.tryAcquire(nowMs: 1000), "the window has fully elapsed since t=0")
    }
}
