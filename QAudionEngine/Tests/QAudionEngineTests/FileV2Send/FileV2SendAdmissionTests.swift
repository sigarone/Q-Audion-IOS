import XCTest
@testable import QAudionEngine

/// The memory budget belongs to the PIPELINE: every transfer it runs shares the same slots, so ten files sent at once hold what one does.
final class FileV2SendAdmissionTests: XCTestCase {

    /// Seven or eight parts: enough for the parallelism to show.
    private let manyParts: UInt64 = 6 * UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 5

    func testTwoTransfersOfOnePipelineShareTheMemoryBudgetOfTheDevice() async throws {
        let rig = try SendRig(self)
        rig.configuration.availableMemoryMiB = 150                                      // a sixth of it: 25 MiB, room for two parts
        let budget = try FileV2MemBudget(memoryMiB: 150, perWorkerExtraBytes: FileV2SendContext.perWorkerExtraBytes)
        XCTAssertEqual(budget.maxParallelism, 2)
        rig.fake.injectDelay(.putPart, ms: 30)                                          // real time: the parts overlap
        let pipeline = try rig.makePipeline()
        let requestOne = rig.makeRequest(GeneratedSource(size: manyParts), id: "memory-one")
        let requestTwo = rig.makeRequest(GeneratedSource(size: manyParts), id: "memory-two")

        async let one = pipeline.send(requestOne)
        async let two = pipeline.send(requestTwo)
        let (resultOne, resultTwo) = await (one, two)
        XCTAssertEqual(resultOne, .sentOk)
        XCTAssertEqual(resultTwo, .sentOk)

        let diagnostics = pipeline.diagnostics
        XCTAssertLessThanOrEqual(diagnostics.peakConcurrentParts, budget.maxParallelism, "never more parts held than the budget has room for, whatever the number of transfers")
        XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, budget.budgetBytes, "the held bytes of BOTH transfers stay inside one budget")
        XCTAssertEqual(diagnostics.peakConcurrentParts, 2, "and the room is used")
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .putPart }.count, 2 * SendTestSizes.parts(ofSize: manyParts))
        try rig.assertNothingIsLeftBehind()
    }

    func testManyTransfersTogetherStillHoldNoMoreThanOne() async throws {
        let rig = try SendRig(self)
        rig.configuration.availableMemoryMiB = 60                                       // room for one part
        rig.fake.injectDelay(.putPart, ms: 15)
        let pipeline = try rig.makePipeline()
        let size = 3 * UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 1
        let requests = (0..<4).map { rig.makeRequest(GeneratedSource(size: size), id: "many-\($0)") }
        let results = await withTaskGroup(of: FileV2SendState.self) { group -> [FileV2SendState] in
            for request in requests { group.addTask { await pipeline.send(request) } }
            var all: [FileV2SendState] = []
            for await result in group { all.append(result) }
            return all
        }
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.allSatisfy { $0 == .sentOk }, "\(results)")
        XCTAssertEqual(pipeline.diagnostics.peakConcurrentParts, 1)
    }

    func testATransferThatWaitsForASlotCanBeCancelledAndTheSlotIsNotLost() async throws {
        let rig = try SendRig(self)
        rig.configuration.availableMemoryMiB = 60                                       // one slot
        rig.fake.injectDelay(.putPart, ms: 150)
        let pipeline = try rig.makePipeline()
        let holder = rig.makeRequest(GeneratedSource(size: manyParts), id: "holder")
        let waiter = rig.makeRequest(GeneratedSource(size: manyParts), id: "waiter")
        let holding = Task { await pipeline.send(holder) }
        try await pollUntilTrue { rig.server.puts.count >= 1 }
        let waiting = Task { await pipeline.send(waiter) }
        try await Task.sleep(nanoseconds: 100_000_000)                                  // the waiter is queued for the only slot
        let cancelled = await pipeline.cancelTransfer(transferID: "waiter")
        XCTAssertEqual(cancelled, .cancelled)
        let waiterResult = await waiting.value
        XCTAssertEqual(waiterResult, .failed(FileV2SendFailure(.cancelled)))

        rig.fake.clearDelays()
        let holderResult = await holding.value
        XCTAssertEqual(holderResult, .sentOk, "the holder was not disturbed")
        // The slot is free again: a new transfer goes through.
        let after = await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_000), id: "after"))
        XCTAssertEqual(after, .sentOk)
        XCTAssertEqual(pipeline.diagnostics.peakConcurrentParts, 1)
        try rig.assertNothingIsLeftBehind()
    }
}

final class FileV2AsyncSemaphoreTests: XCTestCase {

    func testNeverMoreHoldersThanSlotsAndEveryoneGetsThrough() async throws {
        let semaphore = FileV2AsyncSemaphore(slots: 2)
        let state = FileV2Locked((inside: 0, peak: 0, done: 0))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await semaphore.withSlot {
                        state.withValue {
                            $0.inside += 1
                            $0.peak = max($0.peak, $0.inside)
                        }
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        state.withValue {
                            $0.inside -= 1
                            $0.done += 1
                        }
                    }
                }
            }
        }
        let seen = state.withValue { $0 }
        XCTAssertEqual(seen.done, 8)
        XCTAssertEqual(seen.peak, 2, "the two slots were both used and never exceeded")
        XCTAssertEqual(seen.inside, 0)
    }

    func testWaitersAreServedInTheOrderTheyCame() async throws {
        let semaphore = FileV2AsyncSemaphore(slots: 1)
        let order = FileV2Locked<[Int]>([])
        let holder = Task { try await semaphore.withSlot { try await Task.sleep(nanoseconds: 150_000_000) } }
        try await Task.sleep(nanoseconds: 30_000_000)
        var waiters: [Task<Void, Error>] = []
        for index in 0..<4 {
            waiters.append(Task { try await semaphore.withSlot { order.withValue { $0.append(index) } } })
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try await holder.value
        for waiter in waiters { try await waiter.value }
        XCTAssertEqual(order.withValue { $0 }, [0, 1, 2, 3])
    }

    func testAWaiterThatIsCancelledLeavesTheQueueAndNoSlotIsLost() async throws {
        let semaphore = FileV2AsyncSemaphore(slots: 1)
        let entered = FileV2Locked(0)
        let holder = Task { try await semaphore.withSlot { try await Task.sleep(nanoseconds: 200_000_000) } }
        try await Task.sleep(nanoseconds: 30_000_000)
        let doomed = Task { try await semaphore.withSlot { entered.withValue { $0 += 1 } } }
        try await Task.sleep(nanoseconds: 30_000_000)
        doomed.cancel()
        do {
            try await doomed.value
            XCTFail("a cancelled waiter must throw")
        } catch is CancellationError {
        }
        XCTAssertEqual(entered.withValue { $0 }, 0, "it never held the slot")
        try await holder.value
        // The slot is back: the next caller gets it at once.
        let next = Task { try await semaphore.withSlot { entered.withValue { $0 += 1 } } }
        try await next.value
        XCTAssertEqual(entered.withValue { $0 }, 1)
    }

    func testASlotIsGivenBackWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let semaphore = FileV2AsyncSemaphore(slots: 1)
        do {
            try await semaphore.withSlot { throw Boom() }
            XCTFail("the body threw")
        } catch is Boom {
        }
        let again = try await semaphore.withSlot { 42 }
        XCTAssertEqual(again, 42)
    }
}
