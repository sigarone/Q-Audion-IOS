import XCTest
@testable import QAudionEngine

final class LogLineCoalescerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func input(_ seq: Int64, _ offset: TimeInterval, _ message: String,
                       level: String = "I", tag: String = "mesh") -> LogLineCoalescer.Input {
        LogLineCoalescer.Input(seq: seq, timestamp: base.addingTimeInterval(offset), level: level, tag: tag, message: message)
    }

    func test_identicalLinesInOneSecondBecomeOneLineWithCount() {
        let lines = (0..<837).map { input(Int64($0 + 1), Double($0) * 0.001, "connect.backoff link=c1 failures=2") }
        let out = LogLineCoalescer.coalesce(lines)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].message, "connect.backoff link=c1 failures=2 (x837)")
        XCTAssertEqual(out[0].count, 837)
        XCTAssertEqual(out[0].seq, 837, "the entry carries the last sequence number of the run")
        XCTAssertEqual(out[0].timestamp, base, "the entry keeps the time of the first line")
    }

    func test_singleLineIsUnchanged() {
        let out = LogLineCoalescer.coalesce([input(1, 0, "hello")])
        XCTAssertEqual(out.map(\.message), ["hello"])
        XCTAssertEqual(out[0].count, 1)
    }

    func test_repeatAfterTheWindowStartsANewRun() {
        let out = LogLineCoalescer.coalesce([input(1, 0, "x"), input(2, 0.5, "x"), input(3, 1.0, "x"), input(4, 1.2, "x")])
        XCTAssertEqual(out.map(\.message), ["x (x2)", "x (x2)"])
        XCTAssertEqual(out.map(\.seq), [2, 4])
    }

    func test_differentLevelOrTagIsNotMerged() {
        let out = LogLineCoalescer.coalesce([
            input(1, 0, "x", level: "I"), input(2, 0.1, "x", level: "W"), input(3, 0.2, "x", tag: "net")
        ])
        XCTAssertEqual(out.count, 3)
    }

    func test_onlyAdjacentRepeatsMergeAndOrderIsKept() {
        let out = LogLineCoalescer.coalesce([input(1, 0.0, "a"), input(2, 0.1, "b"), input(3, 0.2, "a")])
        XCTAssertEqual(out.map(\.message), ["a", "b", "a"])
        XCTAssertEqual(out.map(\.seq), [1, 2, 3])
    }

    func test_adjacentPairMergesInsideAMixedSequence() {
        let out = LogLineCoalescer.coalesce([
            input(1, 0.0, "a"), input(2, 0.1, "a"), input(3, 0.2, "b"), input(4, 0.3, "a"), input(5, 0.4, "a")
        ])
        XCTAssertEqual(out.map(\.message), ["a (x2)", "b", "a (x2)"])
        XCTAssertEqual(out.map(\.seq), [2, 3, 5])
    }

    func test_emptyInput() {
        XCTAssertTrue(LogLineCoalescer.coalesce([]).isEmpty)
    }
}
