import XCTest
@testable import QAudionEngine

final class MeshFragmentTests: XCTestCase {

    private func nodeId(_ hex: String) throws -> MeshNodeId {
        try MeshNodeId(hex: hex)
    }

    // MARK: - MeshFragmenter

    func testShouldFragmentThreshold() {
        XCTAssertFalse(MeshFragmenter.shouldFragment(Data(repeating: 0, count: MeshFragmenter.threshold)))
        XCTAssertTrue(MeshFragmenter.shouldFragment(Data(repeating: 0, count: MeshFragmenter.threshold + 1)))
    }

    func testFragmentSplitsIntoOrderedChunksCoveringWholePayload() throws {
        let payload = Data((0..<1000).map { UInt8($0 % 256) })
        let parts = try MeshFragmenter.fragment(payload, chunkSize: 300)
        XCTAssertEqual(parts.count, 4) // 300*3 + 100
        for (i, part) in parts.enumerated() {
            XCTAssertEqual(part.header.index, i)
            XCTAssertEqual(part.header.total, parts.count)
        }
        let reassembled = parts.reduce(Data()) { $0 + $1.chunk }
        XCTAssertEqual(reassembled, payload)
    }

    func testFragmentSingleChunkForSmallPayload() throws {
        let payload = Data([1, 2, 3])
        let parts = try MeshFragmenter.fragment(payload, chunkSize: 300)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].chunk, payload)
    }

    func testFragmentThrowsWhenExceedingMaxFragments() {
        let payload = Data(repeating: 0, count: 1000)
        XCTAssertThrowsError(try MeshFragmenter.fragment(payload, chunkSize: 1))
    }

    // MARK: - MeshFragmentReassembler

    func testReassembleSingleFragmentCompletesImmediately() throws {
        let reassembler = MeshFragmentReassembler()
        let sender = try nodeId("0011223344556677")
        let header = try MeshFragmentHeader(fragmentSetId: 1, index: 0, total: 1)
        let outcome = reassembler.offer(senderId: sender, header: header, chunk: Data([1, 2, 3]))
        XCTAssertEqual(outcome, .complete(Data([1, 2, 3])))
    }

    func testReassembleMultipleFragmentsOutOfOrder() throws {
        let reassembler = MeshFragmentReassembler()
        let sender = try nodeId("0011223344556677")
        let h0 = try MeshFragmentHeader(fragmentSetId: 7, index: 0, total: 3)
        let h1 = try MeshFragmentHeader(fragmentSetId: 7, index: 1, total: 3)
        let h2 = try MeshFragmentHeader(fragmentSetId: 7, index: 2, total: 3)

        XCTAssertEqual(reassembler.offer(senderId: sender, header: h2, chunk: Data([3])), .awaitingMoreFragments)
        XCTAssertEqual(reassembler.offer(senderId: sender, header: h0, chunk: Data([1])), .awaitingMoreFragments)
        XCTAssertEqual(reassembler.offer(senderId: sender, header: h1, chunk: Data([2])), .complete(Data([1, 2, 3])))
    }

    func testReassembleDuplicateFragmentIsIdempotent() throws {
        let reassembler = MeshFragmentReassembler()
        let sender = try nodeId("0011223344556677")
        let h0 = try MeshFragmentHeader(fragmentSetId: 9, index: 0, total: 2)
        let h1 = try MeshFragmentHeader(fragmentSetId: 9, index: 1, total: 2)

        XCTAssertEqual(reassembler.offer(senderId: sender, header: h0, chunk: Data([1])), .awaitingMoreFragments)
        // Same fragment delivered twice (a flood relay can legitimately do
        // this) — must not error and must not double-count bytes.
        XCTAssertEqual(reassembler.offer(senderId: sender, header: h0, chunk: Data([1])), .awaitingMoreFragments)
        XCTAssertEqual(reassembler.offer(senderId: sender, header: h1, chunk: Data([2])), .complete(Data([1, 2])))
    }

    func testReassembleRejectsTotalMismatchForExistingSet() throws {
        let reassembler = MeshFragmentReassembler()
        let sender = try nodeId("0011223344556677")
        let h0 = try MeshFragmentHeader(fragmentSetId: 3, index: 0, total: 2)
        let hBad = try MeshFragmentHeader(fragmentSetId: 3, index: 1, total: 5)

        XCTAssertEqual(reassembler.offer(senderId: sender, header: h0, chunk: Data([1])), .awaitingMoreFragments)
        if case .rejected = reassembler.offer(senderId: sender, header: hBad, chunk: Data([2])) {
            // expected
        } else {
            XCTFail("expected a rejection for mismatched total")
        }
    }

    func testReassemblePerSetByteCapDropsTheSet() throws {
        let reassembler = MeshFragmentReassembler()
        let sender = try nodeId("0011223344556677")
        let bigChunk = Data(repeating: 0, count: MeshFragmentReassembler.maxBytesPerSet)
        let h0 = try MeshFragmentHeader(fragmentSetId: 1, index: 0, total: 2)
        let h1 = try MeshFragmentHeader(fragmentSetId: 1, index: 1, total: 2)

        XCTAssertEqual(reassembler.offer(senderId: sender, header: h0, chunk: bigChunk), .awaitingMoreFragments)
        if case .rejected = reassembler.offer(senderId: sender, header: h1, chunk: Data([1])) {
            // expected — exceeds the per-set cap
        } else {
            XCTFail("expected per-set cap rejection")
        }
        // The set was discarded, so re-submitting the first fragment starts fresh.
        XCTAssertEqual(reassembler.offer(senderId: sender, header: h0, chunk: Data([9])), .awaitingMoreFragments)
    }

    func testReassembleDifferentSendersDoNotCollideOnSameFragmentSetId() throws {
        let reassembler = MeshFragmentReassembler()
        let senderA = try nodeId("1111111111111111")
        let senderB = try nodeId("2222222222222222")
        let h0 = try MeshFragmentHeader(fragmentSetId: 1, index: 0, total: 1)

        XCTAssertEqual(reassembler.offer(senderId: senderA, header: h0, chunk: Data([0xAA])), .complete(Data([0xAA])))
        XCTAssertEqual(reassembler.offer(senderId: senderB, header: h0, chunk: Data([0xBB])), .complete(Data([0xBB])))
    }

    func testSweepExpiredDropsStaleIncompleteSets() throws {
        let reassembler = MeshFragmentReassembler()
        let sender = try nodeId("0011223344556677")
        let h0 = try MeshFragmentHeader(fragmentSetId: 1, index: 0, total: 2)

        var now: Int64 = 1_000
        reassembler.clock = { now }
        XCTAssertEqual(reassembler.offer(senderId: sender, header: h0, chunk: Data([1])), .awaitingMoreFragments)

        now += MeshFragmentReassembler.defaultSetTimeoutMs + 1
        XCTAssertEqual(reassembler.sweepExpired(), 1)

        // The set is gone — completing it now starts a brand-new set.
        let h1 = try MeshFragmentHeader(fragmentSetId: 1, index: 1, total: 2)
        XCTAssertEqual(reassembler.offer(senderId: sender, header: h1, chunk: Data([2])), .awaitingMoreFragments)
    }

    func testSweepExpiredLeavesFreshSetsAlone() throws {
        let reassembler = MeshFragmentReassembler()
        let sender = try nodeId("0011223344556677")
        let h0 = try MeshFragmentHeader(fragmentSetId: 1, index: 0, total: 2)
        var now: Int64 = 1_000
        reassembler.clock = { now }
        _ = reassembler.offer(senderId: sender, header: h0, chunk: Data([1]))
        now += 10 // well under the timeout
        XCTAssertEqual(reassembler.sweepExpired(), 0)
    }
}
