import XCTest
@testable import QAudionEngine

/// The audio queue of a call: a stop never overlaps a start that is running, a start that has not
/// begun when a stop (or the end of the call) is submitted does not run, and nothing is left
/// running at the end.
final class AudioEngineSerialQueueTests: XCTestCase {

    /// A stand-in for the engine: records the order of operations, the most operations ever active
    /// at once, and whether it is "running".
    private final class FakeEngine: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private var isRunning = false
        private var peakActive = 0
        private var active = 0

        var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
        var running: Bool { lock.lock(); defer { lock.unlock() }; return isRunning }
        var maxActive: Int { lock.lock(); defer { lock.unlock() }; return peakActive }

        func begin(_ name: String) {
            lock.lock()
            active += 1
            peakActive = max(peakActive, active)
            recorded.append("\(name)-begin")
            lock.unlock()
        }

        func end(_ name: String, running newState: Bool? = nil) {
            lock.lock()
            active -= 1
            if let newState { isRunning = newState }
            recorded.append("\(name)-end")
            lock.unlock()
        }

        func note(_ name: String) {
            lock.lock()
            recorded.append(name)
            lock.unlock()
        }
    }

    private func makeQueue() -> AudioEngineSerialQueue {
        AudioEngineSerialQueue(label: "test.audioengine.\(UUID().uuidString)")
    }

    /// Engage, then a disengage while the start is still running, then the end of the call.
    func test_disengageDuringStart_waitsForIt_andNothingIsLeftRunning() {
        let queue = makeQueue()
        let engine = FakeEngine()
        let inStart = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let engageEpoch = queue.currentEpoch
        queue.submitStart(epoch: engageEpoch, work: {
            engine.begin("start")
            inStart.signal()
            _ = release.wait(timeout: .now() + 5)
            engine.end("start", running: true)
        }, skipped: { engine.note("start-skipped") })
        XCTAssertEqual(inStart.wait(timeout: .now() + 5), .success)

        // Disengage while the start is running.
        queue.submitStop {
            engine.begin("stop")
            engine.end("stop", running: false)
        }
        // A retry of the start submitted before the disengage was seen is now stale.
        queue.submitStart(epoch: engageEpoch, work: {
            engine.begin("start2")
            engine.end("start2", running: true)
        }, skipped: { engine.note("start2-skipped") })
        // End of the call.
        queue.submitStop {
            engine.begin("end-of-call-stop")
            engine.end("end-of-call-stop", running: false)
        }

        release.signal()
        queue.waitUntilIdle()

        XCTAssertEqual(engine.events, [
            "start-begin", "start-end",
            "stop-begin", "stop-end",
            "start2-skipped",
            "end-of-call-stop-begin", "end-of-call-stop-end",
        ])
        XCTAssertEqual(engine.maxActive, 1, "operations must never overlap")
        XCTAssertFalse(engine.running, "no engine left running after the call ends")
    }

    /// An engage after the disengage (a fresh epoch) runs; the end of the call still wins at the end.
    func test_reEngageAfterDisengage_runs_thenEndOfCallStopsIt() {
        let queue = makeQueue()
        let engine = FakeEngine()

        queue.submitStop {
            engine.begin("disengage")
            engine.end("disengage", running: false)
        }
        let freshEpoch = queue.currentEpoch
        queue.submitStart(epoch: freshEpoch, work: {
            engine.begin("start")
            engine.end("start", running: true)
        })
        queue.submitStop {
            engine.begin("end-of-call-stop")
            engine.end("end-of-call-stop", running: false)
        }
        queue.waitUntilIdle()

        XCTAssertEqual(engine.events, [
            "disengage-begin", "disengage-end",
            "start-begin", "start-end",
            "end-of-call-stop-begin", "end-of-call-stop-end",
        ])
        XCTAssertFalse(engine.running)
        XCTAssertEqual(engine.maxActive, 1)
    }

    func test_invalidatePendingStarts_skipsStartsNotYetBegun() {
        let queue = makeQueue()
        let engine = FakeEngine()
        let inFirst = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let epoch = queue.currentEpoch

        queue.submitStart(epoch: epoch, work: {
            inFirst.signal()
            _ = release.wait(timeout: .now() + 5)
            engine.note("first")
        })
        XCTAssertEqual(inFirst.wait(timeout: .now() + 5), .success)
        queue.submitStart(epoch: epoch, work: { engine.note("second") }, skipped: { engine.note("second-skipped") })
        let newEpoch = queue.invalidatePendingStarts()
        XCTAssertEqual(newEpoch, epoch + 1)
        release.signal()
        queue.waitUntilIdle()

        XCTAssertEqual(engine.events, ["first", "second-skipped"])
    }

    /// Starts and stops submitted from several threads at once: still one at a time.
    func test_manySubmitters_neverOverlap() {
        let queue = makeQueue()
        let engine = FakeEngine()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i % 3 == 0 {
                queue.submitStop {
                    engine.begin("stop")
                    engine.end("stop", running: false)
                }
            } else {
                queue.submitStart(epoch: queue.currentEpoch, work: {
                    engine.begin("start")
                    engine.end("start", running: true)
                })
            }
        }
        queue.waitUntilIdle()
        XCTAssertEqual(engine.maxActive, 1)
    }
}
