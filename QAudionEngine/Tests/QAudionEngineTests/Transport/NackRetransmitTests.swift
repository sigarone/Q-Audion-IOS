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

    // MARK: - W-REKEYSEQGATE (re-key: the peer's counter restarts at 0 with the new key)

    func test_wouldAccept_isReadOnly_andAgreesWithAccept() {
        let tracker = NackRxTracker()
        XCTAssertTrue(tracker.wouldAccept(3))
        XCTAssertTrue(tracker.wouldAccept(3), "a read-only check must not consume the seq")
        XCTAssertTrue(tracker.accept(3, nowMs: 0))
        XCTAssertFalse(tracker.wouldAccept(3))
        XCTAssertFalse(tracker.accept(3, nowMs: 1))
    }

    func test_recordingFramesThatNeverOpened_poisonsTheTracker_whichIsWhyOnlyOpenedFramesAreCommitted() {
        let tracker = NackRxTracker()
        for seq in 0...5000 { XCTAssertTrue(tracker.accept(Int64(seq), nowMs: 0)) }
        tracker.reset() // key install (resetNackState)
        // old-key frames still in flight: they cannot be opened. Recording them (the pre-fix
        // behaviour) raises highestSeq ...
        for seq in 5001...5040 { XCTAssertTrue(tracker.accept(Int64(seq), nowMs: 0)) }
        // ... and the peer's restarted counter is then dropped as "too old".
        for seq in 0...20 { XCTAssertFalse(tracker.wouldAccept(Int64(seq)), "seq \(seq)") }
    }

    func test_onlyOpenedFramesCommitted_restartedCounterIsFollowed() {
        let tracker = NackRxTracker()
        for seq in 0...5000 { _ = tracker.accept(Int64(seq), nowMs: 0) }
        tracker.reset() // key install (resetNackState)
        // old-key frames still in flight: checked read-only, never opened, never committed
        for seq in 5001...5040 { XCTAssertTrue(tracker.wouldAccept(Int64(seq))) }
        // the peer switches: its counter restarts at 0 and every frame opens
        for seq in 0...200 {
            XCTAssertTrue(tracker.wouldAccept(Int64(seq)), "seq \(seq)")
            XCTAssertTrue(tracker.accept(Int64(seq), nowMs: Int64(seq) * 20), "seq \(seq)")
        }
        // duplicates inside the new epoch are still dropped
        XCTAssertFalse(tracker.wouldAccept(200))
    }

    // MARK: - W-NACKEPOCH (the reset must not depend on Task vs main-queue ordering)

    func test_newEpochSeqZero_isAccepted_beforeAnyExplicitReset() {
        let tracker = NackRxTracker()
        XCTAssertFalse(tracker.adoptKeyEpoch(0), "epoch 0 is the initial state")
        for seq in 0...5000 { _ = tracker.accept(Int64(seq), nowMs: 0) }
        // The race: the new key is live, the explicit reset() has NOT run yet.
        XCTAssertFalse(tracker.wouldAccept(0), "without the epoch, seq 0 is judged against the old highestSeq")
        // Key install bumped the epoch synchronously; the RX path adopts it before its check.
        XCTAssertTrue(tracker.adoptKeyEpoch(1))
        XCTAssertTrue(tracker.wouldAccept(0))
        XCTAssertTrue(tracker.accept(0, nowMs: 1))
        XCTAssertFalse(tracker.wouldAccept(0), "duplicates inside the new epoch are still dropped")
    }

    func test_adoptKeyEpoch_sameEpoch_keepsState() {
        let tracker = NackRxTracker()
        XCTAssertTrue(tracker.adoptKeyEpoch(1))
        XCTAssertTrue(tracker.accept(7, nowMs: 0))
        XCTAssertFalse(tracker.adoptKeyEpoch(1))
        XCTAssertFalse(tracker.wouldAccept(7), "an unchanged epoch must not wipe duplicate memory")
    }

    func test_lateExplicitReset_afterEpochAdopted_neverRejectsNewEpochFrames() {
        let tracker = NackRxTracker()
        for seq in 0...5000 { _ = tracker.accept(Int64(seq), nowMs: 0) }
        XCTAssertTrue(tracker.adoptKeyEpoch(1))
        for seq in 0...10 { XCTAssertTrue(tracker.accept(Int64(seq), nowMs: Int64(seq) * 20)) }
        tracker.reset() // the main-actor resetNackState() Task landing late
        XCTAssertFalse(tracker.adoptKeyEpoch(1), "reset() keeps the epoch: no second reset")
        for seq in 11...40 { XCTAssertTrue(tracker.wouldAccept(Int64(seq)), "seq \(seq)") }
    }

    /// Copilot review of #127 — a late, unguarded `reset()` call does not just
    /// stop rejecting UNSEEN new-epoch sequences (covered above): it also wipes
    /// the dedup memory of sequences already accepted under that same epoch, so
    /// a retransmission of one of them would incorrectly pass `wouldAccept` a
    /// second time. `reset()` itself has no way to avoid this — it unconditionally
    /// forgets everything, by design, for the "different epoch" case. The fix is
    /// at the call site: `CallService.resetNackState()` no longer calls
    /// `nackRxTracker.reset()` at all (only `adoptKeyEpoch` may reset the RX
    /// state now), which this test documents by showing what would break if a
    /// caller reintroduced a raw `reset()` call after frames were already
    /// accepted in the current epoch.
    func test_lateExplicitReset_afterEpochAdopted_alsoForgetsAlreadyAcceptedSequences_thisIsWhyCallersMustNotCallResetDirectly() {
        let tracker = NackRxTracker()
        XCTAssertTrue(tracker.adoptKeyEpoch(1))
        XCTAssertTrue(tracker.accept(0, nowMs: 0))
        XCTAssertFalse(tracker.wouldAccept(0), "seq 0 was just accepted: a duplicate must be rejected")
        tracker.reset() // the main-actor resetNackState() Task landing late, AFTER seq 0 was accepted
        XCTAssertTrue(
            tracker.wouldAccept(0),
            "reset() wipes duplicate memory without bumping the epoch: a retransmission of an " +
            "already-played sequence would now be treated as new and could be decoded/played twice")
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
