import XCTest
@testable import QAudionEngine

/// W-LIVELOGOFFMAIN (2026-09-21) — when the log shipper backs off, for how long, and how
/// it reads `Retry-After`. Every test drives an injected monotonic clock (`now`) and an
/// injected jitter draw: nothing sleeps and nothing is random.
final class LiveLogBackoffTests: XCTestCase {

    // MARK: - Which failures back off

    func test_classifyTreatsOnly429And503AsThrottle() {
        XCTAssertEqual(LiveLogBackoff.classify(status: 429), .throttle)
        XCTAssertEqual(LiveLogBackoff.classify(status: 503), .throttle)
    }

    func test_classifyKeepsEveryOther5xxOnItsOwnClass() {
        XCTAssertEqual(LiveLogBackoff.classify(status: 500), .serverError)
        XCTAssertEqual(LiveLogBackoff.classify(status: 502), .serverError)
        XCTAssertEqual(LiveLogBackoff.classify(status: 504), .serverError)
        XCTAssertEqual(LiveLogBackoff.classify(status: 599), .serverError)
    }

    func test_classifyLeavesEverythingElseAlone() {
        XCTAssertEqual(LiveLogBackoff.classify(status: 400), .other)
        XCTAssertEqual(LiveLogBackoff.classify(status: 401), .other)
        XCTAssertEqual(LiveLogBackoff.classify(status: 404), .other)
        XCTAssertEqual(LiveLogBackoff.classify(status: 499), .other)
        XCTAssertEqual(LiveLogBackoff.classify(status: 600), .other)
        XCTAssertEqual(LiveLogBackoff.classify(status: nil), .other)
    }

    // MARK: - The exponential schedule

    func test_throttleScheduleDoublesFromFiveSecondsToTheCap() {
        var backoff = LiveLogBackoff()
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            let delay = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
            delays.append(delay ?? -1)
        }
        XCTAssertEqual(delays, [5, 10, 20, 40, 80, 120, 120, 120])
        XCTAssertEqual(backoff.consecutiveFailures, 8)
    }

    func test_503FollowsTheSameScheduleAs429() {
        var backoff = LiveLogBackoff()
        let first = backoff.recordFailure(status: 503, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
        let second = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
        XCTAssertEqual(first ?? -1, 5)
        XCTAssertEqual(second ?? -1, 10)
    }

    func test_jitterAddsUpToTwentyPercentOnTopOfTheScheduledDelay() {
        var low = LiveLogBackoff()
        var high = LiveLogBackoff()
        let lowest = low.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
        let highest = high.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: 1)
        XCTAssertEqual(lowest ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(highest ?? -1, 6, accuracy: 0.0001)
    }

    func test_jitterDrawIsClampedToTheUnitInterval() {
        var below = LiveLogBackoff()
        var above = LiveLogBackoff()
        let underflow = below.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: -4)
        let overflow = above.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: 9)
        XCTAssertEqual(underflow ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(overflow ?? -1, 6, accuracy: 0.0001)
    }

    func test_otherServerErrorsKeepTheScheduleTheShipperAlwaysUsed() {
        var backoff = LiveLogBackoff()
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            let delay = backoff.recordFailure(status: 500, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
            delays.append(delay ?? -1)
        }
        // 3 s doubling, exponent capped at 5 (so 48 s is the plateau), as before.
        XCTAssertEqual(delays, [3, 6, 12, 24, 48, 48, 48])
    }

    // MARK: - The back-off window itself

    func test_theWindowIsRelativeToTheInjectedClock() {
        var backoff = LiveLogBackoff()
        XCTAssertFalse(backoff.isBackingOff(now: 100))
        _ = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 100, jitterUnit: 0)
        XCTAssertTrue(backoff.isBackingOff(now: 100))
        XCTAssertTrue(backoff.isBackingOff(now: 104.9))
        XCTAssertFalse(backoff.isBackingOff(now: 105))
        XCTAssertEqual(backoff.remainingSeconds(now: 101), 4, accuracy: 0.0001)
        XCTAssertEqual(backoff.remainingSeconds(now: 500), 0, accuracy: 0.0001)
    }

    // MARK: - Retry-After

    func test_retryAfterIsHonouredExactlyForThrottleStatuses() {
        var backoff = LiveLogBackoff()
        let delay = backoff.recordFailure(status: 429, retryAfterSeconds: 37, now: 100, jitterUnit: 1)
        XCTAssertEqual(delay ?? -1, 37, accuracy: 0.0001, "the server's hint replaces the schedule and gets no jitter")
        XCTAssertTrue(backoff.isBackingOff(now: 136.9))
        XCTAssertFalse(backoff.isBackingOff(now: 137))
    }

    func test_retryAfterIsHonouredOn503() {
        var backoff = LiveLogBackoff()
        let delay = backoff.recordFailure(status: 503, retryAfterSeconds: 45, now: 0, jitterUnit: 0)
        XCTAssertEqual(delay ?? -1, 45, accuracy: 0.0001)
    }

    func test_retryAfterIsClampedToASaneRange() {
        var tiny = LiveLogBackoff()
        var huge = LiveLogBackoff()
        let raised = tiny.recordFailure(status: 429, retryAfterSeconds: 0, now: 0, jitterUnit: 0)
        let lowered = huge.recordFailure(status: 429, retryAfterSeconds: 86_400, now: 0, jitterUnit: 0)
        XCTAssertEqual(raised ?? -1, LiveLogBackoff.retryAfterMinSeconds, accuracy: 0.0001)
        XCTAssertEqual(lowered ?? -1, LiveLogBackoff.retryAfterMaxSeconds, accuracy: 0.0001)
    }

    func test_anUnusableRetryAfterFallsBackToTheSchedule() {
        var negative = LiveLogBackoff()
        var infinite = LiveLogBackoff()
        let a = negative.recordFailure(status: 429, retryAfterSeconds: -5, now: 0, jitterUnit: 0)
        let b = infinite.recordFailure(status: 429, retryAfterSeconds: Double.infinity, now: 0, jitterUnit: 0)
        XCTAssertEqual(a ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(b ?? -1, 5, accuracy: 0.0001)
    }

    func test_retryAfterIsIgnoredForOtherServerErrors() {
        var backoff = LiveLogBackoff()
        let delay = backoff.recordFailure(status: 500, retryAfterSeconds: 300, now: 0, jitterUnit: 0)
        XCTAssertEqual(delay ?? -1, 3, accuracy: 0.0001, "500 keeps its old schedule; only 429/503 read the header")
    }

    func test_aRetryAfterAnswerStillCountsInTheStreak() {
        var backoff = LiveLogBackoff()
        _ = backoff.recordFailure(status: 429, retryAfterSeconds: 30, now: 0, jitterUnit: 0)
        let next = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 30, jitterUnit: 0)
        XCTAssertEqual(next ?? -1, 10, accuracy: 0.0001, "the second failure is the second step of the schedule")
    }

    // MARK: - Reset

    func test_successClearsTheStreakAndTheBackoff() {
        var backoff = LiveLogBackoff()
        _ = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
        _ = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 10, jitterUnit: 0)
        XCTAssertEqual(backoff.consecutiveFailures, 2)
        backoff.recordSuccess()
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        XCTAssertFalse(backoff.isBackingOff(now: 10))
        let again = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 200, jitterUnit: 0)
        XCTAssertEqual(again ?? -1, 5, accuracy: 0.0001, "after a success the schedule starts over")
    }

    func test_aFailureThatIsNotAThrottleEndsTheStreakButStartsNoBackoff() {
        var backoff = LiveLogBackoff()
        _ = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
        _ = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
        XCTAssertEqual(backoff.consecutiveFailures, 2)

        let unrelated = backoff.recordFailure(status: 404, retryAfterSeconds: nil, now: 3, jitterUnit: 0)
        XCTAssertNil(unrelated)
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        XCTAssertTrue(backoff.isBackingOff(now: 3), "a back-off already in force is left to run out, as before")

        let next = backoff.recordFailure(status: 429, retryAfterSeconds: nil, now: 20, jitterUnit: 0)
        XCTAssertEqual(next ?? -1, 5, accuracy: 0.0001)
    }

    func test_aNetworkErrorWithNoStatusNeverBacksOff() {
        var backoff = LiveLogBackoff()
        let delay = backoff.recordFailure(status: nil, retryAfterSeconds: nil, now: 0, jitterUnit: 0)
        XCTAssertNil(delay)
        XCTAssertFalse(backoff.isBackingOff(now: 0))
    }

    // MARK: - Parsing Retry-After

    func test_parseRetryAfterReadsDelaySeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(LiveLogBackoff.parseRetryAfter("120", now: now) ?? -1, 120, accuracy: 0.0001)
        XCTAssertEqual(LiveLogBackoff.parseRetryAfter("  7 ", now: now) ?? -1, 7, accuracy: 0.0001)
        XCTAssertEqual(LiveLogBackoff.parseRetryAfter("0", now: now) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(LiveLogBackoff.parseRetryAfter("1.5", now: now) ?? -1, 1.5, accuracy: 0.0001)
    }

    func test_parseRetryAfterRejectsWhatIsNotAHint() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(LiveLogBackoff.parseRetryAfter(nil, now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("", now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("   ", now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("soon", now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("-3", now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("inf", now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("nan", now: now))
    }

    func test_parseRetryAfterReadsAnHttpDateRelativeToNow() {
        // 1994-11-06T08:49:37Z is epoch 784111777.
        let now = Date(timeIntervalSince1970: 784_111_747)
        let seconds = LiveLogBackoff.parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now: now)
        XCTAssertEqual(seconds ?? -1, 30, accuracy: 0.001)
    }

    func test_parseRetryAfterTurnsADateInThePastIntoZero() {
        let now = Date(timeIntervalSince1970: 784_111_877)
        let seconds = LiveLogBackoff.parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now: now)
        XCTAssertEqual(seconds ?? -1, 0, accuracy: 0.001)
    }

    func test_parseRetryAfterRejectsMalformedDates() {
        let now = Date(timeIntervalSince1970: 784_111_747)
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("Sun, 06 Nov 1994 08:49:37 PST", now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("Sun 06 Nov 1994 08:49:37 GMT", now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("Sun, 06 Xyz 1994 08:49:37 GMT", now: now))
        XCTAssertNil(LiveLogBackoff.parseRetryAfter("Sun, 06 Nov 1994 08:49 GMT", now: now))
    }

    func test_httpDateParserIsExactAndLocaleIndependent() {
        let date = LiveLogBackoff.parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT")
        XCTAssertEqual(date?.timeIntervalSince1970 ?? -1, 784_111_777, accuracy: 0.001)
    }
}
