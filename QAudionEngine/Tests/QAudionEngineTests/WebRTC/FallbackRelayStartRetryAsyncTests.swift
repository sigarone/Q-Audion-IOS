import XCTest
@testable import QAudionEngine

/// The relay-capture start sequence when the start runs on the audio queue and the result comes
/// back later: the result is awaited before anything else is scheduled, a route change does not add
/// a try while one is running, and a result that arrives after the sequence was cancelled is dropped.
final class FallbackRelayStartRetryAsyncTests: XCTestCase {

    private final class Clock {
        var nowMs: Int64 = 1_000
        private var nextId = 0
        private(set) var pending: [Int: (dueMs: Int64, work: () -> Void)] = [:]

        var scheduler: FallbackRelayStartRetry.Scheduler {
            { [weak self] delayMs, work in
                guard let self else { return {} }
                self.nextId += 1
                let id = self.nextId
                self.pending[id] = (self.nowMs + Int64(delayMs), work)
                return { [weak self] in self?.pending[id] = nil }
            }
        }

        func fireNext() {
            guard let (id, item) = pending.min(by: { $0.value.dueMs < $1.value.dueMs }) else { return }
            pending[id] = nil
            nowMs = max(nowMs, item.dueMs)
            item.work()
        }
    }

    private final class Harness {
        let clock = Clock()
        var completions: [(Bool) -> Void] = []
        var failed: [Int] = []
        var started: [Int] = []
        var gaveUp: [Int] = []
        var wanted = true
        lazy var retry = FallbackRelayStartRetry(
            scheduler: clock.scheduler,
            nowMs: { [unowned self] in self.clock.nowMs },
            attemptAsync: { [unowned self] done in self.completions.append(done) },
            isStillWanted: { [unowned self] in self.wanted },
            onAttemptFailed: { [unowned self] n in self.failed.append(n) },
            onStarted: { [unowned self] n in self.started.append(n) },
            onGaveUp: { [unowned self] n in self.gaveUp.append(n) })
    }

    func test_resultArrivingLater_isBooked_andNothingElseRunsMeanwhile() {
        let h = Harness()
        h.retry.begin(firstDelayMs: 0)
        XCTAssertEqual(h.completions.count, 1)
        XCTAssertTrue(h.retry.isRunning)
        XCTAssertTrue(h.clock.pending.isEmpty, "no next try is scheduled while the result is awaited")

        h.retry.nudge()
        XCTAssertTrue(h.clock.pending.isEmpty, "a route change adds no try while one is running")

        h.completions[0](false)
        XCTAssertEqual(h.failed, [1])
        XCTAssertEqual(h.clock.pending.count, 1, "the next try is scheduled once the failure is known")

        h.clock.fireNext()
        XCTAssertEqual(h.completions.count, 2)
        h.completions[1](true)
        XCTAssertEqual(h.started, [2])
        XCTAssertFalse(h.retry.isRunning)
    }

    func test_resultArrivingAfterCancel_isDropped() {
        let h = Harness()
        h.retry.begin(firstDelayMs: 0)
        h.retry.cancel()
        h.completions[0](true)
        XCTAssertTrue(h.started.isEmpty)
        XCTAssertTrue(h.failed.isEmpty)
        XCTAssertFalse(h.retry.isRunning)
    }

    func test_everyTryFailing_givesUpAfterTheLastResult() {
        let h = Harness()
        h.retry.begin(firstDelayMs: 0)
        var tries = 0
        while h.retry.isRunning && tries < 50 {
            tries += 1
            h.completions.last?(false)
            if h.retry.isRunning { h.clock.fireNext() }
        }
        XCTAssertEqual(h.gaveUp, [FallbackRelayStartRetry.maxAttempts])
        XCTAssertEqual(h.failed.count, FallbackRelayStartRetry.maxAttempts)
    }

    func test_callOverWhileWaiting_nextTryEndsTheSequence() {
        let h = Harness()
        h.retry.begin(firstDelayMs: 0)
        h.completions[0](false)
        h.wanted = false
        h.clock.fireNext()
        XCTAssertFalse(h.retry.isRunning)
        XCTAssertEqual(h.completions.count, 1, "no further start once the fallback no longer applies")
    }
}
