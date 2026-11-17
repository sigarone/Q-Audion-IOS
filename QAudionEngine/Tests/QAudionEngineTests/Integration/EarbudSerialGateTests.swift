import XCTest
@testable import QAudionEngine

/// `EarbudSerialGate`: the operations of the one CoreBluetooth earbud client run one at a time, in order.
final class EarbudSerialGateTests: XCTestCase {

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxActive = 0
        private(set) var order: [Int] = []
        func enter(_ id: Int) {
            lock.lock(); active += 1; maxActive = max(maxActive, active); order.append(id); lock.unlock()
        }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
    }

    private enum Boom: Error { case boom }

    func testBodiesNeverOverlap() async {
        let gate = EarbudSerialGate()
        let tally = Tally()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<24 {
                group.addTask {
                    _ = try? await gate.run {
                        tally.enter(i)
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        tally.leave()
                    }
                }
            }
        }
        XCTAssertEqual(tally.maxActive, 1, "two operations on the one write/read continuation would leak one of them")
        XCTAssertEqual(Set(tally.order), Set(0..<24), "every body ran")
    }

    func testBodiesRunInTheOrderTheyAsked() async {
        let gate = EarbudSerialGate()
        let tally = Tally()
        let hold = Task {
            _ = try? await gate.run {
                tally.enter(0)
                try? await Task.sleep(nanoseconds: 300_000_000)
                tally.leave()
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)   // 0 holds the gate
        var tasks: [Task<Void, Never>] = [hold]
        for i in 1...4 {
            tasks.append(Task {
                _ = try? await gate.run {
                    tally.enter(i)
                    tally.leave()
                }
            })
            try? await Task.sleep(nanoseconds: 30_000_000)   // 1, 2, 3, 4 queue up in this order
        }
        for t in tasks { await t.value }
        XCTAssertEqual(tally.order, [0, 1, 2, 3, 4])
    }

    func testTheValueOfTheBodyIsReturned() async throws {
        let gate = EarbudSerialGate()
        let v: Int = try await gate.run { 41 + 1 }
        XCTAssertEqual(v, 42)
    }

    func testAThrowingBodyReleasesTheGate() async {
        let gate = EarbudSerialGate()
        do {
            try await gate.run { throw Boom.boom }
            XCTFail("the error must propagate")
        } catch {
            XCTAssertEqual(error as? Boom, Boom.boom)
        }
        let ran = try? await gate.run { true }
        XCTAssertEqual(ran, true, "the next operation is not locked out by the failed one")
    }

    // MARK: - Cancellation (a timed-out caller must not run later)

    /// A flag a test sets from outside; the holder of the gate spins on it.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Takes the gate and keeps it until `release` is set. Returns once the gate is really held.
    private func hold(_ gate: EarbudSerialGate, until release: Flag) async -> Task<Void, Never> {
        let held = Flag()
        let task = Task {
            _ = try? await gate.run {
                held.set()
                while !release.isSet { try? await Task.sleep(nanoseconds: 2_000_000) }
            }
        }
        for _ in 0..<2000 where !held.isSet { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(held.isSet, "the holder took the gate")
        return task
    }

    /// Reproduces the pairing bug: the relay's PAIR_FIN timeout cancels the write while an earlier operation holds
    /// the gate. The old gate kept the cancelled caller in line, so the write ran the moment the gate freed.
    func testACancelledWaiterLeavesTheQueueAndItsBodyNeverRuns() async {
        let gate = EarbudSerialGate()
        let release = Flag()
        let holder = await hold(gate, until: release)

        let ran = Flag()
        let outcome = Flag()   // set when the waiter's `run` has returned
        let waiter = Task { () -> Bool in
            defer { outcome.set() }
            do {
                try await gate.run { ran.set() }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)   // it is queued behind the holder
        waiter.cancel()
        for _ in 0..<2000 where !outcome.isSet { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(outcome.isSet, "a cancelled waiter returns at once, it does not wait for the holder")
        XCTAssertFalse(release.isSet, "(the holder still has the gate)")
        release.set()   // a gate that kept the cancelled waiter in line is freed only here, so this test cannot hang
        let threwCancellation = await waiter.value
        XCTAssertTrue(threwCancellation, "run throws CancellationError")
        await holder.value
        let afterwards = try? await gate.run { 7 }
        XCTAssertEqual(afterwards, 7, "the gate is free and not blocked by the departed waiter")
        XCTAssertFalse(ran.isSet, "the body of a cancelled waiter must never run: it would write PAIR_FIN after the pairing was reported failed")
    }

    func testACancelledWaiterDoesNotHoldBackTheOnesBehindIt() async {
        let gate = EarbudSerialGate()
        let release = Flag()
        let holder = await hold(gate, until: release)
        let tally = Tally()

        var tasks: [Task<Void, Never>] = []
        for i in 1...3 {
            tasks.append(Task {
                _ = try? await gate.run { tally.enter(i); tally.leave() }
            })
            try? await Task.sleep(nanoseconds: 30_000_000)   // 1, 2, 3 queue up in this order
        }
        tasks[1].cancel()   // 2 gives up while it waits
        try? await Task.sleep(nanoseconds: 30_000_000)
        release.set()
        await holder.value
        for t in tasks { await t.value }
        XCTAssertEqual(tally.order, [1, 3], "2 never ran, 1 and 3 ran in their order")
    }

    func testATaskCancelledBeforeItAsksNeverRunsEvenOnAFreeGate() async {
        let gate = EarbudSerialGate()
        let ran = Flag()
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do {
                try await gate.run { ran.set() }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await Task.yield()
        task.cancel()
        let threw = await task.value
        XCTAssertTrue(threw)
        XCTAssertFalse(ran.isSet)
        let next = try? await gate.run { 1 }
        XCTAssertEqual(next, 1, "the cancelled caller left the gate free")
    }

    func testABodyThatIsAlreadyRunningIsNotInterruptedByTheCancellation() async {
        let gate = EarbudSerialGate()
        let started = Flag()
        let release = Flag()
        let task = Task { () -> Int? in
            return try? await gate.run { () -> Int in
                started.set()
                while !release.isSet { try? await Task.sleep(nanoseconds: 2_000_000) }
                return 5
            }
        }
        for _ in 0..<2000 where !started.isSet { try? await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        release.set()
        let value = await task.value
        XCTAssertEqual(value, 5, "once it has the gate, a body finishes; reacting to cancellation is its own business")
        let next = try? await gate.run { 1 }
        XCTAssertEqual(next, 1)
    }
}
