import Foundation
import QAudionEngine

/// The copy of a file kept for a message held for Bluetooth only, so the file can still be sent after the app was closed and
/// opened again (the user may answer days later). Kept in the app's own Application Support directory, excluded from backups,
/// one directory per message row. Removed after the send, when the held row is deleted, at its ephemeral expiry (all three through
/// `sweepOrphans`, which removes the directory of any row that is no longer held or retryable), and at startup. A send that failed
/// keeps its copy for the retry.
enum BluetoothHeldFiles {

    /// Rows with an upload running from a kept copy. The sweep leaves their directories alone, so a long upload never loses its
    /// file; `finish` removes the id and the directory when the upload ends.
    private static let useLock = NSLock()
    nonisolated(unsafe) private static var inUse: Set<UUID> = []

    static func beginUse(rowId: UUID) {
        useLock.lock()
        inUse.insert(rowId)
        useLock.unlock()
    }

    static func isInUse(rowId: UUID) -> Bool {
        useLock.lock()
        defer { useLock.unlock() }
        return inUse.contains(rowId)
    }

    /// The upload from the kept copy failed for good: the id leaves the in-use set and the directory STAYS, so the retry still has
    /// its file. Only a successful send (`finish`), an explicit delete of the row or its expiry remove it.
    static func endUse(rowId: UUID) {
        useLock.lock()
        inUse.remove(rowId)
        useLock.unlock()
    }

    /// The failed send has a row of its own (a document gets a new row id): the kept copy moves to that row's directory, which the
    /// sweep treats as live while the row exists and can be retried. Returns the new location of the file.
    @discardableResult
    static func adopt(from oldRowId: UUID, to newRowId: UUID) -> URL? {
        guard oldRowId != newRowId else { return heldURL(rowId: oldRowId) }
        guard let from = directory(rowId: oldRowId), let to = directory(rowId: newRowId) else { return nil }
        try? FileManager.default.removeItem(at: to)
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            return nil
        }
        return heldURL(rowId: newRowId)
    }

    /// The upload from the kept copy ended with a successful send: the id leaves the in-use set and the directory goes.
    static func finish(rowId: UUID) {
        useLock.lock()
        inUse.remove(rowId)
        useLock.unlock()
        remove(rowId: rowId)
    }

    private static var base: URL? {
        guard var dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        dir.appendPathComponent("BluetoothHeld", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    private static func directory(rowId: UUID) -> URL? {
        base?.appendingPathComponent(rowId.uuidString, isDirectory: true)
    }

    /// Copies `sourceURL` into the row's directory and returns the copy, or nil when it could not be kept.
    static func keep(sourceURL: URL, rowId: UUID) -> URL? {
        guard let dir = directory(rowId: rowId) else { return nil }
        try? FileManager.default.removeItem(at: dir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(sourceURL.lastPathComponent.isEmpty ? "file" : sourceURL.lastPathComponent)
            try FileManager.default.copyItem(at: sourceURL, to: target)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableTarget = target
            try? mutableTarget.setResourceValues(values)
            return target
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// The kept copy of the row's file, if there is one.
    static func heldURL(rowId: UUID) -> URL? {
        guard let dir = directory(rowId: rowId),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let name = names.sorted().first else { return nil }
        return dir.appendingPathComponent(name)
    }

    static func remove(rowId: UUID) {
        guard let dir = directory(rowId: rowId) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Removes the directory of every row that is no longer held (sent, deleted, expired) and any stray entry.
    static func sweepOrphans(heldRowIds: Set<UUID>) {
        guard let base, let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        for name in names {
            if let id = UUID(uuidString: name), heldRowIds.contains(id) || isInUse(rowId: id) { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    @MainActor
    static func sweepOrphans() {
        sweepOrphans(heldRowIds: ConversationStore().retainedHeldFileRowIds())
    }
}
