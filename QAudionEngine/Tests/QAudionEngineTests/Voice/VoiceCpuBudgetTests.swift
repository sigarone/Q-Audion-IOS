import XCTest
import Foundation
@testable import QAudionEngine

/// The process-wide `VoiceCpuBudget`: the numbers of the replay and the rules that a long call and several reporters add.
final class VoiceCpuBudgetTests: XCTestCase {
    private let cpu = VoiceCpuConstants(budgetTotalCore: 0.3, windowS: 30, maxPending: 3, postCallMaxS: 10)
    private let s: Int64 = 1_000_000_000

    func testTheLimitIsTheShareTimesTheWindowRoundedToAWholeNanosecond() {
        XCTAssertEqual(VoiceCpuBudget(cpu: cpu).limitNs, 9 * s)
    }

    func testTotalClipsEveryIntervalToTheLast30SecondsAndRoomIsAStrictComparison() {
        let b = VoiceCpuBudget(cpu: cpu)
        b.add(who: "contact", startNs: 0, endNs: 4 * s)
        b.add(who: "vad", startNs: 100 * s, endNs: 105 * s) // not yet at t = 50 s
        XCTAssertEqual(b.total(10 * s), 4 * s)
        XCTAssertEqual(b.total(32 * s), 2 * s) // (2 s, 32 s]: 2 s of the first interval are inside
        XCTAssertEqual(b.total(34 * s), 0) // an interval that ends exactly at the lower bound is outside
        XCTAssertEqual(b.total(50 * s), 0)
        // exactly at the limit there is no room, one nanosecond below there is
        let c = VoiceCpuBudget(cpu: cpu)
        c.add(who: "monitor", startNs: 0, endNs: 9 * s - 1)
        XCTAssertTrue(c.room(10 * s))
        c.add(who: "guardian", startNs: 0, endNs: 1)
        XCTAssertEqual(c.total(10 * s), 9 * s)
        XCTAssertFalse(c.room(10 * s))
        XCTAssertTrue(c.room(40 * s), "the busy time leaves the window")
    }

    func testForgettingOldIntervalsChangesNoReading() {
        let b = VoiceCpuBudget(cpu: cpu)
        var seed: UInt64 = 7
        func next(_ bound: Int64) -> Int64 {
            // a small deterministic sequence: the test must not depend on the system generator
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int64(seed >> 33) % bound
        }
        var all: [(Int64, Int64)] = []
        var t: Int64 = 0
        for i in 0..<20_000 {
            t += next(40_000_000) + 1
            let d = next(20_000_000) + 1
            all.append((t, t + d))
            b.add(who: "vad", startNs: t, endNs: t + d)
            if i % 997 == 0 {
                let lo = t - 30 * s
                var naive: Int64 = 0
                for iv in all { naive += max(0, min(iv.1, t) - max(iv.0, lo)) }
                XCTAssertEqual(b.total(t), naive, "at \(t)")
            }
        }
        XCTAssertGreaterThan(t, 300 * s, "the run is many windows long")
    }

    func testReportersOnSeveralThreadsAddWithoutLosingAnInterval() {
        let b = VoiceCpuBudget(cpu: cpu)
        let threads = 4
        let each = 2_000
        let group = DispatchGroup()
        for k in 0..<threads {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<each {
                    let at = Int64(1000 * k + i)
                    b.add(who: "t\(k)", startNs: at, endNs: at + 1)
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(b.total(1_000_000), Int64(threads * each))
    }
}
