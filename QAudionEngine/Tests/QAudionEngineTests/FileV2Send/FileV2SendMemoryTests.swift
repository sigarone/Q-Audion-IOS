import XCTest
import CryptoKit
@testable import QAudionEngine

/// Memory does not depend on the size of the file: a source of the largest size the format allows, 5 GiB, is read, sealed and uploaded a chunk
/// and a part at a time, with a synthetic source that never exists in full and a server that keeps nothing.
final class FileV2SendMemoryTests: XCTestCase {

    /// A server that stores nothing. It checks every part body against its exact length and its digest, remembers which parts it saw, and
    /// samples the resident memory of the process at every part: the peak is what a streaming sender must keep small.
    final class DiscardingServer: FileV2Server, @unchecked Sendable {
        private let lock = NSLock()
        private var seen = Set<Int>()
        private var bytes: Int64 = 0
        private var peakResident: UInt64 = 0
        private var wrongBodies = 0
        private var blobLength: Int64 = 0

        var received: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
        var receivedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
        var peakResidentBytes: UInt64 { lock.lock(); defer { lock.unlock() }; return peakResident }
        var bodiesThatWereWrong: Int { lock.lock(); defer { lock.unlock() }; return wrongBodies }

        func create(_ request: FileV2CreateRequest) async throws -> FileV2Created {
            lock.lock()
            blobLength = request.blobLength
            lock.unlock()
            let parts = FileV2Wire.partCount(blobLength: request.blobLength)
            return FileV2Created(obj: "11111111-2222-4333-8444-555555555555", blobLength: request.blobLength, partSize: request.partSize,
                                 parts: parts, parallelism: 6, maxParallelism: 8,
                                 token: FileV2IssuedToken(v: String(repeating: "a", count: 64), exp: 1_900_000_000_000, max: 30, scope: "user"),
                                 existing: false, received: 0, complete: false)
        }

        func putPart(obj: String, part: Int, body: Data, sha256: Data) async throws -> FileV2PutResult {
            let expected = FileV2Wire.partLength(blobLength: blobLength, part: part)
            let ok = body.count == expected && Data(SHA256.hash(data: body)) == sha256
            let resident = FileV2TestSupport.residentMemoryBytes() ?? 0
            lock.lock()
            if !ok { wrongBodies += 1 }
            seen.insert(part)
            bytes += Int64(body.count)
            peakResident = max(peakResident, resident)
            let count = seen.count
            lock.unlock()
            return FileV2PutResult(part: part, duplicate: false, received: count, parts: FileV2Wire.partCount(blobLength: blobLength))
        }

        func partsMap(obj: String) async throws -> FileV2PartsMap { throw FileV2ServerError(status: 500, code: "storage_error") }

        func complete(obj: String) async throws {
            guard received == FileV2Wire.partCount(blobLength: blobLength) else { throw FileV2ServerError(status: 409, code: "incomplete") }
        }

        func delete(obj: String) async throws {}

        func issueToken(obj: String, scope: FileV2TokenRequest) async throws -> FileV2IssuedToken {
            throw FileV2ServerError(status: 500, code: "storage_error")
        }

        func listUnfinished(limit: Int?, after: String?) async throws -> FileV2UnfinishedPage {
            FileV2UnfinishedPage(objects: [], next: nil)
        }

        func deleteUnfinished() async throws -> FileV2BulkDeleteResult { FileV2BulkDeleteResult(deleted: 0, freedBytes: 0) }

        func fetchRange(obj: String, from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?, waitSeconds: Int) async throws
            -> FileV2RangeResult {
            throw FileV2ServerError(status: 500, code: "storage_error")
        }
    }

    func testAFiveGiBSourceIsStreamedWithMemoryThatDoesNotDependOnItsSize() async throws {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self).appendingPathComponent("send", isDirectory: true)
        let log = SendEventLog()
        let store = InstrumentedStore(inner: try FileV2FileSendStore(directory: directory, durability: NoopDurability()), log: log)
        let server = DiscardingServer()
        let wrapper = FileV2InMemorySecretWrapper()
        let channel = RecordingChannel(log: log)
        let sources = TestSourceProvider()
        let source = GeneratedSource(size: FileV2.maxSize)                              // exactly MAX_SIZE: 5 GiB, 5120 chunks, 640 parts
        sources.register(source)
        var configuration = FileV2SendConfiguration()
        configuration.availableMemoryMiB = 1024
        let deps = FileV2SendDependencies(server: server, store: store, secrets: wrapper, sources: sources, channel: channel)
        let pipeline = FileV2SendPipeline(dependencies: deps, configuration: configuration)

        // At the hand-over of the descriptor, the journal holds the tag of every chunk of the 5 GiB file.
        let atAnnounce = FileV2Locked((tags: 0, journalBytes: 0))
        channel.setHook { _ in
            let tags = (try? store.load("five-gib").tags.count) ?? -1
            let size = ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("five-gib.qsj").path)[.size]) as? NSNumber)?.intValue ?? -1
            atAnnounce.withValue { $0 = (tags, size) }
        }

        let baseline = FileV2TestSupport.residentMemoryBytes() ?? 0
        let started = Date()
        let result = await pipeline.send(FileV2SendRequest(transferID: "five-gib", source: source, conversation: .direct(userID: "bob"),
                                                           metadata: FileV2SendMetadata(kind: .video, name: "huge.mov")))
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(result, .sentOk, "took \(seconds) s")

        // Every part arrived whole and intact, 640 of them.
        XCTAssertEqual(server.received, FileV2Wire.maxParts)
        XCTAssertEqual(server.bodiesThatWereWrong, 0)
        XCTAssertEqual(server.receivedBytes, Int64(FileV2.maxBlob) - Int64(FileV2.headerLength))
        let descriptor = try FileV2Descriptor.parse(try XCTUnwrap(channel.announced.first?.body))
        XCTAssertEqual(descriptor.size, FileV2.maxSize)
        XCTAssertEqual(descriptor.header.totalChunks, FileV2.maxChunks)

        // The journal is small whatever the file: 5120 tags of 16 bytes and the per-part records, a few hundred kilobytes at most.
        let seen = atAnnounce.withValue { $0 }
        XCTAssertEqual(seen.tags, FileV2.maxChunks)
        XCTAssertGreaterThan(seen.journalBytes, FileV2.maxChunks * FileV2.tagSize)
        XCTAssertLessThan(seen.journalBytes, 400 * 1024)

        // Memory: the pipeline's own count of what it held stays inside the budget, and the process did not grow by anything like the size of
        // the file (the file is 5 GiB, the bound here is 512 MiB).
        let budget = try FileV2MemBudget(memoryMiB: 1024, perWorkerExtraBytes: FileV2SendContext.perWorkerExtraBytes)
        let diagnostics = pipeline.diagnostics
        XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, budget.budgetBytes)
        XCTAssertLessThanOrEqual(diagnostics.peakConcurrentParts, budget.maxParallelism)
        XCTAssertGreaterThanOrEqual(diagnostics.peakConcurrentParts, 1)
        if baseline > 0, server.peakResidentBytes > 0 {
            let growth = server.peakResidentBytes > baseline ? server.peakResidentBytes - baseline : 0
            XCTAssertLessThan(growth, 512 << 20, "the process grew by \(growth >> 20) MiB sending 5 GiB")
        }
        XCTAssertEqual(try store.listTransferIDs(), [])
        XCTAssertEqual(wrapper.count, 0)
    }
}
