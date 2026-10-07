import XCTest
@testable import QAudionEngine

/// WIRE_SPEC 12.8: the journal holds `T[i]` DURABLY BEFORE the chunk's part is PUT. The pipeline, the instrumented store and the fake server
/// share one event log; these tests read it.
final class FileV2SendJournalOrderTests: XCTestCase {

    private func sequentialRig() throws -> SendRig {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1
        return rig
    }

    func testEveryPartIsPutOnlyAfterItsTagsAreAppendedAndFlushed() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "order"))
        XCTAssertEqual(result, .sentOk)
        let events = rig.log.events

        // The shape of the log for each part: the append starts, the file is flushed, the append returns, and only then the PUT starts.
        let totalChunks = try rig.lastDescriptor().header.totalChunks
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(events, totalChunks: totalChunks), [])
        XCTAssertEqual(SendEventAnalysis.everyTagAppendIsFlushed(events), [])
        for part in 0..<3 {
            let first = part * FileV2Wire.chunksPerPart
            let chunks = (first..<min(first + FileV2Wire.chunksPerPart, totalChunks)).map(String.init).joined(separator: ",")
            let began = try XCTUnwrap(events.firstIndex(of: "journal.tags part=\(part) chunks=\(chunks).begin"), "part \(part)")
            let done = try XCTUnwrap(events.firstIndex(of: "journal.tags part=\(part) chunks=\(chunks).done"), "part \(part)")
            let put = try XCTUnwrap(events.firstIndex(of: "server.put.start part=\(part)"), "part \(part)")
            let flushes = events[began..<done].filter { $0.hasPrefix("fsync.file") }
            XCTAssertEqual(flushes.count, 1, "part \(part): one flush between the start and the end of the append")
            XCTAssertLessThan(began, done)
            XCTAssertLessThan(done, put, "part \(part): the tags are durable before the PUT")
        }
        // The first flush of a file comes with the begin record, then one per tag append, per object, per token, per part done, per phase.
        XCTAssertGreaterThanOrEqual(rig.durability.fileFlushCount, 3 + 3)
    }

    func testTheCheckersSeeAViolation() {
        let late = ["journal.tags part=0 chunks=0,1,2,3,4,5,6,7.begin", "fsync.file(size=100)", "server.put.start part=0",
                    "journal.tags part=0 chunks=0,1,2,3,4,5,6,7.done"]
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(late, totalChunks: 8).count, 1, "a PUT before the append returned")

        let partial = ["journal.tags part=0 chunks=0,1,2,3.done", "server.put.start part=0"]
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(partial, totalChunks: 8).count, 1, "tags for half of the chunks")

        let none = ["server.put.start part=1"]
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(none, totalChunks: 17).count, 1)

        let covered = ["journal.tags part=1 chunks=8,9,10,11,12,13,14,15.done", "server.put.start part=1"]
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(covered, totalChunks: 17), [])

        // The last part is short: its needed chunks end at the last chunk of the file.
        let last = ["journal.tags part=2 chunks=16.done", "server.put.start part=2"]
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(last, totalChunks: 17), [])

        // An append that returned without a flush is flagged.
        let unflushed = ["journal.tags part=0 chunks=0.begin", "journal.tags part=0 chunks=0.done"]
        XCTAssertEqual(SendEventAnalysis.everyTagAppendIsFlushed(unflushed).count, 1)
        let flushed = ["journal.tags part=0 chunks=0.begin", "fsync.file(size=9)", "journal.tags part=0 chunks=0.done"]
        XCTAssertEqual(SendEventAnalysis.everyTagAppendIsFlushed(flushed), [])
    }

    func testIfTheTagsCannotBeMadeDurableThePartIsNeverPut() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let store = try rig.makeStore()
        store.failNextTagAppends(1)                                  // the disk refuses the first tags record
        let result = await (try rig.makePipeline(store: store)).send(rig.makeRequest(source, id: "disk-full"))
        assertFailure(result, .storage)
        XCTAssertEqual(rig.server.puts.count, 0, "no PUT without durable tags")
        XCTAssertEqual(try rig.makeStore().load("disk-full").tags.count, 0)

        // The state is kept (nothing was lost), and when the disk works again the transfer goes on.
        let again = await (try rig.makePipeline()).resume(transferID: "disk-full")
        XCTAssertEqual(again, .sentOk)
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(rig.log.events, totalChunks: try rig.lastDescriptor().header.totalChunks), [])
    }

    func testWithParallelWorkersEveryPutIsStillCoveredByDurableTags() async throws {
        let rig = try SendRig(self)
        rig.fake.injectDelay(.putPart, ms: 20)                      // real time: the parts overlap
        let source = GeneratedSource(size: 6 * UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 5)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "parallel-order"))
        XCTAssertEqual(result, .sentOk)
        XCTAssertGreaterThanOrEqual(rig.fake.calls.filter { $0.op == .putPart }.count, 7)
        let descriptor = try rig.lastDescriptor()
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(rig.log.events, totalChunks: descriptor.header.totalChunks), [])
        try rig.assertBlobEqualsOneShot(descriptor: descriptor, source: source)
        rig.assertNoChunkWasEverTransmittedWithADifferentTag()
    }

    func testAResumedTransferJournalsOnlyTheTagsItDoesNotHaveYet() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: false))
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "no-duplicates"))
        rig.server.revive()
        let store = try rig.makeStore()
        let result = await (try rig.makePipeline(store: store)).resume(transferID: "no-duplicates")
        XCTAssertEqual(result, .sentOk)
        // The second run sealed part 1 again (its tags were journaled before the crash) and appended nothing for it: only part 2's tags are new.
        let appended = store.events.compactMap { event -> [Int]? in
            if case .tags(_, let entries) = event { return entries.map { $0.index } }
            return nil
        }
        XCTAssertEqual(appended, [[16]])
    }
}
