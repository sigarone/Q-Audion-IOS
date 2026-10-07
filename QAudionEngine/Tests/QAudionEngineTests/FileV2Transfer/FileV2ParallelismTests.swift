import XCTest
@testable import QAudionEngine

/// The memory budget (design 2.3), the adaptive parallelism rule (design 2.3.1) and the retry policy: pure, table driven. The
/// tables are the ones of the Android reference (MemBudgetAndParallelismTest), so the three platforms decide alike.
final class FileV2ParallelismTests: XCTestCase {

    private let mib: Int64 = 1 << 20
    private let partBytes: Int64 = 8_388_736

    // MARK: MemBudget: min(6 x part, memory / 6), at least one worker

    func testMemoryBudgetTable() throws {
        // memory MiB, expected max parallelism (budget / real part size 8 388 736 B, floor); budget = min(6 parts, memory / 6)
        let rows: [(Int, Int)] = [
            (512, 6),   // 85 MiB, capped at 6 real parts: the server's P=6 fits
            (288, 5),   // exactly 48 MiB: 5.9999 real parts, the lower budget is the floor
            (256, 5),   // 42.7 MiB
            (192, 3),   // 32 MiB: 3.9998 real parts, prudent side
            (128, 2),   // 21.3 MiB
            (96, 1),    // 16 MiB
            (64, 1),    // 10.7 MiB
            (48, 1),    // 8 MiB
            (24, 1),    // below one part: still one worker, never zero
            (0, 1)
        ]
        for (memory, expected) in rows {
            let budget = try FileV2MemBudget(memoryMiB: memory)
            XCTAssertEqual(budget.budgetBytes, min(6 * partBytes, Int64(memory) * mib / 6), "budget for \(memory) MiB")
            XCTAssertEqual(budget.maxParallelism, expected, "parallelism for \(memory) MiB")
        }
    }

    func testDefaultBudgetIsSixRealPartsSoTheServersParallelismHoldsOnARoomyDevice() throws {
        let budget = try FileV2MemBudget(memoryMiB: 1024)
        XCTAssertEqual(budget.budgetBytes, 6 * 8_388_736)
        XCTAssertEqual(budget.maxParallelism, 6)
        XCTAssertEqual(FileV2MemBudget.defaultCapBytes, 6 * Int64(FileV2Wire.partSize))
    }

    func testAPlaintextChunkHeldPerWorkerIsCountedWhenThePipelineKeepsOne() throws {
        let budget = try FileV2MemBudget(memoryMiB: 1024, perWorkerExtraBytes: 1 << 20)
        XCTAssertEqual(budget.maxParallelism, 5)    // 6 x 8 388 736 / (8 388 736 + 1 048 576) = 5.33
    }

    func testTheCapIsAParameter() throws {
        let budget = try FileV2MemBudget(memoryMiB: 512, capBytes: 24 * mib)
        XCTAssertEqual(budget.budgetBytes, 24 * mib)
        XCTAssertEqual(budget.maxParallelism, 2)    // 24 MiB / 8 388 736 = 2.99
    }

    func testNegativeInputsAreRefused() {
        XCTAssertThrowsError(try FileV2MemBudget(memoryMiB: -1)) { XCTAssertEqual($0 as? FileV2ConfigError, .invalidArgument("memoryMiB")) }
        XCTAssertThrowsError(try FileV2MemBudget(memoryMiB: 1, capBytes: -1)) {
            XCTAssertEqual($0 as? FileV2ConfigError, .invalidArgument("capBytes"))
        }
        XCTAssertThrowsError(try FileV2MemBudget(memoryMiB: 1, perWorkerExtraBytes: -1)) {
            XCTAssertEqual($0 as? FileV2ConfigError, .invalidArgument("perWorkerExtraBytes"))
        }
    }

    func testHugeInputsNeitherTrapNorOverflow() throws {
        let huge = try FileV2MemBudget(memoryMiB: Int.max)
        XCTAssertEqual(huge.budgetBytes, FileV2MemBudget.defaultCapBytes)
        XCTAssertEqual(huge.maxParallelism, 6)
        let heavy = try FileV2MemBudget(memoryMiB: 1024, capBytes: Int64.max, perWorkerExtraBytes: Int64.max)
        XCTAssertEqual(heavy.maxParallelism, 1)
        let wide = try FileV2MemBudget(memoryMiB: Int.max, capBytes: Int64.max)
        XCTAssertGreaterThan(wide.maxParallelism, 1_000_000)
    }

    // MARK: Ceiling and starting point

    private func parallelism(p0: Int = 6, serverMax: Int = 8, memCap: Int = 6, metered: Bool = false,
                             directionCap: Int = 8) -> FileV2AdaptiveParallelism {
        FileV2AdaptiveParallelism(serverParallelism: p0, serverMaxParallelism: serverMax, memoryCap: memCap, metered: metered,
                                  directionCap: directionCap, startMs: 0)
    }

    func testCeilingAndInitialValueTable() {
        // p0, serverMax, memCap, metered, directionCap -> ceiling, initial
        let rows: [(Int, Int, Int, Bool, Int, Int, Int)] = [
            (6, 8, 6, false, 8, 6, 6),
            (6, 8, 5, false, 8, 5, 5),     // memory budget lowers the start too
            (6, 8, 6, true, 8, 3, 3),      // metered / data saver: ceiling 3
            (6, 4, 6, false, 8, 4, 4),     // server max_parallelism
            (6, 16, 16, false, 8, 8, 6),   // never above 8
            (2, 8, 6, false, 8, 6, 2),     // P0 below the ceiling is kept
            (6, 12, 12, false, 4, 4, 4),   // download ceiling 4
            (0, 8, 6, false, 8, 6, 1),     // nonsense P0 -> 1
            (6, 0, 6, false, 8, 1, 1)      // nonsense max -> 1
        ]
        for row in rows {
            let value = parallelism(p0: row.0, serverMax: row.1, memCap: row.2, metered: row.3, directionCap: row.4)
            XCTAssertEqual(value.ceiling, row.5, "ceiling \(row)")
            XCTAssertEqual(value.current, row.6, "initial \(row)")
        }
    }

    func testTheNamedCeilings() {
        XCTAssertEqual(FileV2AdaptiveParallelism.hardCeiling, 8)
        XCTAssertEqual(FileV2AdaptiveParallelism.meteredCeiling, 3)
        XCTAssertEqual(FileV2AdaptiveParallelism.downloadCeiling, 4)
        XCTAssertEqual(FileV2AdaptiveParallelism.window, 4)
        XCTAssertEqual(FileV2AdaptiveParallelism.holdWindows, 4)
        XCTAssertEqual(FileV2AdaptiveParallelism.gain, 1.15, accuracy: 1e-12)
    }

    // MARK: Window: every 4 completed parts

    /// Completes 4 parts whose aggregate goodput is `bps`; returns the new clock.
    private func window(_ value: inout FileV2AdaptiveParallelism, bps: Int64, now: Int64) -> Int64 {
        let total = 4 * partBytes
        let end = now + total * 1000 / bps
        let step = (end - now) / 4
        for index in 1...4 {
            value.onPartDone(bytes: partBytes, nowMs: index == 4 ? end : now + step * Int64(index), startedMs: now)
        }
        return end
    }

    func testNothingChangesBeforeTheWindowIsFull() {
        var value = parallelism(p0: 3, serverMax: 8, memCap: 8)
        value.onPartDone(bytes: partBytes, nowMs: 1000, startedMs: 0)
        value.onPartDone(bytes: partBytes, nowMs: 2000, startedMs: 0)
        value.onPartDone(bytes: partBytes, nowMs: 3000, startedMs: 0)
        XCTAssertEqual(value.current, 3)
        XCTAssertEqual(value.changes, 0)
    }

    func testClimbsByOneWhileEachStepGainsFifteenPercentAndRevertsWhenItDoesNot() {
        var value = parallelism(p0: 3, serverMax: 8, memCap: 8)
        var now: Int64 = 0
        now = window(&value, bps: 10_000_000, now: now)          // baseline at P=3, probe P=4
        XCTAssertEqual(value.current, 4)
        now = window(&value, bps: 11_600_000, now: now)          // +16%: keep 4, probe 5
        XCTAssertEqual(value.current, 5)
        now = window(&value, bps: 13_400_000, now: now)          // +15.5%: keep 5, probe 6
        XCTAssertEqual(value.current, 6)
        now = window(&value, bps: 14_000_000, now: now)          // +4.5%: not enough, back to 5
        XCTAssertEqual(value.current, 5)
        XCTAssertEqual(value.changes, 4)                         // 3->4, 4->5, 5->6, 6->5
    }

    func testGainBelowFifteenPercentIsNotAGain() {
        var value = parallelism(p0: 3, serverMax: 8, memCap: 8)
        var now: Int64 = 0
        now = window(&value, bps: 10_000_000, now: now)          // probe 4
        now = window(&value, bps: 11_400_000, now: now)          // +14%: revert
        XCTAssertEqual(value.current, 3)
    }

    func testNeverAboveTheCeiling() {
        var value = parallelism(p0: 5, serverMax: 8, memCap: 6)   // ceiling 6
        var now: Int64 = 0
        var bps: Int64 = 10_000_000
        for _ in 0..<10 {
            now = window(&value, bps: bps, now: now)
            bps *= 2
        }
        XCTAssertEqual(value.current, 6)
        XCTAssertLessThanOrEqual(value.current, value.ceiling)
    }

    func testAfterAFailedProbeItHoldsAndProbesAgainOnlyAfterFourWindows() {
        var value = parallelism(p0: 3, serverMax: 8, memCap: 8)
        var now: Int64 = 0
        now = window(&value, bps: 10_000_000, now: now)          // probe 4
        now = window(&value, bps: 10_000_000, now: now)          // no gain: back to 3, hold
        XCTAssertEqual(value.current, 3)
        for _ in 0..<3 {
            now = window(&value, bps: 10_000_000, now: now)
            XCTAssertEqual(value.current, 3)
        }
        now = window(&value, bps: 10_000_000, now: now)          // 4th hold window: probe again
        XCTAssertEqual(value.current, 4)
    }

    // MARK: Errors halve, never below 1

    func testAnErrorHalvesTheParallelismDownToOne() {
        var value = parallelism(p0: 6, memCap: 6)
        value.onPartFailed(nowMs: 1000, startedMs: 0)
        XCTAssertEqual(value.current, 3)
        value.onPartFailed(nowMs: 2000, startedMs: 1000)
        XCTAssertEqual(value.current, 1)
        value.onPartFailed(nowMs: 3000, startedMs: 2000)
        XCTAssertEqual(value.current, 1)
    }

    func testAnErrorResetsTheMeasurementAndTheNextWindowIsANewBaseline() {
        var value = parallelism(p0: 6, serverMax: 8, memCap: 8)
        var now: Int64 = 0
        now = window(&value, bps: 10_000_000, now: now)          // 6 -> probe 7
        XCTAssertEqual(value.current, 7)
        value.onPartFailed(nowMs: now, startedMs: now)           // 7 -> 3
        XCTAssertEqual(value.current, 3)
        now = window(&value, bps: 5_000_000, now: now)           // new baseline (not compared with 10 MB/s): probe 4
        XCTAssertEqual(value.current, 4)
    }

    func testANetworkDropFailsEveryPartInFlightAtOnceAndCostsOneHalvingNotACollapseToOne() {
        var value = parallelism(p0: 6, memCap: 6)
        for index in 0..<6 { value.onPartFailed(nowMs: 1000 + Int64(index), startedMs: 0) }     // six parts started under P=6 all fail
        XCTAssertEqual(value.current, 3)
        XCTAssertEqual(value.changes, 1)
        value.onPartFailed(nowMs: 2000, startedMs: 1500)                                        // a part started AFTER the halving fails: that is news
        XCTAssertEqual(value.current, 1)
    }

    func testPartsStartedUnderThePreviousPAreNotSamplesOfTheProbeWindow() {
        var value = parallelism(p0: 3, serverMax: 8, memCap: 8)
        var now: Int64 = 0
        now = window(&value, bps: 10_000_000, now: now)                                          // baseline, P becomes 4 at now
        XCTAssertEqual(value.current, 4)
        // four stragglers that started before the change finish right after it: they must not close or taint the probe window
        for _ in 0..<4 { value.onPartDone(bytes: partBytes, nowMs: now + 1, startedMs: now - 1) }
        XCTAssertEqual(value.current, 4)
        now = window(&value, bps: 11_600_000, now: now + 1)                                      // +16% over the baseline: the probe is kept
        XCTAssertEqual(value.current, 5)
    }

    func testStatisticsForTelemetry() {
        var value = parallelism(p0: 3, serverMax: 8, memCap: 8)
        var now: Int64 = 0
        now = window(&value, bps: 10_000_000, now: now)
        now = window(&value, bps: 12_000_000, now: now)
        value.onPartFailed(nowMs: now, startedMs: now)
        let stats = value.stats()
        XCTAssertEqual(stats.finalParallelism, value.current)
        XCTAssertEqual(stats.changes, 3)                          // 3->4, 4->5, 5->2
        XCTAssertTrue((10_000_000.0...12_000_000.0).contains(stats.meanGoodputBytesPerSecond), "\(stats.meanGoodputBytesPerSecond)")
        XCTAssertEqual(parallelism().stats().meanGoodputBytesPerSecond, 0)
    }

    func testAValueTypeCopyIsASnapshot() {
        var value = parallelism(p0: 3, serverMax: 8, memCap: 8)
        let before = value
        _ = window(&value, bps: 10_000_000, now: 0)
        XCTAssertEqual(before.current, 3)
        XCTAssertEqual(value.current, 4)
    }

    // MARK: Retry policy: 1-2-4-8 s, jitter, Retry-After, at most 5 attempts

    func testBackoffTableWithZeroJitter() {
        let policy = FileV2RetryPolicy(jitter: { _ in 0 })
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: nil), 1_000)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 2, retryAfterSeconds: nil), 2_000)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 3, retryAfterSeconds: nil), 4_000)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 4, retryAfterSeconds: nil), 8_000)
        XCTAssertNil(policy.nextDelayMs(failedAttempts: 5, retryAfterSeconds: nil), "fifth failure: the part is out of attempts")
        XCTAssertNil(policy.nextDelayMs(failedAttempts: 9, retryAfterSeconds: nil))
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 0, retryAfterSeconds: nil), 1_000, "nonsense counts as the first failure")
    }

    func testJitterIsAddedOnTopOfTheBaseAndInjected() {
        let policy = FileV2RetryPolicy(jitter: { $0 / 4 })
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: nil), 1_250)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 4, retryAfterSeconds: nil), 10_000)
    }

    func testAJitterOutsideZeroToBaseIsClamped() {
        XCTAssertEqual(FileV2RetryPolicy(jitter: { _ in -500 }).nextDelayMs(failedAttempts: 1, retryAfterSeconds: nil), 1_000)
        XCTAssertEqual(FileV2RetryPolicy(jitter: { _ in 99_999 }).nextDelayMs(failedAttempts: 1, retryAfterSeconds: nil), 2_000)
    }

    func testDefaultJitterStaysWithinAQuarterOfTheBase() {
        let policy = FileV2RetryPolicy()
        for _ in 0..<200 {
            let delay = policy.nextDelayMs(failedAttempts: 2, retryAfterSeconds: nil) ?? -1
            XCTAssertTrue((2_000...2_500).contains(delay), "delay \(delay)")
        }
    }

    func testRetryAfterWinsOverTheBackoffAndAttemptsStillCount() {
        let policy = FileV2RetryPolicy(jitter: { _ in 0 })
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: 30), 30_000)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 4, retryAfterSeconds: 2), 2_000)
        XCTAssertNil(policy.nextDelayMs(failedAttempts: 5, retryAfterSeconds: 2))
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: 0), 0, "Retry-After: 0 means now")
    }

    func testANegativeRetryAfterIsIgnored() {
        let policy = FileV2RetryPolicy(jitter: { _ in 0 })
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 2, retryAfterSeconds: -5), 2_000)
    }

    func testRetryAfterAboveThreeHundredSecondsIsCapped() {
        let policy = FileV2RetryPolicy(jitter: { _ in 0 })
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: 300), 300_000)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: 301), 300_000)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: 3_600), 300_000)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: Int.max), 300_000)
        // and the jitter still applies on top of the cap, so the longest wait is 375 s
        XCTAssertEqual(FileV2RetryPolicy(jitter: { $0 / 4 }).nextDelayMs(failedAttempts: 1, retryAfterSeconds: 9_999), 375_000)
    }

    func testRetryAfterGetsTheJitterTooSoManyClientsDoNotComeBackTogether() {
        XCTAssertEqual(FileV2RetryPolicy(jitter: { $0 / 4 }).nextDelayMs(failedAttempts: 1, retryAfterSeconds: 8), 10_000)
        let policy = FileV2RetryPolicy()
        for _ in 0..<200 {
            let delay = policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: 4) ?? -1
            XCTAssertTrue((4_000...5_000).contains(delay), "delay \(delay)")
        }
    }

    func testAttemptLimitIsAParameterDefaultFive() {
        XCTAssertEqual(FileV2RetryPolicy().maxAttempts, 5)
        let policy = FileV2RetryPolicy(maxAttempts: 2, jitter: { _ in 0 })
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: nil), 1_000)
        XCTAssertNil(policy.nextDelayMs(failedAttempts: 2, retryAfterSeconds: nil))
    }

    // MARK: Part timeouts

    func testTheSlowestLegitimatePartTakesAboutSeventeenAndAHalfMinutes() {
        XCTAssertEqual(FileV2PartTimeout.serverFloorBytesPerSecond, 8000)
        XCTAssertEqual(FileV2PartTimeout.serverGraceSeconds, 30)
        XCTAssertEqual(FileV2PartTimeout.slowestLegitimateSeconds, 1049)    // 8 388 736 / 8000 = 1048.6
        XCTAssertGreaterThan(Double(FileV2PartTimeout.slowestLegitimateSeconds) / 60.0, 17.4)
        XCTAssertLessThan(Double(FileV2PartTimeout.slowestLegitimateSeconds) / 60.0, 17.6)
    }

    func testAProgressDeadlineSlidesWhileBytesMoveAndExpiresWhenNothingDoes() {
        var deadline = FileV2ProgressDeadline(idleLimitMs: 30_000, startMs: 1_000)
        XCTAssertEqual(deadline.expiresAtMs, 31_000)
        XCTAssertFalse(deadline.isExpired(nowMs: 30_999))
        XCTAssertTrue(deadline.isExpired(nowMs: 31_000))
        // a transfer that keeps moving for much longer than the idle limit never expires
        var now: Int64 = 1_000
        for _ in 0..<1_100 {
            now += 1_000
            deadline.progress(bytes: 8_000, nowMs: now)
            XCTAssertFalse(deadline.isExpired(nowMs: now))
        }
        XCTAssertGreaterThan(now, Int64(FileV2PartTimeout.slowestLegitimateSeconds) * 1000)
        // nothing moved: it expires an idle limit after the last byte
        XCTAssertFalse(deadline.isExpired(nowMs: now + 29_999))
        XCTAssertTrue(deadline.isExpired(nowMs: now + 30_000))
        // a call that moved no byte does not slide it, and neither does a clock that went backwards
        deadline.progress(bytes: 0, nowMs: now + 29_000)
        deadline.progress(bytes: 10, nowMs: now - 5_000)
        XCTAssertTrue(deadline.isExpired(nowMs: now + 30_000))
    }
}
