import XCTest
@testable import QAudionEngine

/// Thread-safe recorder for the async tests below.
final class AsyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) {
        lock.lock(); values.append(value); lock.unlock()
    }
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

final class GroupSerialQueueTests: XCTestCase {

    func testOperationsRunFirstInFirstOutAndNeverOverlap() async {
        let queue = GroupSerialQueue(debounceMs: 5)
        let recorder = AsyncRecorder()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                // Submitted in order: each `run` call is enqueued before the next task starts.
                group.addTask {
                    await queue.run {
                        recorder.add("start\(index)")
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        recorder.add("end\(index)")
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let maxConcurrent = await queue.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1, "never two renegotiations in flight")
        // Every start is immediately followed by its own end.
        let log = recorder.all
        XCTAssertEqual(log.count, 16)
        for index in stride(from: 0, to: log.count, by: 2) {
            XCTAssertTrue(log[index].hasPrefix("start"))
            XCTAssertEqual(String(log[index].dropFirst("start".count)), String(log[index + 1].dropFirst("end".count)))
        }
    }

    func testRunReturnsTheValueAndPropagatesErrors() async throws {
        struct Boom: Error {}
        let queue = GroupSerialQueue(debounceMs: 5)
        let value = await queue.run { 42 }
        XCTAssertEqual(value, 42)
        do {
            try await queue.run { () async throws -> Void in throw Boom() }
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        // The failed operation released the baton.
        let after = await queue.run { "still works" }
        XCTAssertEqual(after, "still works")
    }

    func testDebounceRunsOnlyTheLastOperationOfABurst() async {
        let queue = GroupSerialQueue(debounceMs: 40)
        let recorder = AsyncRecorder()
        for index in 0..<5 {
            await queue.debounce(key: "reconcile") { recorder.add("op\(index)") }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(recorder.all, ["op4"])
    }

    func testDebounceKeysAreIndependent() async {
        let queue = GroupSerialQueue(debounceMs: 20)
        let recorder = AsyncRecorder()
        await queue.debounce(key: "a") { recorder.add("a") }
        await queue.debounce(key: "b") { recorder.add("b") }
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(Set(recorder.all), ["a", "b"])
        let maxConcurrent = await queue.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testADebouncedOperationRunsThroughTheSameFifoAsRun() async {
        let queue = GroupSerialQueue(debounceMs: 10)
        let recorder = AsyncRecorder()
        await queue.debounce(key: "slow") {
            recorder.add("debounced-start")
            try? await Task.sleep(nanoseconds: 60_000_000)
            recorder.add("debounced-end")
        }
        try? await Task.sleep(nanoseconds: 30_000_000)             // the debounced op is running now
        await queue.run { recorder.add("run") }
        XCTAssertEqual(recorder.all, ["debounced-start", "debounced-end", "run"])
    }

    func testCancelPendingDropsScheduledOperations() async {
        let queue = GroupSerialQueue(debounceMs: 60)
        let recorder = AsyncRecorder()
        await queue.debounce(key: "x") { recorder.add("never") }
        await queue.cancelPending()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(recorder.all.isEmpty)
    }
}
