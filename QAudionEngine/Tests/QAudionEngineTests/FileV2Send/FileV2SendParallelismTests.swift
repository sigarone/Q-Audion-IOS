import XCTest
@testable import QAudionEngine

/// Parallel parts (WIRE_SPEC 12.10): the number of workers follows the adaptive rule and the memory budget, a failure halves it, a part that
/// stops moving is timed out on idleness and one that keeps moving is not.
final class FileV2SendParallelismTests: XCTestCase {

    /// Seven or eight parts: enough for the parallelism to show.
    private let manyParts: UInt64 = 6 * UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 5

    func testNoMoreWorkersThanTheMemoryBudgetAllowsAndTheHeldBytesStayInsideIt() async throws {
        let rig = try SendRig(self)
        rig.configuration.availableMemoryMiB = 150                                      // a sixth of it: 25 MiB, room for two workers
        let budget = try FileV2MemBudget(memoryMiB: 150, perWorkerExtraBytes: FileV2SendContext.perWorkerExtraBytes)
        XCTAssertEqual(budget.maxParallelism, 2)
        rig.fake.injectDelay(.putPart, ms: 30)                                          // real time: the parts overlap
        let source = GeneratedSource(size: manyParts)
        let pipeline = try rig.makePipeline()
        let result = await pipeline.send(rig.makeRequest(source, id: "small-memory"))
        XCTAssertEqual(result, .sentOk)

        let diagnostics = pipeline.diagnostics
        XCTAssertLessThanOrEqual(diagnostics.peakConcurrentParts, budget.maxParallelism, "never more parts held than the budget has room for")
        XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, budget.budgetBytes, "the held bytes stay inside the budget")
        XCTAssertEqual(diagnostics.peakConcurrentParts, 2, "and the room is used")
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    func testAMemoryBudgetOfOneWorkerSendsOnePartAtATime() async throws {
        let rig = try SendRig(self)
        rig.configuration.availableMemoryMiB = 60
        rig.fake.injectDelay(.putPart, ms: 20)
        let source = GeneratedSource(size: 3 * UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 1)
        let pipeline = try rig.makePipeline()
        let result = await pipeline.send(rig.makeRequest(source, id: "one-worker"))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(pipeline.diagnostics.peakConcurrentParts, 1)
    }

    func testWithTheProductionBudgetSeveralPartsAreInFlightAndTheBudgetHolds() async throws {
        let rig = try SendRig(self)
        rig.fake.injectDelay(.putPart, ms: 30)
        let source = GeneratedSource(size: manyParts)
        let pipeline = try rig.makePipeline()
        let result = await pipeline.send(rig.makeRequest(source, id: "production-budget"))
        XCTAssertEqual(result, .sentOk)
        let budget = try FileV2MemBudget(memoryMiB: rig.configuration.availableMemoryMiB,
                                         perWorkerExtraBytes: FileV2SendContext.perWorkerExtraBytes)
        let diagnostics = pipeline.diagnostics
        XCTAssertEqual(budget.maxParallelism, 4, "6 x part size, two chunks extra for each worker")
        XCTAssertGreaterThanOrEqual(diagnostics.peakConcurrentParts, 3)
        XCTAssertLessThanOrEqual(diagnostics.peakConcurrentParts, budget.maxParallelism)
        XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, budget.budgetBytes)
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .putPart }.count, SendTestSizes.parts(ofSize: manyParts))
    }

    func testTheServersOwnLimitOfPartsInFlightIsRespected() async throws {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 2                                                   // max_parallelism in the answer of create: 2
        rig.fake.injectDelay(.putPart, ms: 30)
        let pipeline = try rig.makePipeline()
        let result = await pipeline.send(rig.makeRequest(GeneratedSource(size: manyParts), id: "server-limit"))
        XCTAssertEqual(result, .sentOk)
        XCTAssertLessThanOrEqual(pipeline.diagnostics.peakConcurrentParts, 2)
    }

    func testAMeteredNetworkUsesAtMostThreeParts() async throws {
        let rig = try SendRig(self)
        rig.configuration.metered = true
        rig.fake.injectDelay(.putPart, ms: 30)
        let pipeline = try rig.makePipeline()
        let result = await pipeline.send(rig.makeRequest(GeneratedSource(size: manyParts), id: "metered"))
        XCTAssertEqual(result, .sentOk)
        XCTAssertLessThanOrEqual(pipeline.diagnostics.peakConcurrentParts, FileV2AdaptiveParallelism.meteredCeiling)
    }

    func testFailuresHalveTheParallelismAndTheTransferStillCompletes() async throws {
        let rig = try SendRig(self)
        rig.fake.injectDelay(.putPart, ms: 30)
        // Every one of the first four parts fails once with a 503 while they are in flight together.
        for part in 0..<4 {
            rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 1, part: part)
        }
        let source = GeneratedSource(size: manyParts)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "failures"))
        XCTAssertEqual(result, .sentOk)
        let changes = rig.telemetry.events.compactMap { event -> (Int, Int)? in
            if case .parallelismChanged(let from, let to) = event { return (from, to) }
            return nil
        }
        XCTAssertTrue(changes.contains { $0.1 < $0.0 }, "the parallelism fell on failures: \(changes)")
        XCTAssertEqual(rig.telemetry.count { $0 == .retried }, 4)
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    // MARK: Progress-based timeouts

    func testThePartTimeoutOfProductionAllowsTheSlowestPartTheServerAccepts() {
        let configuration = FileV2SendConfiguration()
        XCTAssertEqual(FileV2PartTimeout.slowestLegitimateSeconds, 1049, "8 MiB at 8000 bytes per second")
        XCTAssertGreaterThanOrEqual(configuration.partTotalTimeoutMs, Int64(FileV2PartTimeout.slowestLegitimateSeconds) * 1000,
                                    "a server that cannot report progress gets a total deadline longer than the slowest legitimate part")
        XCTAssertLessThan(configuration.partIdleTimeoutMs, configuration.partTotalTimeoutMs, "and an idle limit is much shorter")
    }

    func testAPartThatStopsMovingIsTimedOutAndSentAgainWithTheSameBytes() async throws {
        let rig = try SendRig(self, reporting: true)
        rig.fake.maxPartsInFlight = 1
        rig.configuration.partIdleTimeoutMs = 60_000
        let reporting = try XCTUnwrap(rig.server as? ReportingServer)
        reporting.stall(part: 1, times: 1)                                              // part 1: no byte moves, ten minutes pass
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "stalls"))
        XCTAssertEqual(result, .sentOk)
        XCTAssertTrue(rig.log.events.contains("server.put.stall part=1"))
        XCTAssertEqual(rig.telemetry.count { $0 == .retried }, 1, "one timeout, one retry")
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    /// A reporting server that takes a quarter of an hour over part 1, moving all the time.
    private final class Crawling: FileV2PartProgressReporting, @unchecked Sendable {
        let inner: ReportingServer
        let clock: XferManualClock

        init(inner: ReportingServer, clock: XferManualClock) {
            self.inner = inner
            self.clock = clock
        }

        func putPart(obj: String, part: Int, body: Data, sha256: Data, progress: @escaping @Sendable (Int) -> Void) async throws -> FileV2PutResult {
            if part == 1 {
                // 30 steps of 50 virtual seconds (25 minutes in all, over the slowest legitimate part) with bytes moving at each one: the
                // idle limit of 90 seconds is never reached, so a total timeout would have cut this and the idle one does not.
                for _ in 0..<30 {
                    progress(1000)
                    clock.advance(ms: 50_000)
                    try await Task.sleep(nanoseconds: 8_000_000)                       // real time for the watchdog to look
                }
            }
            return try await inner.putPart(obj: obj, part: part, body: body, sha256: sha256, progress: progress)
        }

        func create(_ request: FileV2CreateRequest) async throws -> FileV2Created { try await inner.create(request) }
        func putPart(obj: String, part: Int, body: Data, sha256: Data) async throws -> FileV2PutResult {
            try await inner.putPart(obj: obj, part: part, body: body, sha256: sha256)
        }
        func partsMap(obj: String) async throws -> FileV2PartsMap { try await inner.partsMap(obj: obj) }
        func complete(obj: String) async throws { try await inner.complete(obj: obj) }
        func delete(obj: String) async throws { try await inner.delete(obj: obj) }
        func issueToken(obj: String, scope: FileV2TokenRequest) async throws -> FileV2IssuedToken {
            try await inner.issueToken(obj: obj, scope: scope)
        }
        func listUnfinished(limit: Int?, after: String?) async throws -> FileV2UnfinishedPage {
            try await inner.listUnfinished(limit: limit, after: after)
        }
        func deleteUnfinished() async throws -> FileV2BulkDeleteResult { try await inner.deleteUnfinished() }
        func fetchRange(obj: String, from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?, waitSeconds: Int) async throws
            -> FileV2RangeResult {
            try await inner.fetchRange(obj: obj, from: from, toInclusive: toInclusive, token: token, waitSeconds: waitSeconds)
        }
    }

    func testASlowPartThatKeepsMovingIsNotTimedOutWhateverItsTotalTime() async throws {
        let rig = try SendRig(self, reporting: true)
        rig.fake.maxPartsInFlight = 1
        rig.configuration.partIdleTimeoutMs = 90_000
        let reporting = try XCTUnwrap(rig.server as? ReportingServer)
        let crawling = Crawling(inner: reporting, clock: rig.clock)
        let deps = FileV2SendDependencies(server: crawling, store: try rig.makeStore(), secrets: rig.wrapper, sources: rig.sources,
                                          channel: rig.channel, clock: rig.clock, sleeper: rig.sleeper, telemetry: rig.telemetry)
        let pipeline = FileV2SendPipeline(dependencies: deps, configuration: rig.configuration)
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let result = await pipeline.send(rig.makeRequest(source, id: "crawls"))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(rig.telemetry.count { $0 == .retried }, 0, "25 virtual minutes of steady progress is not a timeout")
        XCTAssertEqual(rig.server.puts.count, 3, "no part was sent twice")
    }

    func testAServerThatCannotReportProgressGetsATotalDeadlineAndAStalledPartIsRetried() async throws {
        let rig = try SendRig(self)                                                      // a plain recorder: no progress reports
        rig.fake.maxPartsInFlight = 1
        rig.configuration.partTotalTimeoutMs = 120_000
        // Part 1 hangs for ever; ten virtual minutes pass (the hook is the "network" taking its time), then the deadline cuts it.
        let hung = FileV2Locked(false)
        rig.server.setHook { [rig] op, call in
            if op == .putPart && call == 1 && !hung.withValue({ $0 }) {
                hung.withValue { $0 = true }
                rig.clock.advance(ms: 10 * 60_000)
            }
        }
        rig.fake.injectDelay(.putPart, ms: 400, part: 1)                                // real 400 ms: long enough for the watchdog's first look
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "total-deadline"))
        XCTAssertEqual(result, .sentOk)
        XCTAssertGreaterThanOrEqual(rig.telemetry.count { $0 == .retried }, 1)
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
    }
}
