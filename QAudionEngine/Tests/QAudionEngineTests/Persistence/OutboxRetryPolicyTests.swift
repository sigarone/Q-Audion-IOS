import XCTest
@testable import QAudionEngine

/// W-MSGOUTBOX / W-MSGDEDUP (2026-09-01) — pins the pure decisions the 1:1
/// outbox drainer and the inbound dedup/ordering rely on, same style as
/// `RestartIceDecisionsTests` / `DatabaseOpenRecoveryPolicyTests`.
final class OutboxRetryPolicyTests: XCTestCase {

    // MARK: - Constants and kill switches

    func test_constants_matchTheDocumentedContract() {
        XCTAssertTrue(OutboxRetryPolicy.enabled)
        XCTAssertEqual(OutboxRetryPolicy.baseDelayMs, 500)
        XCTAssertEqual(OutboxRetryPolicy.maxDelayMs, 30_000)
        XCTAssertEqual(OutboxRetryPolicy.maxAttempts, 20)
        XCTAssertEqual(OutboxRetryPolicy.maxAgeMs, 24 * 60 * 60 * 1000)
        XCTAssertTrue(InboundMessagePolicy.dedupEnabled)
        XCTAssertTrue(InboundMessagePolicy.orderByServerTimestampEnabled)
    }

    // MARK: - Backoff ceiling

    func test_backoffCeiling_zeroFailures_isSendNow() {
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: 0), 0)
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: -3), 0)
    }

    func test_backoffCeiling_doublesFromBase() {
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: 1), 500)
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: 2), 1_000)
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: 3), 2_000)
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: 6), 16_000)
    }

    func test_backoffCeiling_clampsAtCap() {
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: 7), 30_000)
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: 20), 30_000)
        // Far past the exponent guard: still the cap, never an overflow.
        XCTAssertEqual(OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: 10_000), 30_000)
    }

    // MARK: - Full jitter

    func test_backoff_fullJitter_drawsOverTheWholeWindow() {
        // Injected RNG returning the lower bound → 0; upper bound → ceiling.
        let low = OutboxRetryPolicy.backoffMs(afterFailedAttempts: 3, random: { $0.lowerBound })
        let high = OutboxRetryPolicy.backoffMs(afterFailedAttempts: 3, random: { $0.upperBound })
        XCTAssertEqual(low, 0)
        XCTAssertEqual(high, 2_000)
    }

    func test_backoff_fullJitter_windowIsZeroToCeiling() {
        var seenRange: ClosedRange<Int64>?
        _ = OutboxRetryPolicy.backoffMs(afterFailedAttempts: 5, random: { range in
            seenRange = range
            return range.lowerBound
        })
        XCTAssertEqual(seenRange?.lowerBound, 0)
        XCTAssertEqual(seenRange?.upperBound, 8_000)
    }

    func test_backoff_zeroFailures_neverConsultsRng() {
        var called = false
        let delay = OutboxRetryPolicy.backoffMs(afterFailedAttempts: 0, random: { _ in
            called = true
            return 999
        })
        XCTAssertEqual(delay, 0)
        XCTAssertFalse(called)
    }

    func test_backoff_defaultRng_staysInsideWindow() {
        for attempts in 1...25 {
            let ceiling = OutboxRetryPolicy.backoffCeilingMs(afterFailedAttempts: attempts)
            for _ in 0..<50 {
                let delay = OutboxRetryPolicy.backoffMs(afterFailedAttempts: attempts)
                XCTAssertGreaterThanOrEqual(delay, 0)
                XCTAssertLessThanOrEqual(delay, ceiling)
            }
        }
    }

    func test_backoff_misbehavingRng_isClamped() {
        let tooHigh = OutboxRetryPolicy.backoffMs(afterFailedAttempts: 2, random: { _ in 1_000_000 })
        let tooLow = OutboxRetryPolicy.backoffMs(afterFailedAttempts: 2, random: { _ in -5 })
        XCTAssertEqual(tooHigh, 1_000)
        XCTAssertEqual(tooLow, 0)
    }

    // MARK: - Per-row action

    func test_rowAction_freshEntry_attemptsNow() {
        let action = OutboxRetryPolicy.rowAction(
            attempts: 0, createdAtMs: 1_000, nextAttemptAtMs: 0, nowMs: 1_000)
        XCTAssertEqual(action, .attemptNow)
    }

    func test_rowAction_backoffStillRunning_waits() {
        let action = OutboxRetryPolicy.rowAction(
            attempts: 2, createdAtMs: 1_000, nextAttemptAtMs: 5_000, nowMs: 4_999)
        XCTAssertEqual(action, .wait(untilMs: 5_000))
    }

    func test_rowAction_backoffElapsed_attemptsNow() {
        let action = OutboxRetryPolicy.rowAction(
            attempts: 2, createdAtMs: 1_000, nextAttemptAtMs: 5_000, nowMs: 5_000)
        XCTAssertEqual(action, .attemptNow)
    }

    func test_rowAction_attemptCap_isInclusive() {
        let atCap = OutboxRetryPolicy.rowAction(
            attempts: OutboxRetryPolicy.maxAttempts, createdAtMs: 1_000, nextAttemptAtMs: 0, nowMs: 2_000)
        let oneBelow = OutboxRetryPolicy.rowAction(
            attempts: OutboxRetryPolicy.maxAttempts - 1, createdAtMs: 1_000, nextAttemptAtMs: 0, nowMs: 2_000)
        XCTAssertEqual(atCap, .giveUpAttempts)
        XCTAssertEqual(oneBelow, .attemptNow)
    }

    func test_rowAction_ageCap_isInclusive_andWinsOverAttempts() {
        let created: Int64 = 1_000
        let atAge = OutboxRetryPolicy.rowAction(
            attempts: OutboxRetryPolicy.maxAttempts, createdAtMs: created,
            nextAttemptAtMs: 0, nowMs: created + OutboxRetryPolicy.maxAgeMs)
        let justUnder = OutboxRetryPolicy.rowAction(
            attempts: 0, createdAtMs: created,
            nextAttemptAtMs: 0, nowMs: created + OutboxRetryPolicy.maxAgeMs - 1)
        XCTAssertEqual(atAge, .giveUpAge)
        XCTAssertEqual(justUnder, .attemptNow)
    }

    func test_rowAction_ageCap_beatsPendingBackoff() {
        let created: Int64 = 0
        let action = OutboxRetryPolicy.rowAction(
            attempts: 3, createdAtMs: created,
            nextAttemptAtMs: OutboxRetryPolicy.maxAgeMs + 60_000,
            nowMs: OutboxRetryPolicy.maxAgeMs)
        XCTAssertEqual(action, .giveUpAge)
    }

    // MARK: - What gets queued

    func test_shouldQueue_onlyTransportFailures() {
        XCTAssertTrue(OutboxRetryPolicy.shouldQueue(isTransportFailure: true))
        XCTAssertFalse(OutboxRetryPolicy.shouldQueue(isTransportFailure: false))
    }

    // MARK: - Inbound ordering

    func test_effectiveSentAt_prefersServerTimestamp() {
        let server = Date(timeIntervalSince1970: 1_700_000_000)
        let arrival = Date(timeIntervalSince1970: 1_700_000_500)
        XCTAssertEqual(InboundMessagePolicy.effectiveSentAt(serverTimestamp: server, arrival: arrival), server)
    }

    func test_effectiveSentAt_fallsBackToArrival_whenWireHasNoTimestamp() {
        let arrival = Date(timeIntervalSince1970: 1_700_000_500)
        XCTAssertEqual(InboundMessagePolicy.effectiveSentAt(serverTimestamp: nil, arrival: arrival), arrival)
    }
}
