import XCTest
@testable import QAudionEngine

/// The Tier 1 model is loaded lazily: building the analyzer / guardian costs nothing, the load happens once, at
/// the first `warmUp()` or the first window (whichever comes first), never on the constructing thread, and never
/// twice even when asked concurrently.
final class GuardianLazyModelLoadTests: XCTestCase {

    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        let result: Bool
        let delay: TimeInterval
        init(result: Bool = true, delay: TimeInterval = 0) { self.result = result; self.delay = delay }
        func load() -> Bool {
            lock.lock(); n += 1; lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return result
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeAnalyzer(_ counter: LoadCounter) -> VoiceprintAnalyzer {
        VoiceprintAnalyzer(modelManager: ModelManager(), loadModel: { counter.load() })
    }

    // MARK: - VoiceprintAnalyzer

    func testConstructionLoadsNothing() {
        let counter = LoadCounter()
        let analyzer = makeAnalyzer(counter)
        XCTAssertEqual(counter.count, 0)
        XCTAssertFalse(analyzer.isModelLoaded)
        XCTAssertTrue(analyzer.canScore, "nothing has failed yet")
    }

    func testWarmUpLoadsOnceEvenWhenRepeatedAndFollowedByScore() {
        let counter = LoadCounter()
        let analyzer = makeAnalyzer(counter)
        analyzer.warmUp()
        analyzer.warmUp()
        _ = analyzer.score(window48k: [Float](repeating: 0.1, count: 4800))
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(analyzer.isModelLoaded)
    }

    func testFirstScoreLoadsWhenNoWarmUpHappened() {
        let counter = LoadCounter()
        let analyzer = makeAnalyzer(counter)
        _ = analyzer.score(window48k: [Float](repeating: 0.1, count: 4800))
        _ = analyzer.score(window48k: [Float](repeating: 0.1, count: 4800))
        XCTAssertEqual(counter.count, 1, "the first use loads, later uses reuse")
    }

    func testConcurrentWarmUpAndScoreLoadExactlyOnce() {
        let counter = LoadCounter(delay: 0.05)
        let analyzer = makeAnalyzer(counter)
        let done = expectation(description: "all callers returned")
        done.expectedFulfillmentCount = 16
        for i in 0..<16 {
            DispatchQueue.global().async {
                if i % 2 == 0 { analyzer.warmUp() } else { _ = analyzer.score(window48k: [Float](repeating: 0.1, count: 4800)) }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(counter.count, 1)
    }

    func testPerChunkCheckIsNotBlockedByALoadInProgress() {
        let counter = LoadCounter(delay: 0.5)
        let analyzer = makeAnalyzer(counter)
        let loading = expectation(description: "load started")
        DispatchQueue.global().async {
            analyzer.warmUp()
            loading.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)   // the load is now in progress
        let t0 = Date()
        XCTAssertTrue(analyzer.canScore)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.25, "canScore must not wait for the load")
        wait(for: [loading], timeout: 10)
    }

    func testFailedLoadIsNotRetriedAndStopsPerChunkWork() {
        let counter = LoadCounter(result: false)
        let analyzer = makeAnalyzer(counter)
        XCTAssertNil(analyzer.score(window48k: [Float](repeating: 0.1, count: 4800)))
        XCTAssertNil(analyzer.score(window48k: [Float](repeating: 0.1, count: 4800)))
        analyzer.warmUp()
        XCTAssertEqual(counter.count, 1)
        XCTAssertFalse(analyzer.canScore)
        XCTAssertFalse(analyzer.isModelLoaded)
    }

    // MARK: - GuardianMode

    private final class ManualExecutor: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [@Sendable () -> Void] = []
        func submit(_ job: @escaping @Sendable () -> Void) { lock.lock(); jobs.append(job); lock.unlock() }
        var pending: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }
        func runAll() {
            while true {
                lock.lock()
                guard !jobs.isEmpty else { lock.unlock(); return }
                let job = jobs.removeFirst()
                lock.unlock()
                job()
            }
        }
    }

    private func makeGuardian(
        analyzer: VoiceprintAnalyzer, executor: ManualExecutor, scorerAvailable: Bool = true
    ) -> GuardianMode {
        GuardianMode(
            scorer: { analyzer.score(window48k: $0) },
            scorerAvailable: scorerAvailable,
            scorerStillUsable: { analyzer.canScore },
            warmUpScorer: { analyzer.warmUp() },
            executor: { job in executor.submit(job) },
            nowMs: { 0 }
        )
    }

    func testBuildingTheGuardianRunsNoJobAndLoadsNothing() {
        let counter = LoadCounter()
        let executor = ManualExecutor()
        _ = makeGuardian(analyzer: makeAnalyzer(counter), executor: executor)
        XCTAssertEqual(executor.pending, 0)
        XCTAssertEqual(counter.count, 0)
    }

    func testWarmUpIsHandedToTheInferenceQueueNotRunOnTheCaller() {
        let counter = LoadCounter()
        let executor = ManualExecutor()
        let guardian = makeGuardian(analyzer: makeAnalyzer(counter), executor: executor)
        guardian.warmUp()
        XCTAssertEqual(executor.pending, 1)
        XCTAssertEqual(counter.count, 0, "the caller does not pay for the load")
        executor.runAll()
        XCTAssertEqual(counter.count, 1)
        guardian.warmUp()
        executor.runAll()
        XCTAssertEqual(counter.count, 1, "a second warm-up is a no-op")
    }

    func testWithoutARuntimeWarmUpDoesNothing() {
        let counter = LoadCounter()
        let executor = ManualExecutor()
        let guardian = makeGuardian(analyzer: makeAnalyzer(counter), executor: executor, scorerAvailable: false)
        guardian.warmUp()
        XCTAssertEqual(executor.pending, 0)
        XCTAssertEqual(counter.count, 0)
    }

    /// 4.04 s of voiced audio at 20 ms per chunk: the window completes and its inference is queued whether or
    /// not a warm-up ever ran; the load is paid once, by whichever came first.
    private func feedOneWindow(_ guardian: GuardianMode) {
        var bytes = [UInt8](repeating: 0, count: 960 * 2)
        for i in 0..<960 {
            let v = Int16(i % 2 == 0 ? 3000 : -3000)
            let bits = UInt16(bitPattern: v)
            bytes[2 * i] = UInt8(bits & 0xFF)
            bytes[2 * i + 1] = UInt8(bits >> 8)
        }
        let chunk = Data(bytes)
        for _ in 0..<(GuardianWindowAccumulator.defaultWindowSamples / 960 + 1) { guardian.processFrame(chunk) }
    }

    func testFirstWindowLoadsByItselfWhenNoWarmUpRan() {
        let counter = LoadCounter()
        let executor = ManualExecutor()
        let guardian = makeGuardian(analyzer: makeAnalyzer(counter), executor: executor)
        feedOneWindow(guardian)
        XCTAssertEqual(executor.pending, 1, "the first window's inference is queued")
        XCTAssertEqual(counter.count, 0, "processFrame itself never loads")
        executor.runAll()
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(guardian.tier1Stats.windowsReady, 1)
    }

    func testWarmUpBeforeTheFirstWindowMeansTheInferenceFindsTheModelReady() {
        let counter = LoadCounter()
        let executor = ManualExecutor()
        let guardian = makeGuardian(analyzer: makeAnalyzer(counter), executor: executor)
        guardian.warmUp()
        executor.runAll()
        XCTAssertEqual(counter.count, 1)
        feedOneWindow(guardian)
        executor.runAll()
        XCTAssertEqual(counter.count, 1, "no second load for the first window")
        XCTAssertEqual(guardian.tier1Stats.windowsReady, 1)
    }

    func testAFailedLoadStopsTheGuardianFromDoingPerChunkWork() {
        let counter = LoadCounter(result: false)
        let executor = ManualExecutor()
        let analyzer = makeAnalyzer(counter)
        let guardian = makeGuardian(analyzer: analyzer, executor: executor)
        guardian.warmUp()
        executor.runAll()
        XCTAssertFalse(analyzer.canScore)
        feedOneWindow(guardian)
        XCTAssertEqual(guardian.tier1Stats, GuardianMode.Tier1Stats(), "no VAD, no copy, no hand-off")
        XCTAssertEqual(executor.pending, 0)
    }
}
