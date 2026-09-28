import XCTest
@testable import QAudionEngine

/// W-LIVELOGOFFMAIN (2026-09-21) — the bounded backlog of prepared log lines: it keeps
/// what the server has not confirmed, drops the OLDEST first when a bound is hit, and
/// counts every drop.
final class LiveLogBacklogTests: XCTestCase {

    /// A line of exactly `size - 1` characters, so it weighs `size` bytes with its newline.
    private func line(weighing size: Int) -> String {
        return String(repeating: "x", count: size - 1)
    }

    // MARK: - Growth and bounds

    func test_keepsEverythingWhileWithinBothBounds() {
        var backlog = LiveLogBacklog(maxEntries: 10, maxBytes: 1_000)
        backlog.append(seq: 1, line: "a")
        backlog.append(seq: 2, line: "bb")
        backlog.append(seq: 3, line: "ccc")
        XCTAssertEqual(backlog.count, 3)
        XCTAssertFalse(backlog.isEmpty)
        XCTAssertEqual(backlog.byteCount, 2 + 3 + 4, "each line weighs its UTF-8 size plus one newline")
        XCTAssertEqual(backlog.droppedTotal, 0)
    }

    func test_theEntryBoundDropsTheOldestAndCountsThem() {
        var backlog = LiveLogBacklog(maxEntries: 3, maxBytes: 10_000)
        for seq in 1...5 {
            backlog.append(seq: Int64(seq), line: "l\(seq)")
        }
        XCTAssertEqual(backlog.count, 3)
        XCTAssertEqual(backlog.droppedTotal, 2)
        let batch = backlog.peekBatch(maxLines: 10, byteBudget: 10_000)
        XCTAssertEqual(batch?.lines ?? [], ["l3", "l4", "l5"], "the newest three survive, in order")
        XCTAssertEqual(batch?.lastSeq ?? -1, 5)
    }

    func test_theByteBoundDropsTheOldestAndCountsThem() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 25)
        backlog.append(seq: 1, line: line(weighing: 10))
        backlog.append(seq: 2, line: line(weighing: 10))
        XCTAssertEqual(backlog.count, 2)
        XCTAssertEqual(backlog.byteCount, 20)
        backlog.append(seq: 3, line: line(weighing: 10))
        XCTAssertEqual(backlog.count, 2, "30 bytes do not fit in 25: the oldest goes")
        XCTAssertEqual(backlog.byteCount, 20)
        XCTAssertEqual(backlog.droppedTotal, 1)
        XCTAssertEqual(backlog.peekBatch(maxLines: 10, byteBudget: 1_000)?.lastSeq ?? -1, 3)
    }

    func test_aLineBiggerThanTheWholeBacklogIsDroppedAndCounted() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 50)
        backlog.append(seq: 1, line: line(weighing: 10))
        backlog.append(seq: 2, line: line(weighing: 60))
        XCTAssertTrue(backlog.isEmpty, "the oversize line cannot fit, and evicting the older ones for it is not enough")
        XCTAssertEqual(backlog.byteCount, 0)
        XCTAssertEqual(backlog.droppedTotal, 2)
    }

    func test_takeUnreportedDropCountReturnsWhatIsNewAndResets() {
        var backlog = LiveLogBacklog(maxEntries: 2, maxBytes: 10_000)
        for seq in 1...4 {
            backlog.append(seq: Int64(seq), line: "x")
        }
        XCTAssertEqual(backlog.takeUnreportedDropCount(), 2)
        XCTAssertEqual(backlog.takeUnreportedDropCount(), 0)
        backlog.append(seq: 5, line: "x")
        XCTAssertEqual(backlog.takeUnreportedDropCount(), 1)
        XCTAssertEqual(backlog.droppedTotal, 3, "the running total is not reset by reporting")
    }

    func test_noteDroppedCountsLinesTheCollectorSkipped() {
        var backlog = LiveLogBacklog(maxEntries: 10, maxBytes: 1_000)
        backlog.noteDropped(0)
        backlog.noteDropped(-5)
        XCTAssertEqual(backlog.droppedTotal, 0)
        backlog.noteDropped(40)
        XCTAssertEqual(backlog.droppedTotal, 40)
        XCTAssertEqual(backlog.takeUnreportedDropCount(), 40)
    }

    // MARK: - Choosing a chunk

    func test_peekBatchReturnsNilWhenEmpty() {
        let backlog = LiveLogBacklog(maxEntries: 10, maxBytes: 1_000)
        XCTAssertNil(backlog.peekBatch(maxLines: 10, byteBudget: 1_000))
    }

    func test_peekBatchStopsAtTheLineLimitAndDoesNotRemoveAnything() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 10_000)
        for seq in 1...5 {
            backlog.append(seq: Int64(seq), line: "l\(seq)")
        }
        let batch = backlog.peekBatch(maxLines: 2, byteBudget: 10_000)
        XCTAssertEqual(batch?.lines ?? [], ["l1", "l2"])
        XCTAssertEqual(batch?.lastSeq ?? -1, 2)
        XCTAssertEqual(batch?.byteCount ?? -1, 6)
        XCTAssertEqual(backlog.count, 5, "looking is not taking")
    }

    func test_peekBatchStopsAtTheByteBudget() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 10_000)
        for seq in 1...3 {
            backlog.append(seq: Int64(seq), line: line(weighing: 10))
        }
        let batch = backlog.peekBatch(maxLines: 10, byteBudget: 25)
        XCTAssertEqual(batch?.lines.count ?? -1, 2)
        XCTAssertEqual(batch?.byteCount ?? -1, 20)
        XCTAssertEqual(batch?.lastSeq ?? -1, 2)
    }

    func test_peekBatchAlwaysIncludesTheFirstLineSoAGiantOneCannotWedgeTheQueue() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 10_000)
        backlog.append(seq: 1, line: line(weighing: 500))
        backlog.append(seq: 2, line: line(weighing: 10))
        let batch = backlog.peekBatch(maxLines: 10, byteBudget: 100)
        XCTAssertEqual(batch?.lines.count ?? -1, 1)
        XCTAssertEqual(batch?.lastSeq ?? -1, 1)
    }

    // MARK: - Confirming a chunk

    func test_removeThroughRemovesUpToAndIncludingTheConfirmedSeq() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 10_000)
        for seq in 1...5 {
            backlog.append(seq: Int64(seq), line: "l\(seq)")
        }
        XCTAssertEqual(backlog.removeThrough(seq: 3), 3)
        XCTAssertEqual(backlog.count, 2)
        XCTAssertEqual(backlog.peekBatch(maxLines: 10, byteBudget: 1_000)?.lines ?? [], ["l4", "l5"])
        XCTAssertEqual(backlog.removeThrough(seq: 3), 0, "confirming the same chunk twice removes nothing more")
        XCTAssertEqual(backlog.byteCount, 6)
    }

    func test_removeThroughIsKeyedBySeqSoItSurvivesDropsWhileTheChunkWasInFlight() {
        var backlog = LiveLogBacklog(maxEntries: 3, maxBytes: 10_000)
        for seq in 1...3 {
            backlog.append(seq: Int64(seq), line: "l\(seq)")
        }
        let inFlight = backlog.peekBatch(maxLines: 2, byteBudget: 1_000)
        XCTAssertEqual(inFlight?.lastSeq ?? -1, 2)
        // While that chunk is being uploaded, two more lines arrive and push 1 and 2 out.
        backlog.append(seq: 4, line: "l4")
        backlog.append(seq: 5, line: "l5")
        XCTAssertEqual(backlog.peekBatch(maxLines: 10, byteBudget: 1_000)?.lines ?? [], ["l3", "l4", "l5"])
        // The confirmation for seq 2 must not eat 3 and 4, which were never shipped.
        XCTAssertEqual(backlog.removeThrough(seq: inFlight?.lastSeq ?? -1), 0)
        XCTAssertEqual(backlog.count, 3)
    }

    func test_removeThroughEverythingEmptiesTheBacklog() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 10_000)
        backlog.append(seq: 1, line: "a")
        backlog.append(seq: 2, line: "b")
        XCTAssertEqual(backlog.removeThrough(seq: 99), 2)
        XCTAssertTrue(backlog.isEmpty)
        XCTAssertEqual(backlog.byteCount, 0)
        XCTAssertNil(backlog.peekBatch(maxLines: 10, byteBudget: 1_000))
        backlog.append(seq: 100, line: "c")
        XCTAssertEqual(backlog.peekBatch(maxLines: 10, byteBudget: 1_000)?.lines ?? [], ["c"])
    }

    func test_removeAllForgetsTheLinesButNotTheDropCount() {
        var backlog = LiveLogBacklog(maxEntries: 1, maxBytes: 1_000)
        backlog.append(seq: 1, line: "a")
        backlog.append(seq: 2, line: "b")
        XCTAssertEqual(backlog.droppedTotal, 1)
        backlog.removeAll()
        XCTAssertTrue(backlog.isEmpty)
        XCTAssertEqual(backlog.byteCount, 0)
        XCTAssertEqual(backlog.droppedTotal, 1)
    }

    // MARK: - A long run

    func test_aLongRunOfDropsKeepsTheNewestLinesInOrder() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 1_000_000)
        for seq in 0..<1_000 {
            backlog.append(seq: Int64(seq), line: "line-\(seq)")
        }
        XCTAssertEqual(backlog.count, 100)
        XCTAssertEqual(backlog.droppedTotal, 900)
        let batch = backlog.peekBatch(maxLines: 1_000, byteBudget: 1_000_000)
        let expected: [String] = (900..<1_000).map { "line-\($0)" }
        XCTAssertEqual(batch?.lines ?? [], expected)
        XCTAssertEqual(batch?.lastSeq ?? -1, 999)
        // ...and it still drains correctly after all that compaction.
        XCTAssertEqual(backlog.removeThrough(seq: 949), 50)
        XCTAssertEqual(backlog.peekBatch(maxLines: 1, byteBudget: 1_000)?.lines ?? [], ["line-950"])
    }
}
