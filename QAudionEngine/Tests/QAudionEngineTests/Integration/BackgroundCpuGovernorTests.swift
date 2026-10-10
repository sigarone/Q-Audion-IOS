import XCTest
@testable import QAudionEngine

/// A fake clock and a fake process-CPU counter that move only when a test says so (shared with the wiring tests).
final class GovWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime = 1_000.0
    private var currentCpu = 50.0
    private var cpuReads = 0

    var time: Double { lock.lock(); defer { lock.unlock() }; return currentTime }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return cpuReads }

    /// `seconds` pass and the process uses `cores` cores during them.
    func advance(_ seconds: Double, cores: Double) {
        lock.lock()
        currentTime += seconds
        currentCpu += seconds * cores
        lock.unlock()
    }

    func readCpu() -> Double? {
        lock.lock(); defer { lock.unlock() }
        cpuReads += 1
        return currentCpu
    }

    func governor(
        flag: AppBackgroundFlag, config: BackgroundCpuGovernor.Config = .standard
    ) -> BackgroundCpuGovernor {
        BackgroundCpuGovernor(
            config: config, flag: flag,
            clock: { [self] in self.time },
            cpuSeconds: { [self] in self.readCpu() })
    }
}

/// The CPU governor: in the background, when the process average passes half a core over 30 s, whole ticks of a
/// check are held back until it drops under 0.40 core; one tick per 30 s still runs; in the foreground it never
/// acts. Deterministic: clock, CPU counter and background flag are fakes. Ticks arrive every 10 s, as the
/// background period of the contact-voice check does.
final class BackgroundCpuGovernorTests: XCTestCase {

    private let flag = AppBackgroundFlag()
    private let world = GovWorld()

    private func makeGovernor(config: BackgroundCpuGovernor.Config = .standard) -> BackgroundCpuGovernor {
        world.governor(flag: flag, config: config)
    }

    /// Decisions at t = 0, 10, ... for `seconds`, the process using `cores` cores throughout.
    private func ticks(
        _ governor: BackgroundCpuGovernor, seconds: Int, cores: Double, first: Bool = false
    ) -> [Bool] {
        var runs: [Bool] = []
        if first { runs.append(governor.decide().run) }
        for _ in 0..<(seconds / 10) {
            world.advance(10, cores: cores)
            runs.append(governor.decide().run)
        }
        return runs
    }

    // MARK: - below / above the threshold

    func testBelowTheThresholdNothingIsHeldBack() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        let runs = ticks(governor, seconds: 120, cores: 0.45, first: true)
        XCTAssertEqual(runs, [Bool](repeating: true, count: 13))
        XCTAssertEqual(governor.totals, BackgroundCpuGovernor.Totals(ran: 13, skipped: 0))
        XCTAssertFalse(governor.isHoldingBack)
    }

    func testAboveTheThresholdInTheBackgroundTicksAreHeldBackWithAFloor() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        let runs = ticks(governor, seconds: 100, cores: 0.9, first: true)
        // t = 0 and 10 run (under 20 s of history nothing is judged); from t = 20 the average (0.9) is over 0.5, so
        // ticks are held back, except that one runs 30 s after the last one that ran: t = 40, 70, 100.
        XCTAssertEqual(runs, [true, true, false, false, true, false, false, true, false, false, true])
        XCTAssertTrue(governor.isHoldingBack)
        XCTAssertEqual(governor.totals, BackgroundCpuGovernor.Totals(ran: 5, skipped: 6))
    }

    func testTheFloorIsAParameter() {
        flag.set(isInBackground: true)
        let governor = makeGovernor(config: BackgroundCpuGovernor.Config(
            horizonSeconds: 30, minSpanSeconds: 20, highCores: 0.50, lowCores: 0.40,
            floorSeconds: 20, summarySeconds: 30))
        let runs = ticks(governor, seconds: 60, cores: 0.9, first: true)
        XCTAssertEqual(runs, [true, true, false, true, false, true, false])
    }

    func testAHeavyStartCannotTripItBeforeThereIsEnoughHistory() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        XCTAssertTrue(governor.decide().run)
        world.advance(10, cores: 8)   // a burst of 8 cores for the first 10 s
        XCTAssertTrue(governor.decide().run, "10 s of history is not enough to judge")
        XCTAssertFalse(governor.isHoldingBack)
    }

    func testWithoutAMeasurementTheCheckRuns() {
        flag.set(isInBackground: true)
        let world = self.world
        let governor = BackgroundCpuGovernor(
            config: .standard, flag: flag, clock: { world.time }, cpuSeconds: { nil })
        var runs: [Bool] = []
        for _ in 0..<10 {
            world.advance(10, cores: 5)
            runs.append(governor.decide().run)
        }
        XCTAssertEqual(runs, [Bool](repeating: true, count: 10))
    }

    // MARK: - foreground

    func testInTheForegroundItNeverActsAndNeverMeasures() {
        let governor = makeGovernor()
        let runs = ticks(governor, seconds: 200, cores: 6, first: true)
        XCTAssertEqual(runs, [Bool](repeating: true, count: 21))
        XCTAssertEqual(world.reads, 0, "the foreground must not even read the CPU counter")
        XCTAssertEqual(governor.totals, BackgroundCpuGovernor.Totals())
    }

    func testTheFlagIsReadAtEveryDecision() {
        // Held back in the background; the very next decision after returning to the foreground runs.
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        _ = ticks(governor, seconds: 60, cores: 0.9, first: true)
        XCTAssertTrue(governor.isHoldingBack)
        flag.set(isInBackground: false)
        world.advance(1, cores: 0.9)
        XCTAssertTrue(governor.decide().run)
        world.advance(1, cores: 0.9)
        XCTAssertTrue(governor.decide().run)
        XCTAssertFalse(governor.isHoldingBack)
    }

    func testForegroundCpuIsNotCountedWhenTheAppGoesBackAgain() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        _ = ticks(governor, seconds: 60, cores: 0.9, first: true)
        XCTAssertTrue(governor.isHoldingBack)

        flag.set(isInBackground: false)
        world.advance(60, cores: 3)               // a heavy minute in the foreground
        XCTAssertTrue(governor.decide().run)      // closes the background stretch
        flag.set(isInBackground: true)

        // A new stretch: it starts from nothing, so the heavy foreground minute does not count against it.
        XCTAssertTrue(governor.decide().run)
        XCTAssertFalse(governor.isHoldingBack)
        let runs = ticks(governor, seconds: 40, cores: 0.1)
        XCTAssertEqual(runs, [true, true, true, true])
        XCTAssertFalse(governor.isHoldingBack)
    }

    func testAStretchThatBeganWhileNobodyWasAskingIsStillANewStretch() {
        // Background, foreground and background again between two decisions: the entry count tells.
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        _ = ticks(governor, seconds: 60, cores: 0.9, first: true)
        XCTAssertTrue(governor.isHoldingBack)

        flag.set(isInBackground: false)
        world.advance(5, cores: 3)
        flag.set(isInBackground: true)
        world.advance(5, cores: 0.1)
        XCTAssertTrue(governor.decide().run)
        XCTAssertFalse(governor.isHoldingBack, "the old stretch's history must not carry over")
    }

    // MARK: - hysteresis

    func testHysteresisHoldsBetweenTheTwoThresholdsAndResumesBelowTheLowOne() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        _ = governor.decide()

        _ = ticks(governor, seconds: 60, cores: 0.90)
        XCTAssertTrue(governor.isHoldingBack, "over 0.50: held back")

        _ = ticks(governor, seconds: 60, cores: 0.45)
        XCTAssertTrue(governor.isHoldingBack, "0.45 is under the high threshold but not under the low one")

        _ = ticks(governor, seconds: 60, cores: 0.30)
        XCTAssertFalse(governor.isHoldingBack, "under 0.40: resumed")

        // Having resumed, 0.45 is not enough to hold back again: the bar to start is 0.50.
        var runs: [Bool] = []
        for _ in 0..<6 {
            world.advance(10, cores: 0.45)
            runs.append(governor.decide().run)
            XCTAssertFalse(governor.isHoldingBack)
        }
        XCTAssertEqual(runs, [Bool](repeating: true, count: 6))

        // And a load clearly over the bar holds back again.
        _ = ticks(governor, seconds: 60, cores: 0.90)
        XCTAssertTrue(governor.isHoldingBack)
    }

    // MARK: - summaries for the log

    func testPeriodicSummaryEveryThirtySecondsOfBackgroundWork() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        var summaries: [BackgroundCpuGovernor.Summary] = []
        if let s = governor.decide().summary { summaries.append(s) }
        for _ in 0..<10 {
            world.advance(10, cores: 0.3)
            if let s = governor.decide().summary { summaries.append(s) }
        }
        XCTAssertEqual(summaries.count, 3, "at t = 30, 60, 90")
        XCTAssertEqual(
            summaries.first,
            BackgroundCpuGovernor.Summary(background: true, cpuPercent: 30, ran: 4, skipped: 0, high: false))
        XCTAssertEqual(summaries.map { $0.ran }, [4, 3, 3])
    }

    func testASummaryAtTheMomentHoldingBackStarts() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        var summaries: [BackgroundCpuGovernor.Summary] = []
        if let s = governor.decide().summary { summaries.append(s) }
        for _ in 0..<2 {
            world.advance(10, cores: 0.9)
            if let s = governor.decide().summary { summaries.append(s) }
        }
        XCTAssertEqual(
            summaries,
            [BackgroundCpuGovernor.Summary(background: true, cpuPercent: 90, ran: 2, skipped: 1, high: true)])
    }

    func testASummaryAtTheMomentHoldingBackEnds() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        _ = governor.decide()
        _ = ticks(governor, seconds: 60, cores: 0.9)
        XCTAssertTrue(governor.isHoldingBack)
        var released: BackgroundCpuGovernor.Summary?
        for _ in 0..<9 {
            world.advance(10, cores: 0.1)
            let decision = governor.decide()
            if let s = decision.summary, !s.high { released = s }
        }
        XCTAssertNotNil(released)
        XCTAssertEqual(released?.background, true)
        XCTAssertFalse(governor.isHoldingBack)
    }

    func testASummaryWhenTheAppReturnsToTheForeground() {
        flag.set(isInBackground: true)
        let governor = makeGovernor()
        _ = ticks(governor, seconds: 40, cores: 0.3, first: true)   // a summary was already given at t = 30
        flag.set(isInBackground: false)
        let back = governor.decide()
        XCTAssertTrue(back.run)
        XCTAssertEqual(
            back.summary,
            BackgroundCpuGovernor.Summary(background: false, cpuPercent: 30, ran: 1, skipped: 0, high: false))
        XCTAssertNil(governor.decide().summary, "once")
    }

    func testLogLinesUseOnlyWholeNumbersAndTheKnownShape() {
        let summary = BackgroundCpuGovernor.Summary(background: true, cpuPercent: 42, ran: 2, skipped: 3, high: false)
        XCTAssertEqual(
            summary.logLine(label: "Voice", everySeconds: 10), "[Voice] bg=1 every=10 cpu=42 skip=3 run=2 high=0")
        let held = BackgroundCpuGovernor.Summary(background: true, cpuPercent: 250, ran: 7, skipped: 0, high: true)
        XCTAssertEqual(held.logLine(label: "Guardian"), "[Guardian] bg=1 cpu=250 skip=0 run=7 high=1")
        let back = BackgroundCpuGovernor.Summary(background: false, cpuPercent: 30, ran: 1, skipped: 0, high: false)
        XCTAssertEqual(back.logLine(label: "Voice", everySeconds: 3), "[Voice] bg=0 every=3 cpu=30 skip=0 run=1 high=0")
    }

    // MARK: - the real counter and the flag's entry count

    func testTheProcessCpuCounterOnlyGoesUp() throws {
        let before = try XCTUnwrap(ProcessCpu.seconds())
        var x = 1.0
        for i in 1...3_000_000 { x = x * 1.0000001 + Double(i % 7) }
        XCTAssertGreaterThan(x, 0)
        let after = try XCTUnwrap(ProcessCpu.seconds())
        XCTAssertGreaterThanOrEqual(before, 0)
        XCTAssertGreaterThanOrEqual(after, before)
    }

    func testTheFlagCountsOnlyRealEntriesToTheBackground() {
        let flag = AppBackgroundFlag()
        XCTAssertEqual(flag.backgroundEntryCount, 0)
        flag.set(isInBackground: false)
        flag.set(isInBackground: true)
        flag.set(isInBackground: true)
        XCTAssertEqual(flag.backgroundEntryCount, 1)
        flag.set(isInBackground: false)
        XCTAssertEqual(flag.backgroundEntryCount, 1, "leaving the background is not an entry")
        flag.set(isInBackground: true)
        XCTAssertEqual(flag.backgroundEntryCount, 2)
    }
}
