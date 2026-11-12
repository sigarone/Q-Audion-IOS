import XCTest
@testable import QAudionEngine

/// The storage of the app's log: readable and writable from any thread, sequence numbers that only
/// grow, the oldest tenth dropped when full, the new entries read in cost proportional to them.
final class SequencedRingTests: XCTestCase {

    private struct Item { let seq: Int64; let text: String }

    private func makeRing(max: Int = 100) -> SequencedRing<Item> {
        SequencedRing<Item>(maxEntries: max, seqOf: { $0.seq })
    }

    func test_entriesSince_returnsOnlyNewOnes_oldestFirst() {
        let ring = makeRing()
        for i in 1...5 { ring.append { Item(seq: $0, text: "l\(i)") } }
        let batch = ring.entriesSince(seq: 2, maxCount: 100) { $0.text }
        XCTAssertEqual(batch.entries, ["l3", "l4", "l5"])
        XCTAssertEqual(batch.skippedOlder, 0)
    }

    func test_entriesSince_keepsTheNewestWhenMoreArePending() {
        let ring = makeRing()
        for i in 1...10 { ring.append { Item(seq: $0, text: "l\(i)") } }
        let batch = ring.entriesSince(seq: 0, maxCount: 4) { $0.text }
        XCTAssertEqual(batch.entries, ["l7", "l8", "l9", "l10"])
        XCTAssertEqual(batch.skippedOlder, 6)
    }

    func test_eviction_dropsTheOldestTenth_andSequenceKeepsGrowing() {
        let ring = makeRing(max: 100)
        for _ in 1...101 { ring.append { Item(seq: $0, text: "x") } }
        XCTAssertEqual(ring.count, 91)
        let next = ring.append { Item(seq: $0, text: "y") }
        XCTAssertEqual(next, 102)
        XCTAssertEqual(ring.snapshot().first?.seq, 11)
    }

    func test_removeAll_keepsTheSequence() {
        let ring = makeRing()
        ring.append { Item(seq: $0, text: "a") }
        ring.removeAll()
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.append { Item(seq: $0, text: "b") }, 2)
    }

    /// Readers on another thread get a consistent batch while writers append from several threads:
    /// no hop to any particular thread is needed.
    func test_readsAndWritesFromBackgroundThreads_stayConsistent() {
        let ring = makeRing(max: 100_000)
        let readsDone = expectation(description: "reader")
        let reader = DispatchQueue(label: "test.ring.reader")
        reader.async {
            var since: Int64 = 0
            for _ in 0..<200 {
                let batch = ring.entriesSince(seq: since, maxCount: 1_000) { $0.seq }
                var previous = since
                for seq in batch.entries {
                    XCTAssertGreaterThan(seq, previous)
                    previous = seq
                }
                since = previous
            }
            readsDone.fulfill()
        }
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<500 { ring.append { Item(seq: $0, text: "w") } }
        }
        wait(for: [readsDone], timeout: 10)
        XCTAssertEqual(ring.count, 2_000)
    }
}
