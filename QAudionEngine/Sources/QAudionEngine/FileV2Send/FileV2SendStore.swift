import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How a file or a directory is made durable. Injected so a test can observe the flush and place it relative to other events
/// (the journal-before-PUT ordering of WIRE_SPEC 12.8 is asserted on the event log the instrumented durability writes to).
public protocol FileV2Durability: Sendable {
    /// Flushes everything written to `handle` to stable storage: `fsync`, and `F_FULLFSYNC` where the platform has it.
    func flush(file handle: FileHandle) throws
    /// Flushes the directory entry itself (a created or renamed file survives a crash only after this).
    func flush(directory url: URL) throws
}

/// `fsync` and, on Apple platforms, `F_FULLFSYNC` (the plain `fsync` of iOS only reaches the drive's cache).
public struct FileV2SystemDurability: FileV2Durability {
    public init() {}

    public func flush(file handle: FileHandle) throws {
        do { try handle.synchronize() } catch { throw FileV2SendStoreError.io("sync") }
        #if canImport(Darwin)
        // Best effort: a file system that does not know F_FULLFSYNC (it answers an error) has done what it can with fsync.
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        #endif
    }

    public func flush(directory url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw FileV2SendStoreError.io("open directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            // Some file systems refuse fsync on a directory: nothing more can be done there.
            if errno == EINVAL || errno == ENOTSUP { return }
            throw FileV2SendStoreError.io("sync directory")
        }
        #if canImport(Darwin)
        _ = fcntl(descriptor, F_FULLFSYNC)
        #endif
    }
}

/// The file-backed send store: one journal file per transfer in a directory the caller injects (on iOS, a folder of
/// Application Support: app-private, excluded from every backup, readable after the first unlock; the tests use a temporary
/// directory).
///
/// - The directory and every journal are marked `isExcludedFromBackup` (the state holds the wrapped key of the file: it never
///   goes into a backup, WIRE_SPEC 12.2 and 12.8) and, on iOS, protected `completeUntilFirstUserAuthentication` so a transfer
///   can go on in the background after the first unlock.
/// - `begin` writes the whole first record to a temporary file, flushes it, renames it and flushes the directory: a transfer
///   either exists with a valid begin record or does not exist.
/// - `append` writes one record at the end and flushes the file before it returns. A torn or corrupt tail is cut off before the
///   first append of a store instance, so a new record is never written after garbage. Any failure of an append drops the open
///   handle: the next call reopens the file and scans it again.
/// - All operations take one lock: appends from parallel workers are serialised, and an append is one `write` and one flush.
public final class FileV2FileSendStore: FileV2SendStore, @unchecked Sendable {

    private final class OpenJournal {
        let handle: FileHandle
        /// The length of the file up to the end of the last good record.
        var length: UInt64

        init(handle: FileHandle, length: UInt64) {
            self.handle = handle
            self.length = length
        }
    }

    private static let fileExtension = "qsj"
    private static let temporaryExtension = "tmp"

    public let directory: URL
    private let durability: FileV2Durability
    private let lock = NSLock()
    private var journals: [String: OpenJournal] = [:]

    public init(directory: URL, durability: FileV2Durability = FileV2SystemDurability()) throws {
        self.directory = directory
        self.durability = durability
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch { throw FileV2SendStoreError.io("create directory") }
        FileV2FileSendStore.protect(directory)
    }

    deinit {
        for journal in journals.values { try? journal.handle.close() }
    }

    // MARK: FileV2SendStore

    public func begin(_ record: FileV2SendBeginRecord) throws {
        guard fileV2IsValidTransferID(record.transferID) else { throw FileV2SendStoreError.invalidIdentifier }
        var content = FileV2JournalFormat.headerBytes()
        content.append(try FileV2JournalFormat.encodeBegin(record))

        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        let final = journalURL(record.transferID)
        let temporary = temporaryURL(record.transferID)
        guard !manager.fileExists(atPath: final.path) else { throw FileV2SendStoreError.alreadyExists }
        try? manager.removeItem(at: temporary)
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FileV2SendStoreError.io("create")
        }
        var finished = false
        defer { if !finished { try? manager.removeItem(at: temporary) } }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: content)
            try durability.flush(file: handle)
        } catch let error as FileV2SendStoreError {
            throw error
        } catch { throw FileV2SendStoreError.io("write") }
        FileV2FileSendStore.protect(temporary)
        do { try manager.moveItem(at: temporary, to: final) } catch { throw FileV2SendStoreError.io("rename") }
        finished = true
        try durability.flush(directory: directory)
    }

    public func append(_ event: FileV2SendJournalEvent, to transferID: String) throws {
        guard fileV2IsValidTransferID(transferID) else { throw FileV2SendStoreError.invalidIdentifier }
        let frame = try FileV2JournalFormat.encode(event)
        lock.lock()
        defer { lock.unlock() }
        let journal = try openJournalLocked(transferID)
        do {
            try journal.handle.seek(toOffset: journal.length)
            try journal.handle.write(contentsOf: frame)
            try durability.flush(file: journal.handle)
            journal.length += UInt64(frame.count)
        } catch {
            // The file may now end with a partial record: forget the handle, the next call scans and truncates.
            try? journal.handle.close()
            journals[transferID] = nil
            if let known = error as? FileV2SendStoreError { throw known }
            throw FileV2SendStoreError.io("append")
        }
    }

    public func load(_ transferID: String) throws -> FileV2SendRecovered {
        guard fileV2IsValidTransferID(transferID) else { throw FileV2SendStoreError.invalidIdentifier }
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked(transferID).recovered
    }

    public func listTransferIDs() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        let names: [String]
        do { names = try manager.contentsOfDirectory(atPath: directory.path) } catch { throw FileV2SendStoreError.io("list") }
        var ids: [String] = []
        for name in names.sorted() {
            let url = directory.appendingPathComponent(name)
            if url.pathExtension == FileV2FileSendStore.temporaryExtension {
                // A begin that never reached its rename: not a transfer.
                try? manager.removeItem(at: url)
            } else if url.pathExtension == FileV2FileSendStore.fileExtension {
                let id = url.deletingPathExtension().lastPathComponent
                if fileV2IsValidTransferID(id) { ids.append(id) }
            }
        }
        return ids
    }

    public func remove(_ transferID: String) throws {
        guard fileV2IsValidTransferID(transferID) else { throw FileV2SendStoreError.invalidIdentifier }
        lock.lock()
        defer { lock.unlock() }
        if let journal = journals.removeValue(forKey: transferID) { try? journal.handle.close() }
        let manager = FileManager.default
        for url in [journalURL(transferID), temporaryURL(transferID)] where manager.fileExists(atPath: url.path) {
            do { try manager.removeItem(at: url) } catch { throw FileV2SendStoreError.io("remove") }
        }
        try durability.flush(directory: directory)
    }

    // MARK: Internals (the lock is held)

    private func journalURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(FileV2FileSendStore.fileExtension)
    }

    private func temporaryURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(FileV2FileSendStore.temporaryExtension)
    }

    private func loadLocked(_ id: String) throws -> (recovered: FileV2SendRecovered, validLength: Int) {
        let url = journalURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileV2SendStoreError.notFound }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw FileV2SendStoreError.io("read") }
        let scan = try FileV2JournalFormat.scan([UInt8](data))
        return (try FileV2JournalFormat.replay(scan), scan.validLength)
    }

    /// Opens the journal for appending, cutting off a torn tail first.
    private func openJournalLocked(_ id: String) throws -> OpenJournal {
        if let journal = journals[id] { return journal }
        let loaded = try loadLocked(id)
        let url = journalURL(id)
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
            if loaded.recovered.droppedTailBytes > 0 {
                try handle.truncate(atOffset: UInt64(loaded.validLength))
                try durability.flush(file: handle)
            }
        } catch let error as FileV2SendStoreError {
            throw error
        } catch { throw FileV2SendStoreError.io("open") }
        let journal = OpenJournal(handle: handle, length: UInt64(loaded.validLength))
        journals[id] = journal
        return journal
    }

    /// Backup exclusion (always) and the iOS data protection class (best effort: a simulator or a file system may refuse it).
    private static func protect(_ url: URL) {
        #if canImport(Darwin)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        #endif
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        #endif
    }
}
