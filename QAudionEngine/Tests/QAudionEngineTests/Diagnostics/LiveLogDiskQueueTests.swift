import XCTest
@testable import QAudionEngine

final class LiveLogDiskQueueTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func queue(maxBytes: Int = LiveLogDiskQueue.defaultMaxBytes) -> LiveLogDiskQueue {
        LiveLogDiskQueue(fileURL: directory.appendingPathComponent("q.json"), maxBytes: maxBytes)
    }

    private func lines(_ range: ClosedRange<Int64>, size: Int = 10) -> [LiveLogDiskQueue.Line] {
        range.map { LiveLogDiskQueue.Line(seq: $0, line: String(repeating: "x", count: size), disposable: $0 % 2 == 0) }
    }

    func test_savedQueueComesBackIdentical() {
        let q = queue()
        let chunk = LiveLogDiskQueue.PendingChunk(filename: "c-1.log", data: Data([1, 2, 3]), lastSeq: 7, fileId: "up-1")
        let snapshot = LiveLogDiskQueue.Snapshot(pending: chunk, lines: lines(8...12))
        XCTAssertNotNil(q.save(snapshot))
        XCTAssertEqual(q.load(), snapshot)
    }

    func test_missingFileLoadsNothing() {
        XCTAssertNil(queue().load())
    }

    func test_emptySnapshotRemovesTheFile() {
        let q = queue()
        q.save(LiveLogDiskQueue.Snapshot(pending: nil, lines: lines(1...2)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.fileURL.path))
        q.save(LiveLogDiskQueue.Snapshot(pending: nil, lines: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.fileURL.path))
        XCTAssertNil(q.load())
    }

    func test_fileSurvivesUntilExplicitlyConfirmedAndDeleted() {
        let q = queue()
        let chunk = LiveLogDiskQueue.PendingChunk(filename: "c.log", data: Data([9]), lastSeq: 1, fileId: nil)
        q.save(LiveLogDiskQueue.Snapshot(pending: chunk, lines: []))
        XCTAssertNotNil(q.load(), "an unconfirmed chunk stays on disk")
        q.save(LiveLogDiskQueue.Snapshot(pending: nil, lines: []))
        XCTAssertNil(q.load(), "after the confirmation nothing is left")
    }

    func test_capDropsTheOldestLinesFirst() {
        let q = queue(maxBytes: 100)
        let result = q.save(LiveLogDiskQueue.Snapshot(pending: nil, lines: lines(1...20)))
        let loaded = q.load()
        XCTAssertEqual(result?.droppedLines, 11, "20 lines of 11 bytes against a cap of 100 keep 9")
        XCTAssertEqual(loaded?.lines.map(\.seq), Array(12...20))
        XCTAssertLessThanOrEqual(loaded?.contentBytes ?? .max, 100)
    }

    func test_capDropsTheOldChunkBeforeTheLines() {
        let q = queue(maxBytes: 150)
        let chunk = LiveLogDiskQueue.PendingChunk(filename: "big.log", data: Data(count: 120), lastSeq: 5, fileId: nil)
        let result = q.save(LiveLogDiskQueue.Snapshot(pending: chunk, lines: lines(6...10)))
        XCTAssertEqual(result?.droppedChunk, true)
        XCTAssertEqual(result?.droppedLines, 0)
        XCTAssertNil(q.load()?.pending)
        XCTAssertEqual(q.load()?.lines.count, 5)
    }

    func test_damagedFileIsIgnoredAndRemoved() throws {
        let q = queue()
        try Data("not json".utf8).write(to: q.fileURL)
        XCTAssertNil(q.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.fileURL.path))
    }

    func test_fileFarOverTheCapIsNotLoaded() throws {
        let q = queue(maxBytes: 100)
        try Data(count: 400 * 1024).write(to: q.fileURL)
        XCTAssertNil(q.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.fileURL.path))
    }

    func test_linesAreStoredVerbatimSoOnlyRedactedTextEverReachesTheDisk() throws {
        let q = queue()
        q.save(LiveLogDiskQueue.Snapshot(pending: nil, lines: [LiveLogDiskQueue.Line(seq: 1, line: "{\"m\":\"token=[redacted]\"}", disposable: false)]))
        let raw = try String(contentsOf: q.fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("redacted"))
        XCTAssertFalse(raw.contains("secret-value"))
    }

    func test_backlogExportsItsLiveLinesAndRestoredStateAcceptsTheChunk() {
        var backlog = LiveLogBacklog(maxEntries: 10, maxBytes: 1000)
        backlog.append(seq: 1, line: "a")
        backlog.append(seq: 2, line: "b", disposable: true)
        backlog.removeThrough(seq: 1)
        XCTAssertEqual(backlog.liveItems().map(\.seq), [2])
        var state = LiveLogUploadState()
        state.restore(filename: "f.log", data: Data([1]), lastSeq: -1, fileId: "id")
        XCTAssertEqual(state.pending?.fileId, "id")
        state.restore(filename: "g.log", data: Data([2]), lastSeq: -2, fileId: nil)
        XCTAssertEqual(state.pending?.filename, "f.log", "a pending chunk is never replaced")
        XCTAssertTrue(state.confirm(throughSeq: -1))
    }

    // MARK: - Owner of the saved queue

    private func ownedSnapshot(owner: String?) -> LiveLogDiskQueue.Snapshot {
        LiveLogDiskQueue.Snapshot(pending: nil, lines: lines(1...3), owner: owner)
    }

    func test_ownerTagIsStableHexAndNeverTheRawId() {
        let a = LiveLogDiskQueue.ownerTag(userId: "user-42", serverBaseURL: "https://a.example/")
        XCTAssertEqual(a, LiveLogDiskQueue.ownerTag(userId: "user-42", serverBaseURL: "HTTPS://a.example"))
        XCTAssertNotEqual(a, LiveLogDiskQueue.ownerTag(userId: "user-43", serverBaseURL: "https://a.example"))
        XCTAssertNotEqual(a, LiveLogDiskQueue.ownerTag(userId: "user-42", serverBaseURL: "https://b.example"))
        XCTAssertEqual(a?.count, 64)
        XCTAssertFalse(a?.contains("user-42") ?? true)
        XCTAssertNil(LiveLogDiskQueue.ownerTag(userId: "", serverBaseURL: "https://a.example"))
    }

    func test_queueOfTheSameOwnerIsRestored() throws {
        let q = queue()
        let owner = try XCTUnwrap(LiveLogDiskQueue.ownerTag(userId: "u1", serverBaseURL: "https://a.example"))
        q.save(ownedSnapshot(owner: owner))
        XCTAssertEqual(q.loadOwned(by: owner)?.lines.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.fileURL.path))
    }

    func test_queueOfAnotherOwnerIsDeletedNotRestored() throws {
        let q = queue()
        let old = try XCTUnwrap(LiveLogDiskQueue.ownerTag(userId: "u1", serverBaseURL: "https://a.example"))
        let new = try XCTUnwrap(LiveLogDiskQueue.ownerTag(userId: "u2", serverBaseURL: "https://a.example"))
        q.save(ownedSnapshot(owner: old))
        XCTAssertNil(q.loadOwned(by: new))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.fileURL.path))
    }

    func test_queueWithoutOwnerIsDeletedNotRestored() throws {
        let q = queue()
        let owner = try XCTUnwrap(LiveLogDiskQueue.ownerTag(userId: "u1", serverBaseURL: "https://a.example"))
        q.save(ownedSnapshot(owner: nil))
        XCTAssertNil(q.loadOwned(by: owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.fileURL.path))
    }

    func test_signedOutDeletesTheQueue() throws {
        let q = queue()
        let owner = try XCTUnwrap(LiveLogDiskQueue.ownerTag(userId: "u1", serverBaseURL: "https://a.example"))
        q.save(ownedSnapshot(owner: owner))
        XCTAssertNil(q.loadOwned(by: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.fileURL.path))
    }

    // MARK: - Each line once

    func test_persistedLinesOfThePendingChunkAreNotStoredTwice() throws {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 10_000)
        for seq in Int64(1)...Int64(6) { backlog.append(seq: seq, line: "line-" + String(seq)) }
        let batch = try XCTUnwrap(backlog.peekBatch(maxLines: 4, byteBudget: 10_000))
        XCTAssertEqual(batch.lastSeq, 4)
        var state = LiveLogUploadState()
        state.start(filename: "c.log", data: Data(batch.lines.joined(separator: "\n").utf8), lastSeq: batch.lastSeq)
        let pending = try XCTUnwrap(state.pending)
        let chunk = LiveLogDiskQueue.PendingChunk(filename: pending.filename, data: pending.data,
                                                  lastSeq: pending.lastSeq, fileId: pending.fileId)
        let owner = "owner-tag"
        let q = queue()
        q.save(LiveLogDiskQueue.snapshot(pending: chunk, backlog: backlog.liveItems(), owner: owner))

        let restored = try XCTUnwrap(q.loadOwned(by: owner))
        XCTAssertEqual(restored.pending?.lastSeq, 4)
        XCTAssertEqual(restored.lines.map(\.seq), [5, 6], "lines 1-4 live in the chunk only")

        // Restart: chunk + lines are what is shipped; every line shows up exactly once.
        let shipped = String(decoding: restored.pending?.data ?? Data(), as: UTF8.self)
            .split(separator: "\n").map(String.init) + restored.lines.map(\.line)
        XCTAssertEqual(shipped, (1...6).map { "line-" + String($0) })
    }

    func test_withoutPendingChunkEveryBacklogLineIsStored() {
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 10_000)
        for seq in Int64(1)...Int64(3) { backlog.append(seq: seq, line: "x") }
        let snapshot = LiveLogDiskQueue.snapshot(pending: nil, backlog: backlog.liveItems(), owner: "o")
        XCTAssertEqual(snapshot.lines.map(\.seq), [1, 2, 3])
    }

    func test_restoredChunkSavedAgainKeepsAllRestoredLines() {
        // After a restart the chunk's last seq sits below every restored line, so none is left out.
        let chunk = LiveLogDiskQueue.PendingChunk(filename: "c.log", data: Data([1]), lastSeq: -4, fileId: nil)
        var backlog = LiveLogBacklog(maxEntries: 100, maxBytes: 10_000)
        backlog.append(seq: -3, line: "a")
        backlog.append(seq: -2, line: "b")
        let snapshot = LiveLogDiskQueue.snapshot(pending: chunk, backlog: backlog.liveItems(), owner: "o")
        XCTAssertEqual(snapshot.lines.map(\.seq), [-3, -2])
    }
}
