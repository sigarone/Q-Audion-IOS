import Foundation
import CryptoKit

/// The log shipper's queue on disk: the chunk waiting for the server's confirmation and the lines behind it,
/// so a restart (or the system ending the app) does not lose what was never delivered.
///
/// One small file in the app's caches folder, written atomically. It is bounded: when the content is over
/// `maxBytes` the OLDEST data goes first (the unconfirmed chunk, then the oldest lines). It is deleted
/// by its owner once nothing is left to deliver, and only the owner decides that after the server's
/// confirmation. Everything handed in has already been through the redactor; this type stores it verbatim and
/// never sees raw log text.
public struct LiveLogDiskQueue: Sendable {

    public struct PendingChunk: Codable, Equatable, Sendable {
        public var filename: String
        public var data: Data
        public var lastSeq: Int64
        public var fileId: String?

        public init(filename: String, data: Data, lastSeq: Int64, fileId: String?) {
            self.filename = filename
            self.data = data
            self.lastSeq = lastSeq
            self.fileId = fileId
        }
    }

    public struct Line: Codable, Equatable, Sendable {
        public var seq: Int64
        public var line: String
        public var disposable: Bool

        public init(seq: Int64, line: String, disposable: Bool) {
            self.seq = seq
            self.line = line
            self.disposable = disposable
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var version: Int = 1
        public var pending: PendingChunk?
        public var lines: [Line]
        /// Who the saved lines belong to (`LiveLogDiskQueue.ownerTag`). A file without it, or with another one,
        /// is never handed to the signed-in account.
        public var owner: String?

        public init(pending: PendingChunk?, lines: [Line], owner: String? = nil) {
            self.pending = pending
            self.lines = lines
            self.owner = owner
        }

        public var isEmpty: Bool { return pending == nil && lines.isEmpty }

        /// Content size the cap is measured on: the chunk bytes plus every line with its newline.
        public var contentBytes: Int {
            var total: Int = pending?.data.count ?? 0
            for item in lines {
                let lineBytes: Int = item.line.utf8.count
                total += lineBytes + 1
            }
            return total
        }
    }

    public static let defaultMaxBytes: Int = 4 * 1024 * 1024
    private static let currentVersion: Int = 1

    public let fileURL: URL
    public let maxBytes: Int

    public init(fileURL: URL, maxBytes: Int = LiveLogDiskQueue.defaultMaxBytes) {
        self.fileURL = fileURL
        self.maxBytes = max(maxBytes, 1)
    }

    /// The queue's file in the caches folder of the app (the system may clear it; nothing there is the only copy
    /// of anything the user needs).
    public static func inCaches(named name: String = "livelog-queue.json") -> LiveLogDiskQueue {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return LiveLogDiskQueue(fileURL: base.appendingPathComponent(name))
    }

    /// `snapshot` cut down to `maxBytes`: the unconfirmed chunk goes first (it is the oldest), then the oldest
    /// lines. `droppedLines` counts the lines lost; a dropped chunk is reported by `droppedChunk`.
    public static func bounded(_ snapshot: Snapshot, maxBytes: Int) -> (snapshot: Snapshot, droppedLines: Int, droppedChunk: Bool) {
        var result = snapshot
        var total = result.contentBytes
        var droppedChunk = false
        if total > maxBytes, let chunk = result.pending {
            total -= chunk.data.count
            result.pending = nil
            droppedChunk = true
        }
        var cut = 0
        while total > maxBytes && cut < result.lines.count {
            let cutBytes: Int = result.lines[cut].line.utf8.count
            total -= cutBytes + 1
            cut += 1
        }
        if cut > 0 { result.lines.removeFirst(cut) }
        return (result, cut, droppedChunk)
    }

    /// Write `snapshot` (cut to the bound first). An empty snapshot removes the file. Returns what the bound
    /// dropped, or nil when the file could not be written.
    @discardableResult
    public func save(_ snapshot: Snapshot) -> (droppedLines: Int, droppedChunk: Bool)? {
        let cut = LiveLogDiskQueue.bounded(snapshot, maxBytes: maxBytes)
        if cut.snapshot.isEmpty {
            delete()
            return (cut.droppedLines, cut.droppedChunk)
        }
        do {
            let encoded = try JSONEncoder().encode(cut.snapshot)
            try encoded.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return (cut.droppedLines, cut.droppedChunk)
        } catch {
            return nil
        }
    }

    /// The saved queue, or nil when there is none or it cannot be trusted (a file that is damaged, of another
    /// version or far over the bound is removed).
    public func load() -> Snapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return nil }
        // Base64 and JSON framing make the file larger than the content it holds.
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let sizeLimit: Int = maxBytes * 2 + 65_536
        guard size > 0, size <= sizeLimit else {
            delete()
            return nil
        }
        guard let raw = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: raw),
              snapshot.version == LiveLogDiskQueue.currentVersion else {
            delete()
            return nil
        }
        return LiveLogDiskQueue.bounded(snapshot, maxBytes: maxBytes).snapshot
    }

    /// Tag of the account a queue belongs to: SHA-256 over the user id and the server base URL, hex. The raw id is
    /// never stored. Nil when nobody is signed in (empty user id).
    public static func ownerTag(userId: String, serverBaseURL: String) -> String? {
        guard !userId.isEmpty else { return nil }
        var base: String = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while base.hasSuffix("/") { base.removeLast() }
        let material: String = userId + "\n" + base
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The saved queue when it belongs to `owner`. With no owner (signed out) or another one the file is deleted and
    /// nothing is returned: lines of one account are never uploaded under another.
    public func loadOwned(by owner: String?) -> Snapshot? {
        guard let owner else {
            delete()
            return nil
        }
        guard let saved = load() else { return nil }
        guard saved.owner == owner else {
            delete()
            return nil
        }
        return saved
    }

    /// What to write for the current state: the chunk waiting for its confirmation plus the backlog BEHIND it.
    /// The chunk's lines are still in the backlog until the server confirms them, so lines up to its last
    /// sequence number are left out here; each line is stored once and a restart cannot ship any twice.
    public static func snapshot(pending: PendingChunk?, backlog: [LiveLogBacklog.Item], owner: String?) -> Snapshot {
        let covered: Int64 = pending?.lastSeq ?? Int64.min
        var lines: [Line] = []
        lines.reserveCapacity(backlog.count)
        for item in backlog where item.seq > covered {
            lines.append(Line(seq: item.seq, line: item.line, disposable: item.disposable))
        }
        return Snapshot(pending: pending, lines: lines, owner: owner)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
