import XCTest
@testable import QAudionEngine

/// W-RETRYAFTER (2026-10-03) — how a background uploader reacts to a failed request:
/// which statuses keep the payload, how `Retry-After` is read, how long the uploader
/// stays quiet, and that a kept batch really comes back after the pause.
///
/// Every test drives an injected monotonic clock (`now`), an injected wall clock and an
/// injected jitter draw: nothing sleeps and nothing is random.
final class UploadRetryPolicyTests: XCTestCase {

    private let wall = Date(timeIntervalSince1970: 784_111_747)

    // MARK: - Verdict

    func test_2xxIsSuccess() {
        XCTAssertEqual(UploadRetryPolicy.verdict(status: 200), .success)
        XCTAssertEqual(UploadRetryPolicy.verdict(status: 204), .success)
        XCTAssertEqual(UploadRetryPolicy.verdict(status: 299), .success)
    }

    /// The exact failure of 2026-10-03: a 429 was read as "the batch itself is rejected".
    func test_429And503KeepThePayload() {
        XCTAssertEqual(UploadRetryPolicy.verdict(status: 429), .keep)
        XCTAssertEqual(UploadRetryPolicy.verdict(status: 503), .keep)
    }

    func test_everyServerErrorAndNetworkFailureKeepsThePayload() {
        for code in [500, 501, 502, 504, 599] {
            XCTAssertEqual(UploadRetryPolicy.verdict(status: code), .keep, "HTTP \(code)")
        }
        XCTAssertEqual(UploadRetryPolicy.verdict(status: nil), .keep)
        XCTAssertEqual(UploadRetryPolicy.verdict(status: 0), .keep)
    }

    func test_stateDependentClientErrorsKeepThePayload() {
        for code in [401, 402, 403, 404, 408, 425] {
            XCTAssertEqual(UploadRetryPolicy.verdict(status: code), .keep, "HTTP \(code)")
        }
    }

    func test_onlyPayloadSpecificRejectionsDrop() {
        for code in [400, 413, 415, 422] {
            XCTAssertEqual(UploadRetryPolicy.verdict(status: code), .reject, "HTTP \(code)")
        }
    }

    func test_throttleIs429And503Only() {
        XCTAssertTrue(UploadRetryPolicy.isThrottle(status: 429))
        XCTAssertTrue(UploadRetryPolicy.isThrottle(status: 503))
        XCTAssertFalse(UploadRetryPolicy.isThrottle(status: 500))
        XCTAssertFalse(UploadRetryPolicy.isThrottle(status: nil))
    }

    // MARK: - Retry-After parsing

    func test_parseReadsDelaySeconds() {
        XCTAssertEqual(UploadRetryPolicy.parseRetryAfter("60", now: wall) ?? -1, 60, accuracy: 0.0001)
        XCTAssertEqual(UploadRetryPolicy.parseRetryAfter(" 7 ", now: wall) ?? -1, 7, accuracy: 0.0001)
    }

    func test_parseReadsAnHttpDate() {
        // 1994-11-06T08:49:37Z is epoch 784111777: 30 s after `wall`.
        let seconds = UploadRetryPolicy.parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now: wall)
        XCTAssertEqual(seconds ?? -1, 30, accuracy: 0.001)
    }

    func test_parseTurnsAPastDateIntoZero() {
        let later = Date(timeIntervalSince1970: 784_111_900)
        let seconds = UploadRetryPolicy.parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now: later)
        XCTAssertEqual(seconds ?? -1, 0, accuracy: 0.001)
    }

    func test_parseReturnsNilForMissingOrUnusableValues() {
        XCTAssertNil(UploadRetryPolicy.parseRetryAfter(nil, now: wall))
        XCTAssertNil(UploadRetryPolicy.parseRetryAfter("", now: wall))
        XCTAssertNil(UploadRetryPolicy.parseRetryAfter("soon", now: wall))
        XCTAssertNil(UploadRetryPolicy.parseRetryAfter("-5", now: wall))
        XCTAssertNil(UploadRetryPolicy.parseRetryAfter("inf", now: wall))
        XCTAssertNil(UploadRetryPolicy.parseRetryAfter("nan", now: wall))
    }

    // MARK: - Delay

    func test_aHeaderIsHonouredAndFloorAndCapApply() {
        let exact = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "60", now: wall,
                                            consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(exact, 60, accuracy: 0.0001)

        let raised = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "0", now: wall,
                                             consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(raised, 1, accuracy: 0.0001, "floor is 1 s")
    }

    func test_aHugeHeaderIsLoweredToTheCap() {
        let huge = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "86400", now: wall,
                                           consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(huge, 300, accuracy: 0.0001)
        let absurd = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "1e300", now: wall,
                                             consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(absurd, 300, accuracy: 0.0001)
    }

    func test_anHttpDateHeaderIsHonoured() {
        let delay = UploadRetryPolicy.delay(status: 503, retryAfterHeader: "Sun, 06 Nov 1994 08:49:37 GMT",
                                            now: wall, consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(delay, 30, accuracy: 0.001)
    }

    func test_aMissingHeaderOn429Or503DefaultsToThirtySecondsThenDoubles() {
        var delays: [TimeInterval] = []
        for streak in 1...6 {
            delays.append(UploadRetryPolicy.delay(status: 429, retryAfterHeader: nil, now: wall,
                                                  consecutiveFailures: streak, jitterUnit: 0))
        }
        XCTAssertEqual(delays, [30, 60, 120, 240, 300, 300])
        let on503 = UploadRetryPolicy.delay(status: 503, retryAfterHeader: nil, now: wall,
                                            consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(on503, 30, accuracy: 0.0001)
    }

    func test_anUnusableHeaderFallsBackToTheDefault() {
        let delay = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "soon", now: wall,
                                            consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(delay, 30, accuracy: 0.0001)
    }

    func test_otherKeptFailuresStartAtTenSecondsAndDoubleToTheCap() {
        var delays: [TimeInterval] = []
        for streak in 1...7 {
            delays.append(UploadRetryPolicy.delay(status: 500, retryAfterHeader: nil, now: wall,
                                                  consecutiveFailures: streak, jitterUnit: 0))
        }
        XCTAssertEqual(delays, [10, 20, 40, 80, 160, 300, 300])
        let network = UploadRetryPolicy.delay(status: nil, retryAfterHeader: nil, now: wall,
                                              consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(network, 10, accuracy: 0.0001)
    }

    func test_aHeaderOnAServerErrorIsHonouredToo() {
        let delay = UploadRetryPolicy.delay(status: 500, retryAfterHeader: "45", now: wall,
                                            consecutiveFailures: 1, jitterUnit: 0)
        XCTAssertEqual(delay, 45, accuracy: 0.0001)
    }

    func test_jitterIsAddedOnTopAndNeverTakenOff() {
        let low = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "60", now: wall,
                                          consecutiveFailures: 1, jitterUnit: 0)
        let high = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "60", now: wall,
                                           consecutiveFailures: 1, jitterUnit: 1)
        XCTAssertEqual(low, 60, accuracy: 0.0001)
        XCTAssertEqual(high, 72, accuracy: 0.0001)
        let clamped = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "60", now: wall,
                                              consecutiveFailures: 1, jitterUnit: -9)
        XCTAssertEqual(clamped, 60, accuracy: 0.0001)
        let over = UploadRetryPolicy.delay(status: 429, retryAfterHeader: "60", now: wall,
                                           consecutiveFailures: 1, jitterUnit: 9)
        XCTAssertEqual(over, 72, accuracy: 0.0001)
    }

    // MARK: - UploadPause

    func test_aFailureOpensAPauseThatEndsExactlyAtItsDelay() {
        var pause = UploadPause()
        XCTAssertFalse(pause.isPaused(now: 100))
        let delay = pause.recordFailure(status: 429, retryAfterHeader: "60", now: 100, wallClock: wall, jitterUnit: 0)
        XCTAssertEqual(delay, 60, accuracy: 0.0001)
        XCTAssertTrue(pause.isPaused(now: 100))
        XCTAssertTrue(pause.isPaused(now: 159.9))
        XCTAssertFalse(pause.isPaused(now: 160))
        XCTAssertEqual(pause.remainingSeconds(now: 130), 30, accuracy: 0.0001)
        XCTAssertEqual(pause.remainingSeconds(now: 999), 0, accuracy: 0.0001)
        XCTAssertEqual(pause.consecutiveFailures, 1)
    }

    func test_aShorterAnswerNeverCutsAPauseAlreadyInForce() {
        var pause = UploadPause()
        _ = pause.recordFailure(status: 429, retryAfterHeader: "120", now: 0, wallClock: wall, jitterUnit: 0)
        _ = pause.recordFailure(status: 429, retryAfterHeader: "5", now: 10, wallClock: wall, jitterUnit: 0)
        XCTAssertTrue(pause.isPaused(now: 119))
        XCTAssertFalse(pause.isPaused(now: 120))
    }

    func test_consecutiveFailuresDoubleTheDefaultAndSuccessStartsOver() {
        var pause = UploadPause()
        let first = pause.recordFailure(status: 429, retryAfterHeader: nil, now: 0, wallClock: wall, jitterUnit: 0)
        let second = pause.recordFailure(status: 429, retryAfterHeader: nil, now: 30, wallClock: wall, jitterUnit: 0)
        XCTAssertEqual(first, 30, accuracy: 0.0001)
        XCTAssertEqual(second, 60, accuracy: 0.0001)
        pause.recordSuccess()
        XCTAssertEqual(pause.consecutiveFailures, 0)
        XCTAssertFalse(pause.isPaused(now: 0))
        let again = pause.recordFailure(status: 429, retryAfterHeader: nil, now: 500, wallClock: wall, jitterUnit: 0)
        XCTAssertEqual(again, 30, accuracy: 0.0001)
    }

    // MARK: - RetryBatchBuffer: the batch is kept and comes back

    private func costOne(_ element: String) -> Int { return 1 }

    /// The scenario of 2026-10-03: the batch is answered 429 + Retry-After 60. It must stay,
    /// nothing may be sent for 60 s, and then the SAME batch must go out again.
    func test_aThrottledBatchIsKeptPausedAndRetriedAfterTheDelay() {
        var buffer = RetryBatchBuffer<String>(capacity: 10)
        buffer.append("a")
        buffer.append("b")
        buffer.append("c")

        guard let first = buffer.peekBatch(maxCount: 10, maxCost: 100, cost: costOne) else {
            XCTFail("expected a batch")
            return
        }
        XCTAssertEqual(first.elements, ["a", "b", "c"])

        // The server answered 429 Retry-After: 60.
        XCTAssertEqual(UploadRetryPolicy.verdict(status: 429), .keep)
        buffer.recordFailure(status: 429, retryAfterHeader: "60", now: 1000, wallClock: wall, jitterUnit: 0)

        XCTAssertEqual(buffer.count, 3, "nothing was dropped")
        XCTAssertEqual(buffer.droppedTotal, 0)
        XCTAssertTrue(buffer.isPaused(now: 1000), "paused at once")
        XCTAssertTrue(buffer.isPaused(now: 1059.9), "still paused 59.9 s later")
        XCTAssertFalse(buffer.isPaused(now: 1060), "free exactly when the server said")

        guard let retry = buffer.peekBatch(maxCount: 10, maxCost: 100, cost: costOne) else {
            XCTFail("the batch must still be there")
            return
        }
        XCTAssertEqual(retry.elements, ["a", "b", "c"], "the same batch, in the same order")
        XCTAssertEqual(retry.lastSeq, first.lastSeq)

        buffer.confirm(throughSeq: retry.lastSeq)
        buffer.recordSuccess()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertFalse(buffer.isPaused(now: 1000))
    }

    func test_aNetworkErrorAlsoKeepsTheBatchAndPauses() {
        var buffer = RetryBatchBuffer<String>(capacity: 10)
        buffer.append("a")
        XCTAssertEqual(UploadRetryPolicy.verdict(status: nil), .keep)
        buffer.recordFailure(status: nil, retryAfterHeader: nil, now: 0, wallClock: wall, jitterUnit: 0)
        XCTAssertEqual(buffer.count, 1)
        XCTAssertTrue(buffer.isPaused(now: 9.9))
        XCTAssertFalse(buffer.isPaused(now: 10))
    }

    func test_eventsAppendedWhilePausedJoinTheKeptBatch() {
        var buffer = RetryBatchBuffer<String>(capacity: 10)
        buffer.append("a")
        buffer.recordFailure(status: 429, retryAfterHeader: "60", now: 0, wallClock: wall, jitterUnit: 0)
        buffer.append("b")
        let batch = buffer.peekBatch(maxCount: 10, maxCost: 100, cost: costOne)
        XCTAssertEqual(batch?.elements ?? [], ["a", "b"])
    }

    // MARK: - RetryBatchBuffer: bounds and the drop counter

    func test_whenFullTheOldestIsDroppedAndCounted() {
        var buffer = RetryBatchBuffer<String>(capacity: 3)
        XCTAssertEqual(buffer.append("a"), 0)
        buffer.append("b")
        buffer.append("c")
        XCTAssertEqual(buffer.append("d"), 1)
        XCTAssertEqual(buffer.append("e"), 1)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.droppedTotal, 2)
        XCTAssertEqual(buffer.unreportedDrops, 2)
        let batch = buffer.peekBatch(maxCount: 10, maxCost: 100, cost: costOne)
        XCTAssertEqual(batch?.elements ?? [], ["c", "d", "e"], "oldest first")
    }

    func test_priorityPayloadsOutliveRoutineOnes() {
        var buffer = RetryBatchBuffer<String>(capacity: 3)
        buffer.append("error-1", isPriority: true)
        buffer.append("a")
        buffer.append("b")
        buffer.append("c")   // drops "a", the oldest routine one
        buffer.append("d")   // drops "b"
        let batch = buffer.peekBatch(maxCount: 10, maxCost: 100, cost: costOne)
        XCTAssertEqual(batch?.elements ?? [], ["error-1", "c", "d"])
        XCTAssertEqual(buffer.droppedTotal, 2)
    }

    func test_ifEverythingIsPriorityTheOldestStillGoes() {
        var buffer = RetryBatchBuffer<String>(capacity: 2)
        buffer.append("e1", isPriority: true)
        buffer.append("e2", isPriority: true)
        buffer.append("e3", isPriority: true)
        let batch = buffer.peekBatch(maxCount: 10, maxCost: 100, cost: costOne)
        XCTAssertEqual(batch?.elements ?? [], ["e2", "e3"])
    }

    /// The count is reported once, in the next batch the server CONFIRMS: a failed attempt
    /// must not use it up.
    func test_theDropCountIsReportedOnlyAfterAConfirmedBatch() {
        var buffer = RetryBatchBuffer<String>(capacity: 2)
        buffer.append("a")
        buffer.append("b")
        buffer.append("c")
        buffer.append("d")
        XCTAssertEqual(buffer.unreportedDrops, 2)

        // Attempt 1 carried "dropped=2" and failed: nothing acknowledged.
        buffer.recordFailure(status: 429, retryAfterHeader: "1", now: 0, wallClock: wall, jitterUnit: 0)
        XCTAssertEqual(buffer.unreportedDrops, 2)

        // Attempt 2 carried it and was confirmed.
        buffer.acknowledgeDropReport(2)
        XCTAssertEqual(buffer.unreportedDrops, 0)
        XCTAssertEqual(buffer.droppedTotal, 2, "the running total is kept")
    }

    func test_dropsThatHappenWhileTheReportWasInFlightAreStillReportedLater() {
        var buffer = RetryBatchBuffer<String>(capacity: 1)
        buffer.append("a")
        buffer.append("b")            // 1 drop
        let inFlight = buffer.unreportedDrops
        buffer.append("c")            // 1 more while the request is out
        buffer.acknowledgeDropReport(inFlight)
        XCTAssertEqual(buffer.unreportedDrops, 1)
    }

    func test_aConfirmationIsKeyedBySequenceNotPosition() {
        var buffer = RetryBatchBuffer<String>(capacity: 3)
        buffer.append("a")
        buffer.append("b")
        buffer.append("c")
        guard let batch = buffer.peekBatch(maxCount: 2, maxCost: 100, cost: costOne) else {
            XCTFail("expected a batch")
            return
        }
        XCTAssertEqual(batch.elements, ["a", "b"])
        // While that batch is in flight the oldest payload is evicted for room.
        buffer.append("d")
        buffer.append("e")
        // Confirming the batch must remove only what is still there up to its cursor,
        // never "c" or newer.
        buffer.confirm(throughSeq: batch.lastSeq)
        let rest = buffer.peekBatch(maxCount: 10, maxCost: 100, cost: costOne)
        XCTAssertEqual(rest?.elements ?? [], ["c", "d", "e"])
    }

    func test_discardRemovesAndCountsARejectedBatch() {
        var buffer = RetryBatchBuffer<String>(capacity: 10)
        buffer.append("a")
        buffer.append("b")
        buffer.append("c")
        guard let batch = buffer.peekBatch(maxCount: 2, maxCost: 100, cost: costOne) else {
            XCTFail("expected a batch")
            return
        }
        XCTAssertEqual(buffer.discard(throughSeq: batch.lastSeq), 2)
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.droppedTotal, 2)
        XCTAssertEqual(buffer.unreportedDrops, 2)
    }

    func test_peekRespectsTheCountAndCostBudgetsButAlwaysTakesTheFirst() {
        var buffer = RetryBatchBuffer<String>(capacity: 10)
        buffer.append("aaaa")
        buffer.append("bb")
        buffer.append("cc")
        let byCount = buffer.peekBatch(maxCount: 2, maxCost: 1000, cost: { $0.count })
        XCTAssertEqual(byCount?.elements ?? [], ["aaaa", "bb"])
        let byCost = buffer.peekBatch(maxCount: 10, maxCost: 6, cost: { $0.count })
        XCTAssertEqual(byCost?.elements ?? [], ["aaaa", "bb"])
        XCTAssertEqual(byCost?.totalCost, 6)
        let oversized = buffer.peekBatch(maxCount: 10, maxCost: 1, cost: { $0.count })
        XCTAssertEqual(oversized?.elements ?? [], ["aaaa"], "one giant payload must never wedge the queue")
    }

    func test_anEmptyBufferHasNoBatch() {
        let buffer = RetryBatchBuffer<String>(capacity: 4)
        XCTAssertNil(buffer.peekBatch(maxCount: 10, maxCost: 10, cost: costOne))
    }

    func test_removeAllForgetsPayloadsAndCountersButNotThePause() {
        var buffer = RetryBatchBuffer<String>(capacity: 1)
        buffer.append("a")
        buffer.append("b")
        buffer.recordFailure(status: 429, retryAfterHeader: "60", now: 0, wallClock: wall, jitterUnit: 0)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.droppedTotal, 0)
        XCTAssertEqual(buffer.unreportedDrops, 0)
        XCTAssertTrue(buffer.isPaused(now: 30), "withdrawing and re-granting consent is not a way around the pause")
    }

    func test_capacityIsAtLeastOne() {
        var buffer = RetryBatchBuffer<String>(capacity: 0)
        buffer.append("a")
        buffer.append("b")
        XCTAssertEqual(buffer.count, 1)
    }
}
