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
///
/// A failure of either is a failure of the flush, and so of the append that asked for it: the part the record covers is never PUT
/// (WIRE_SPEC 12.8). The one failure of `F_FULLFSYNC` that is tolerated is the file system saying that it does not know the request
/// (`ENOTSUP`, `EINVAL`): `fsync` has then done everything the platform offers.
public struct FileV2SystemDurability: FileV2Durability {
    /// Asks the platform to push the data of a descriptor to stable storage; returns 0, or the `errno` of the failure. A seam, so that
    /// a test can make the request fail (the real one cannot be made to fail on demand).
    public typealias FullSync = @Sendable (Int32) -> Int32

    private let fullSync: FullSync

    public init() {
        self.fullSync = FileV2SystemDurability.platformFullSync
    }

    public init(fullSync: @escaping FullSync) {
        self.fullSync = fullSync
    }

    /// `fcntl(F_FULLFSYNC)` on Apple platforms; nothing on a platform that has no such request (the harness on Linux), where `fsync` is
    /// all there is.
    public static let platformFullSync: FullSync = { descriptor in
        #if canImport(Darwin)
        return fcntl(descriptor, F_FULLFSYNC) == 0 ? 0 : errno
        #else
        _ = descriptor
        return 0
        #endif
    }

    public func flush(file handle: FileHandle) throws {
        do { try handle.synchronize() } catch { throw FileV2SendStoreError.io("sync") }
        try check(fullSync(handle.fileDescriptor))
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
        try check(fullSync(descriptor))
    }

    private func check(_ code: Int32) throws {
        guard code == 0 || code == ENOTSUP || code == EINVAL else { throw FileV2SendStoreError.io("full sync") }
    }
}

/// What the store does to a file or a directory so that it never leaves the device.
public protocol FileV2FileProtection: Sendable {
    /// Marks `url` as excluded from every backup. Throws when the mark could not be set: the store then refuses to hold a journal there.
    func excludeFromBackup(_ url: URL) throws
    /// The iOS data protection class `completeUntilFirstUserAuthentication`. Best effort (a simulator or a file system may refuse it).
    func applyDataProtection(_ url: URL)
}

/// The platform's protection of the journal (WIRE_SPEC 12.8: the transfer state is "never included in a backup").
///
/// On Apple platforms `isExcludedFromBackup` is set and read back; if it cannot be set the error is thrown, so that no journal is
/// ever written where a backup could take it. Other platforms have no such attribute (this code only ships on Apple platforms; Linux
/// is the test harness).
public struct FileV2SystemFileProtection: FileV2FileProtection {
    public init() {}

    public func excludeFromBackup(_ url: URL) throws {
        #if canImport(Darwin)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try target.setResourceValues(values) } catch { throw FileV2SendStoreError.io("backup exclusion") }
        target.removeAllCachedResourceValues()
        guard (try? target.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true else {
            throw FileV2SendStoreError.io("backup exclusion")
        }
        #endif
    }

    public func applyDataProtection(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        #endif
    }
}

/// An exclusive claim on one transfer: whoever holds it is the only one that may run, resume, announce again or cancel that
/// transfer, and the only one that writes its journal. Held for the whole operation and released on every path.
public protocol FileV2SendTransferLock: AnyObject, Sendable {
    /// Gives the claim up. Idempotent. A lock that is dropped without it releases itself.
    func release()
}

/// The file-backed send store: one journal file per transfer in a directory the caller injects (on iOS, a folder of
/// Application Support: app-private, excluded from every backup, readable after the first unlock; the tests use a temporary
/// directory).
///
/// - The directory and every journal are marked `isExcludedFromBackup` (the state holds the wrapped key of the file: it never
///   goes into a backup, WIRE_SPEC 12.2 and 12.8) and, on iOS, protected `completeUntilFirstUserAuthentication` so a transfer
///   can go on in the background after the first unlock. The exclusion is NOT best effort: if it cannot be set the store refuses to
///   start (`init`) or to begin a transfer (`begin`). The Keychain item of a key is `ThisDeviceOnly`, which a restore of an
///   ENCRYPTED backup onto the same device still brings back; the spec's "K MUST NOT be restored from a backup" therefore leans on
///   this exclusion (a restored key without its journal is useless), on `FileV2SendPipeline.recoverOnLaunch` (which destroys the
///   secrets no journal refers to) and on the identity check of the source.
/// - `begin` writes the whole first record to a temporary file, flushes it, renames it and flushes the directory: a transfer
///   either exists with a valid begin record or does not exist.
/// - `append` writes one record at the real end of the file and flushes the file before it returns. A torn or corrupt tail is cut
///   off before the first append of a store instance, so a new record is never written after garbage. Any failure of an append
///   (the write, `fsync`, `F_FULLFSYNC`) drops the open handle and is reported: the next call reopens the file and scans it again.
/// - All operations take one lock inside the instance: appends from parallel workers are serialised, and an append is one `write`
///   and one flush.
/// - ONE WRITER PER TRANSFER, across instances and across processes (the app and an extension that share the directory):
///   `acquireLock` takes `flock(LOCK_EX | LOCK_NB)` on a file of its own, `<id>.lock`, and the pipeline holds it from before the
///   journal is read until the run, the resume, the announce or the cancel has ended. Two instances over one directory would
///   each hold a ledger of tags that does not contain what the other sealed, and the nonce rule (WIRE_SPEC 12.8 rule 2) cannot be
///   kept that way.
public final class FileV2FileSendStore: FileV2SendStore, @unchecked Sendable {

    private static let fileExtension = "qsj"
    private static let temporaryExtension = "tmp"
    private static let lockExtension = "lock"

    public let directory: URL
    private let durability: FileV2Durability
    private let protection: FileV2FileProtection
    private let lock = NSLock()
    private var journals: [String: FileHandle] = [:]

    public init(directory: URL, durability: FileV2Durability = FileV2SystemDurability(),
                protection: FileV2FileProtection = FileV2SystemFileProtection()) throws {
        self.directory = directory
        self.durability = durability
        self.protection = protection
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch { throw FileV2SendStoreError.io("create directory") }
        try protect(directory)
    }

    deinit {
        for handle in journals.values { try? handle.close() }
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
        // Protected while it is still empty: the wrapped key is never in a file a backup could take, not even for a moment.
        try protect(temporary)
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: content)
            try durability.flush(file: handle)
        } catch let error as FileV2SendStoreError {
            throw error
        } catch { throw FileV2SendStoreError.io("write") }
        do { try manager.moveItem(at: temporary, to: final) } catch { throw FileV2SendStoreError.io("rename") }
        finished = true
        try durability.flush(directory: directory)
    }

    public func append(_ event: FileV2SendJournalEvent, to transferID: String) throws {
        guard fileV2IsValidTransferID(transferID) else { throw FileV2SendStoreError.invalidIdentifier }
        let frame = try FileV2JournalFormat.encode(event)
        lock.lock()
        defer { lock.unlock() }
        let handle = try openJournalLocked(transferID)
        do {
            // The real end of the file, not a length remembered from before: whatever is in the file now, the record goes after it.
            try handle.seekToEnd()
            try handle.write(contentsOf: frame)
            try durability.flush(file: handle)
        } catch {
            // The file may now end with a partial record: forget the handle, the next call scans and truncates.
            try? handle.close()
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
            } else if url.pathExtension == FileV2FileSendStore.lockExtension {
                removeIfStale(lockFile: url)
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
        if let handle = journals.removeValue(forKey: transferID) { try? handle.close() }
        let manager = FileManager.default
        for url in [journalURL(transferID), temporaryURL(transferID)] where manager.fileExists(atPath: url.path) {
            do { try manager.removeItem(at: url) } catch { throw FileV2SendStoreError.io("remove") }
        }
        try durability.flush(directory: directory)
    }

    // MARK: The exclusive lock of a transfer

    public func acquireLock(_ transferID: String) throws -> FileV2SendTransferLock {
        guard fileV2IsValidTransferID(transferID) else { throw FileV2SendStoreError.invalidIdentifier }
        let path = lockURL(transferID).path
        // A holder that is done unlinks its file while it still holds the lock. Someone who opened that name just before may get the
        // lock of a file nobody can find any more: it checks, after it has the lock, that the name still leads to the file it locked,
        // and starts again if it does not. Two holders on two different files of the same name are thereby impossible.
        for _ in 0..<16 {
            let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else { throw FileV2SendStoreError.io("lock open") }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                _ = close(descriptor)
                if code == EINTR { continue }
                if code == EWOULDBLOCK || code == EAGAIN { throw FileV2SendStoreError.busy }
                throw FileV2SendStoreError.io("lock")
            }
            var byDescriptor = stat()
            var byName = stat()
            if fstat(descriptor, &byDescriptor) == 0, stat(path, &byName) == 0,
               byDescriptor.st_ino == byName.st_ino, byDescriptor.st_dev == byName.st_dev {
                protection.applyDataProtection(lockURL(transferID))
                return FileV2FileTransferLock(descriptor: descriptor, path: path)
            }
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        throw FileV2SendStoreError.io("lock")
    }

    /// A lock file nobody holds is the leftover of a process that died: remove it. A held one is left alone.
    private func removeIfStale(lockFile url: URL) {
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { return }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        _ = unlink(url.path)
        _ = flock(descriptor, LOCK_UN)
    }

    // MARK: Internals (the lock is held)

    private func journalURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(FileV2FileSendStore.fileExtension)
    }

    private func temporaryURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(FileV2FileSendStore.temporaryExtension)
    }

    private func lockURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(FileV2FileSendStore.lockExtension)
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
    private func openJournalLocked(_ id: String) throws -> FileHandle {
        if let handle = journals[id] { return handle }
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
        journals[id] = handle
        return handle
    }

    /// Backup exclusion (it must succeed) and the iOS data protection class (best effort: a simulator or a file system may refuse it).
    private func protect(_ url: URL) throws {
        try protection.excludeFromBackup(url)
        protection.applyDataProtection(url)
    }
}

/// The `flock` of one transfer on its lock file. Releasing unlinks the file first (while the lock is still held), then unlocks and
/// closes; dropping the object does the same.
private final class FileV2FileTransferLock: FileV2SendTransferLock, @unchecked Sendable {
    private let state = NSLock()
    private var descriptor: Int32
    private let path: String

    init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    func release() {
        state.lock()
        defer { state.unlock() }
        guard descriptor >= 0 else { return }
        _ = unlink(path)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
