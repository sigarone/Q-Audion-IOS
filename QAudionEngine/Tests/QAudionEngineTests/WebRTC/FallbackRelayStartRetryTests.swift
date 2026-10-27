import XCTest
@testable import QAudionEngine

/// Pins the retry sequencing of the relay-capture start during the call fallback and the
/// pure decisions around it: a failed start is retried, route changes only bring the next
/// try forward, the native sender is only handed back when every try failed, a re-engage
/// after that is cooled down, and nothing runs once the call is over.
final class FallbackRelayStartRetryTests: XCTestCase {

    /// Manual clock and scheduler: scheduled work runs only when the test fires it, and
    /// firing it moves the clock to the item's due time.
    private final class FakeClock {
        var nowMs: Int64 = 1_000
        private var nextId = 0
        private(set) var pending: [Int: (dueMs: Int64, work: () -> Void)] = [:]
        private(set) var delays: [Int] = []

        var scheduler: FallbackRelayStartRetry.Scheduler {
            { [weak self] delayMs, work in
                guard let self else { return {} }
                self.nextId += 1
                let id = self.nextId
                self.pending[id] = (self.nowMs + Int64(delayMs), work)
                self.delays.append(delayMs)
                return { [weak self] in self?.pending[id] = nil }
            }
        }

        /// Runs the earliest pending item; false when nothing is pending.
        @discardableResult
        func fireNext() -> Bool {
            guard let (id, item) = pending.min(by: { $0.value.dueMs < $1.value.dueMs }) else { return false }
            pending[id] = nil
            nowMs = max(nowMs, item.dueMs)
            item.work()
            return true
        }
    }

    private final class Harness {
        let clock = FakeClock()
        var attemptResults: [Bool]
        var attemptCalls = 0
        var wanted = true
        var failedAttempts: [Int] = []
        var started: [Int] = []
        var gaveUp: [Int] = []
        var observersAdded = 0
        var observersRemoved = 0
        var routeHandler: (() -> Void)?
        lazy var retry = FallbackRelayStartRetry(
            scheduler: clock.scheduler,
            observeRouteChanges: { [unowned self] handler in
                self.observersAdded += 1
                self.routeHandler = handler
                return { [unowned self] in
                    self.observersRemoved += 1
                    self.routeHandler = nil
                }
            },
            nowMs: { [unowned self] in self.clock.nowMs },
            attempt: { [unowned self] in
                self.attemptCalls += 1
                let i = self.attemptCalls - 1
                return i < self.attemptResults.count ? self.attemptResults[i] : (self.attemptResults.last ?? false)
            },
            isStillWanted: { [unowned self] in self.wanted },
            onAttemptFailed: { [unowned self] in self.failedAttempts.append($0) },
            onStarted: { [unowned self] in self.started.append($0) },
            onGaveUp: { [unowned self] in self.gaveUp.append($0) })

        init(results: [Bool]) { attemptResults = results }
    }

    // MARK: - retry sequencing

    func test_startFailsThenSucceedsOnRetry() {
        let h = Harness(results: [false, false, true])
        h.retry.begin(firstDelayMs: 300)
        XCTAssertEqual(h.clock.delays, [300])
        XCTAssertEqual(h.attemptCalls, 0)

        h.clock.fireNext()  // try 1 fails
        XCTAssertEqual(h.failedAttempts, [1])
        XCTAssertEqual(h.clock.delays.last, FallbackRelayStartRetry.intervalMs)
        h.clock.fireNext()  // try 2 fails
        h.clock.fireNext()  // try 3 succeeds

        XCTAssertEqual(h.failedAttempts, [1, 2])
        XCTAssertEqual(h.started, [3])
        XCTAssertTrue(h.gaveUp.isEmpty)
        XCTAssertFalse(h.retry.isRunning)
        XCTAssertFalse(h.clock.fireNext(), "nothing may be scheduled after a successful start")
    }

    func test_firstTryInlineWhenNoDelay() {
        let h = Harness(results: [true])
        h.retry.begin(firstDelayMs: 0)
        XCTAssertEqual(h.started, [1])
        XCTAssertTrue(h.clock.delays.isEmpty)
    }

    func test_allRetriesFailGivesUpOnceAndStops() {
        let h = Harness(results: [false])
        h.retry.begin(firstDelayMs: 300)
        while h.clock.fireNext() {}

        XCTAssertEqual(h.attemptCalls, FallbackRelayStartRetry.maxAttempts)
        XCTAssertEqual(h.gaveUp, [FallbackRelayStartRetry.maxAttempts], "exactly one failure report")
        XCTAssertTrue(h.started.isEmpty)
        XCTAssertFalse(h.retry.isRunning)
        XCTAssertFalse(h.clock.fireNext())
        let retryWindowMs = FallbackRelayStartRetry.intervalMs * (FallbackRelayStartRetry.maxAttempts - 1)
        XCTAssertTrue((1_500...2_500).contains(retryWindowMs))
    }

    func test_callEndsDuringRetryStopsFurtherAttempts() {
        let h = Harness(results: [false])
        h.retry.begin(firstDelayMs: 300)
        h.clock.fireNext()  // try 1 fails, try 2 is pending
        XCTAssertEqual(h.attemptCalls, 1)

        h.retry.cancel()  // the call ended
        XCTAssertFalse(h.clock.fireNext(), "the pending try was cancelled")
        XCTAssertEqual(h.attemptCalls, 1)
        XCTAssertTrue(h.gaveUp.isEmpty)
        XCTAssertTrue(h.started.isEmpty)
        h.retry.cancel()  // a second cancel is harmless
        XCTAssertEqual(h.observersRemoved, 1)
    }

    func test_fallbackLeftBeforeTheTimerFiresMakesTheTryANoOp() {
        let h = Harness(results: [false])
        h.retry.begin(firstDelayMs: 300)
        h.clock.fireNext()
        h.wanted = false  // generation moved / latch cleared without a cancel call
        h.clock.fireNext()
        XCTAssertEqual(h.attemptCalls, 1)
        XCTAssertFalse(h.retry.isRunning)
        XCTAssertFalse(h.clock.fireNext())
        XCTAssertTrue(h.gaveUp.isEmpty)
        XCTAssertEqual(h.observersRemoved, 1, "the observer goes with the sequence")
    }

    func test_beginWhileRunningIsIgnored() {
        let h = Harness(results: [false])
        XCTAssertTrue(h.retry.begin(firstDelayMs: 300))
        XCTAssertFalse(h.retry.begin(firstDelayMs: 0))
        XCTAssertEqual(h.attemptCalls, 0)
        XCTAssertEqual(h.clock.pending.count, 1)
        XCTAssertEqual(h.observersAdded, 1)
    }

    // MARK: - route-change nudges

    func test_nudgeDuringSettleIsIgnored() {
        let h = Harness(results: [true])
        h.retry.begin(firstDelayMs: 300)
        h.clock.nowMs += 100  // still inside the 300 ms settle
        h.routeHandler?()
        XCTAssertEqual(h.attemptCalls, 0)
        XCTAssertEqual(h.clock.pending.count, 1, "only the original first try is pending")
        h.clock.fireNext()
        XCTAssertEqual(h.started, [1])
    }

    func test_burstOfNudgesDoesNotExhaustTheAttempts() {
        let h = Harness(results: [false])
        h.retry.begin(firstDelayMs: 300)
        h.clock.fireNext()  // try 1 fails at the end of the settle
        for _ in 0..<50 { h.routeHandler?() }  // a burst of route notifications
        while h.clock.fireNext() {}

        XCTAssertEqual(h.attemptCalls, FallbackRelayStartRetry.maxAttempts, "never more tries than the cap")
        XCTAssertEqual(h.gaveUp.count, 1)
        XCTAssertGreaterThan(h.clock.nowMs, 1_000 + 300 + 100 * 10, "the tries stayed spread out in time")
    }

    func test_nudgeOnlyBringsTheNextTryForwardAndKeepsMinimumSpacing() {
        let h = Harness(results: [false, true])
        h.retry.begin(firstDelayMs: 300)
        h.clock.fireNext()  // try 1 fails at t=1300, try 2 pending at t=1450
        h.clock.nowMs += 20
        h.routeHandler?()  // would be too close to try 1: pulled to the minimum spacing only
        XCTAssertEqual(h.attemptCalls, 1)
        XCTAssertEqual(h.clock.pending.count, 1, "the pending try is moved, not duplicated")
        let due = h.clock.pending.values.first!.dueMs
        XCTAssertEqual(due, 1_300 + FallbackRelayStartRetry.minTrySpacingMs)
        h.clock.fireNext()
        XCTAssertEqual(h.started, [2])
        XCTAssertFalse(h.clock.fireNext())
        h.routeHandler?()  // after the end: no observer, nothing happens
        XCTAssertEqual(h.attemptCalls, 2)
    }

    // MARK: - observer and cycles

    func test_observerRemovedOnEveryWayOut() {
        let started = Harness(results: [true])
        started.retry.begin(firstDelayMs: 0)
        XCTAssertEqual(started.observersAdded, 1)
        XCTAssertEqual(started.observersRemoved, 1)

        let gaveUp = Harness(results: [false])
        gaveUp.retry.begin(firstDelayMs: 300)
        while gaveUp.clock.fireNext() {}
        XCTAssertEqual(gaveUp.observersRemoved, 1)

        let cancelled = Harness(results: [false])
        cancelled.retry.begin(firstDelayMs: 300)
        cancelled.retry.cancel()
        XCTAssertEqual(cancelled.observersRemoved, 1)
        XCTAssertNil(cancelled.routeHandler)
    }

    func test_repeatedEngageGiveUpEngageCyclesLeaveNothingBehind() {
        let h = Harness(results: [false])
        for cycle in 1...3 {
            XCTAssertTrue(h.retry.begin(firstDelayMs: 300), "cycle \(cycle) starts cleanly")
            while h.clock.fireNext() {}
            XCTAssertFalse(h.retry.isRunning)
            XCTAssertEqual(h.observersAdded, cycle)
            XCTAssertEqual(h.observersRemoved, cycle, "no leaked observer after cycle \(cycle)")
            XCTAssertTrue(h.clock.pending.isEmpty)
        }
        XCTAssertEqual(h.gaveUp.count, 3)
        XCTAssertEqual(h.attemptCalls, 3 * FallbackRelayStartRetry.maxAttempts, "attempts restart each cycle")
    }

    // MARK: - mute formula

    func test_muteFormulaWhileRelayStartIsPending() {
        typealias M = NativeSenderMuteDecisions
        // Pending: the native sender stays active even though the latch is set.
        XCTAssertFalse(M.shouldMute(peerAnswered: true, userMuted: false, fallbackActive: true, relayStartPending: true))
        // Confirmed (no longer pending): the sender is muted next to the relay capture.
        XCTAssertTrue(M.shouldMute(peerAnswered: true, userMuted: false, fallbackActive: true, relayStartPending: false))
        // The user's own mute and the pre-answer gate always win.
        XCTAssertTrue(M.shouldMute(peerAnswered: true, userMuted: true, fallbackActive: true, relayStartPending: true))
        XCTAssertTrue(M.shouldMute(peerAnswered: false, userMuted: false, fallbackActive: true, relayStartPending: true))
        // Default keeps the old meaning.
        XCTAssertTrue(M.shouldMute(peerAnswered: true, userMuted: false, fallbackActive: true))
        XCTAssertFalse(M.shouldMute(peerAnswered: true, userMuted: false, fallbackActive: false))
    }

    // MARK: - give-up hand-back

    func test_handBackRestoreOrder() {
        XCTAssertEqual(
            FallbackHandBack.steps,
            [.clearLatch, .stopCapture, .unmuteNativeSender, .restoreNativeUnit, .resetControllerState])
    }

    func test_nativeSenderStaysActiveUntilStartIsConfirmed() {
        func run(results: [Bool]) -> (muted: Bool, mutedWhileTrying: Bool) {
            var muted = false
            var mutedWhileTrying = false
            let clock = FakeClock()
            var calls = 0
            let retry = FallbackRelayStartRetry(
                scheduler: clock.scheduler,
                nowMs: { clock.nowMs },
                attempt: {
                    mutedWhileTrying = mutedWhileTrying || muted
                    calls += 1
                    return results[min(calls - 1, results.count - 1)]
                },
                isStillWanted: { true },
                onAttemptFailed: { _ in },
                onStarted: { _ in muted = true },
                onGaveUp: { _ in muted = false })
            retry.begin(firstDelayMs: 300)
            while clock.fireNext() {}
            return (muted, mutedWhileTrying)
        }
        let ok = run(results: [false, false, true])
        XCTAssertTrue(ok.muted)
        XCTAssertFalse(ok.mutedWhileTrying, "never muted while the relay capture is not running")
        let failed = run(results: [false])
        XCTAssertFalse(failed.muted, "native sender kept when every try failed")
        XCTAssertFalse(failed.mutedWhileTrying)
    }

    // MARK: - re-engage after a give-up

    func test_reengageAfterGiveUpIsCooledDownAndCapped() {
        typealias V = SrtpFallbackLatchDecisions
        func verdict(giveUps: Int, since: Int64?) -> V.EngageVerdict {
            V.engageVerdict(
                callLive: true, capturedGeneration: 5, currentGeneration: 5, alreadyActive: false,
                giveUps: giveUps, msSinceLastGiveUp: since)
        }
        XCTAssertEqual(verdict(giveUps: 0, since: nil), .engage)
        XCTAssertEqual(verdict(giveUps: 1, since: 2_000), .coolingDown)
        XCTAssertEqual(verdict(giveUps: 1, since: SrtpFallbackDecisions.giveUpCooldownMs), .engage)
        XCTAssertEqual(
            verdict(giveUps: SrtpFallbackDecisions.maxGiveUpsPerCall, since: 60_000), .giveUpCap)
        // The existing fences still come first.
        XCTAssertEqual(
            V.engageVerdict(
                callLive: false, capturedGeneration: 5, currentGeneration: 5, alreadyActive: false,
                giveUps: 1, msSinceLastGiveUp: 100),
            .noCallLive)
    }
}
