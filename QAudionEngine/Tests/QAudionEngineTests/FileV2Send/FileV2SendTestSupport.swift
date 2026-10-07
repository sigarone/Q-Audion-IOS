import XCTest
@testable import QAudionEngine

// Helpers shared by the tests of the file transfer v2 send store and pipeline.

/// An ordered log that the instrumented store, durability and server of one test all write to, so a test can assert what
/// happened BEFORE what (the journal ordering of WIRE_SPEC 12.8).
final class SendEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ event: String) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func clear() {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }
}

/// `FileV2Durability` that records every flush in the shared log, with the size the file had when it was flushed, and then does
/// the real flush.
final class RecordingDurability: FileV2Durability, @unchecked Sendable {
    let log: SendEventLog
    private let inner: FileV2Durability
    private let lock = NSLock()
    private var fileFlushes = 0
    private var directoryFlushes = 0

    init(log: SendEventLog = SendEventLog(), inner: FileV2Durability = FileV2SystemDurability()) {
        self.log = log
        self.inner = inner
    }

    func flush(file handle: FileHandle) throws {
        let size = (try? handle.offset()) ?? 0
        lock.lock()
        fileFlushes += 1
        lock.unlock()
        log.add("fsync.file(size=\(size))")
        try inner.flush(file: handle)
    }

    func flush(directory url: URL) throws {
        lock.lock()
        directoryFlushes += 1
        lock.unlock()
        log.add("fsync.directory")
        try inner.flush(directory: url)
    }

    var fileFlushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fileFlushes
    }

    var directoryFlushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return directoryFlushes
    }
}

/// A durability that does nothing: for the tests that move gigabytes and would otherwise spend their time in `F_FULLFSYNC`.
struct NoopDurability: FileV2Durability {
    func flush(file handle: FileHandle) throws {}
    func flush(directory url: URL) throws {}
}

enum SendStoreFixtures {

    static let transferID = "11111111-2222-3333-4444-555555555555"

    static func begin(id: String = SendStoreFixtures.transferID, fileID: Data = Data(repeating: 0xA1, count: 16),
                      header: Data = Data(repeating: 0xB2, count: 64), wrappedKey: Data = Data(repeating: 0xC3, count: 16),
                      size: UInt64 = 3_000_000, locator: String = "/tmp/source.bin", modifiedMs: Int64 = 1_700_000_000_123,
                      conversation: FileV2Conversation = .direct(userID: "user-bob"),
                      metadata: FileV2SendMetadata = FileV2SendMetadata(kind: .file, name: "report.pdf",
                                                                       mimeType: "application/pdf")) -> FileV2SendBeginRecord {
        FileV2SendBeginRecord(transferID: id, createdMs: 1_700_000_000_000, fileID: fileID, header: header,
                              wrappedKey: wrappedKey, plaintextSize: size,
                              source: FileV2SourceIdentity(locator: locator, size: size, modifiedMs: modifiedMs),
                              conversation: conversation, metadata: metadata)
    }

    static func tag(_ seed: UInt8) -> Data { Data(repeating: seed, count: FileV2.tagSize) }

    static func tags(part: Int, chunks: Range<Int>) -> FileV2SendJournalEvent {
        .tags(part: part, entries: chunks.map { FileV2SendTag(index: $0, tag: tag(UInt8($0 & 0xFF))) })
    }

    static func objectRecord(obj: String = "0a1b2c3d-0000-4000-8000-0123456789ab") -> FileV2SendObjectRecord {
        FileV2SendObjectRecord(obj: obj, blobLength: 3_000_000 + 64 + 48, parts: 1)
    }

    static func tokenRecord() -> FileV2SendTokenRecord {
        FileV2SendTokenRecord(wrappedValue: Data(repeating: 0xD4, count: 16), exp: 1_700_000_999_000, max: 30, scope: "user")
    }

    /// The text of any value as `String(describing:)` and as a `dump`, which is what a log line or a debugger shows.
    static func printed(_ value: Any) -> String {
        var dumped = ""
        dump(value, to: &dumped)
        return String(describing: value) + "\n" + dumped
    }

    static func fileBytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }
}
