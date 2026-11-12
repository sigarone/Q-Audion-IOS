import XCTest
@testable import QAudionEngine

/// The decisions around the call audio queue, and the queue seams that carry them: the playout path
/// drops a frame without touching the engine while the queue holds it, a route restart queued behind a
/// stop runs after it and finds the engine down, a stop queued for an earlier call does not
/// deactivate a newer call's session, and a skipped engage is recovered.
final class CallAudioQueuePoliciesTests: XCTestCase {

    private func makeQueue() -> AudioEngineSerialQueue {
        AudioEngineSerialQueue(label: "test.policies.\(UUID().uuidString)")
    }

    // MARK: - playout versus the audio queue

    func test_playoutDecision() {
        typealias Access = PlayoutEngineAccess
        XCTAssertEqual(Access.decision(lockAcquired: false, isRunning: true, hasPlayerAndEngine: true, engineRunning: true), .drop)
        XCTAssertEqual(Access.decision(lockAcquired: true, isRunning: true, hasPlayerAndEngine: true, engineRunning: true), .schedule)
        XCTAssertEqual(Access.decision(lockAcquired: true, isRunning: false, hasPlayerAndEngine: true, engineRunning: true), .drop)
        XCTAssertEqual(Access.decision(lockAcquired: true, isRunning: true, hasPlayerAndEngine: false, engineRunning: true), .drop)
        XCTAssertEqual(Access.decision(lockAcquired: true, isRunning: true, hasPlayerAndEngine: true, engineRunning: false), .drop)
    }

    /// The audio queue holds the engine lock for a whole stop. A playout attempt (any other thread) must
    /// fail its `try`-lock, drop the frame and use no engine object; once the stop is done it may schedule
    /// again only if the engine runs.
    func test_pumpDuringAQueuedStop_dropsTheFrame_withoutTouchingTheEngine() {
        let queue = makeQueue()
        let lock = NSRecursiveLock()
        let inStop = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let engineTouches = NSLock()
        var touches = 0
        var engineRunning = true

        queue.submitStop {
            lock.lock()
            defer { lock.unlock() }
            engineRunning = false  // not running first, as the real stop does
            inStop.signal()
            _ = release.wait(timeout: .now() + 5)  // the slow part of the teardown
        }
        XCTAssertEqual(inStop.wait(timeout: .now() + 5), .success)

        // The playout path, on this (non-owner) thread, while the stop runs.
        let gotLock = lock.`try`()
        if gotLock { lock.unlock() }
        let decision = PlayoutEngineAccess.decision(
            lockAcquired: gotLock, isRunning: false, hasPlayerAndEngine: true, engineRunning: true)
        if decision == .schedule {
            engineTouches.lock(); touches += 1; engineTouches.unlock()
        }
        XCTAssertFalse(gotLock)
        XCTAssertEqual(decision, .drop)
        XCTAssertEqual(touches, 0, "the engine must not be touched while the queue holds it")

        release.signal()
        queue.waitUntilIdle()
        let after = lock.`try`()
        if after { lock.unlock() }
        XCTAssertTrue(after)
        XCTAssertFalse(engineRunning)
        XCTAssertEqual(
            PlayoutEngineAccess.decision(lockAcquired: after, isRunning: false, hasPlayerAndEngine: false, engineRunning: false),
            .drop)
    }

    // MARK: - the queue

    func test_isOnQueue() {
        let queue = makeQueue()
        XCTAssertFalse(queue.isOnQueue)
        let inside = expectation(description: "inside")
        var onQueue = false
        queue.submit {
            onQueue = queue.isOnQueue
            inside.fulfill()
        }
        wait(for: [inside], timeout: 5)
        XCTAssertTrue(onQueue)
    }

    /// A route restart queued while a stop is running runs after it, on the queue, and finds the engine down.
    func test_routeRestartDuringAQueuedStop_isSerialized() {
        let queue = makeQueue()
        let inStop = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let log = NSLock()
        var events: [String] = []
        var running = true
        func note(_ e: String) { log.lock(); events.append(e); log.unlock() }

        queue.submitStop {
            running = false
            note("stop-begin")
            inStop.signal()
            _ = release.wait(timeout: .now() + 5)
            note("stop-end")
        }
        XCTAssertEqual(inStop.wait(timeout: .now() + 5), .success)
        // The route change handler of the capture: an ordinary queued operation.
        queue.submit {
            note(running ? "restart-ran" : "restart-skipped-notRunning")
        }
        release.signal()
        queue.waitUntilIdle()

        XCTAssertEqual(events, ["stop-begin", "stop-end", "restart-skipped-notRunning"])
    }

    // MARK: - callKitFreeMode, back-to-back calls

    func test_stopOfAnEarlierCall_doesNotDeactivateTheNewSession() {
        // Same capture serial: the call that ended deactivates the session (CallKit-free mode).
        XCTAssertTrue(CaptureStopPolicy.shouldDeactivateSession(requested: true, submittedGeneration: 1, currentGeneration: 1))
        // A newer capture was created before the queued stop ran: the new call's session stays.
        XCTAssertFalse(CaptureStopPolicy.shouldDeactivateSession(requested: true, submittedGeneration: 1, currentGeneration: 2))
        XCTAssertFalse(CaptureStopPolicy.shouldDeactivateSession(requested: false, submittedGeneration: 1, currentGeneration: 1))
    }

    /// Through the queue: the stop is queued for call 1, the new call's setup runs on main before it, and the
    /// stop closure decides at run time.
    func test_backToBackCalls_throughTheQueue() {
        let queue = makeQueue()
        let lock = NSLock()
        var serial = 1
        var sessionActive = true
        let submitted = serial
        let inFlight = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.submit {  // something slow ahead of the stop
            inFlight.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(inFlight.wait(timeout: .now() + 5), .success)
        queue.submitStop {
            lock.lock()
            let current = serial
            lock.unlock()
            if CaptureStopPolicy.shouldDeactivateSession(requested: true, submittedGeneration: submitted, currentGeneration: current) {
                sessionActive = false
            }
        }
        // The new call is set up (its capture exists, its session configured) before the stop runs.
        lock.lock(); serial = 2; lock.unlock()
        release.signal()
        queue.waitUntilIdle()
        XCTAssertTrue(sessionActive, "the stop of the earlier call must not deactivate the new session")
    }

    // MARK: - skipped engage

    func test_skipPolicy() {
        typealias Policy = FallbackEngageSkipPolicy
        XCTAssertEqual(Policy.action(stillCurrent: false, requeuesSoFar: 0), .drop)
        XCTAssertEqual(Policy.action(stillCurrent: true, requeuesSoFar: 0), .requeue)
        XCTAssertEqual(Policy.action(stillCurrent: true, requeuesSoFar: Policy.maxRequeues - 1), .requeue)
        XCTAssertEqual(Policy.action(stillCurrent: true, requeuesSoFar: Policy.maxRequeues), .handBack)
    }

    /// A stop that is not tied to the call bumps the epoch before the engage runs: the engage is skipped,
    /// then queued again and runs; it is not left half done.
    func test_skippedEngage_isRequeued_andRuns() {
        let queue = makeQueue()
        let log = NSLock()
        var events: [String] = []
        func note(_ e: String) { log.lock(); events.append(e); log.unlock() }

        func queueEngage(requeues: Int) {
            queue.submitStart(epoch: queue.currentEpoch, work: {
                note("unit-off")
            }, skipped: {
                note("skipped")
                switch FallbackEngageSkipPolicy.action(stillCurrent: true, requeuesSoFar: requeues) {
                case .requeue: queueEngage(requeues: requeues + 1)
                case .handBack: note("hand-back")
                case .drop: break
                }
            })
        }

        let epoch = queue.currentEpoch
        // The engage is queued with this epoch; an unrelated stop bumps it before the engage runs.
        queue.submitStop { note("unrelated-stop") }
        queue.submitStart(epoch: epoch, work: { note("unit-off") }, skipped: {
            note("skipped")
            queueEngage(requeues: 1)
        })
        // Let the first skip and its requeue play out.
        queue.waitUntilIdle()
        queue.waitUntilIdle()

        XCTAssertEqual(events, ["unrelated-stop", "skipped", "unit-off"])
    }
}
