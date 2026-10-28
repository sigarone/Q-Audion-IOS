import Foundation
import UniformTypeIdentifiers

/// The hand-over between the share extension and the app.
///
/// The extension runs in a process with a small memory limit and without the encryption or call stack, so it never sends
/// anything. It copies what the user shared into a queue in the shared App Group container, with a small manifest naming the
/// chosen chat, and the app picks the queue up, shows the usual send sheet of that chat and sends through the existing
/// attachment path. The extension also reads the short list of recent chats the app keeps in the same container.
///
/// This file is Foundation only and is compiled into the app and into the extension (no engine, no keys). Nothing that
/// protects a message lives in the shared container: only the shared items until the app takes them, and the names of the
/// recent chats.
public enum ShareLimits {
    /// Items in one share.
    public static let maxItems = 20
    /// One file; larger ones are refused by the extension before anything is copied.
    public static let maxItemBytes: Int64 = 1 << 30
    /// Text or link, in UTF-8 bytes.
    public static let maxTextBytes = 64 * 1024
    /// Shares waiting for the app.
    public static let maxQueuedEntries = 5
    /// A share the app has not taken is dropped after this long.
    public static let entryLifetime: TimeInterval = 24 * 60 * 60
    /// A folder without a manifest (a copy that was interrupted) is dropped after this long.
    public static let partialLifetime: TimeInterval = 60 * 60
    /// Chats offered by the extension.
    public static let maxRecentChats = 20
    /// All the files of one share together.
    public static let maxShareBytes: Int64 = 2 << 30
    /// All the shares waiting for the app together.
    public static let maxQueueBytes: Int64 = 4 << 30
    /// A shared picture the app loads into memory to send (larger ones are sent as files).
    public static let maxInlineImageBytes = 20 * 1024 * 1024
    /// The pictures of one share loaded into memory together.
    public static let maxInlineImageTotal = 100 * 1024 * 1024
}

public enum ShareItemKind: String, Codable, Equatable, Sendable {
    case image
    case video
    case file
    case text
    case url
}

/// One shared item. A file item names a file inside the entry's folder; text and link items carry their text.
public struct ShareItem: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ShareItemKind
    /// File name inside the entry folder (never a path).
    public let fileName: String?
    /// Name to show for a file.
    public let displayName: String?
    /// The text or the link.
    public let text: String?
    public let byteCount: Int64

    public init(id: String = UUID().uuidString, kind: ShareItemKind, fileName: String? = nil, displayName: String? = nil,
                text: String? = nil, byteCount: Int64 = 0) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.displayName = displayName
        self.text = text
        self.byteCount = byteCount
    }
}

/// What the extension writes last, once every file is in place.
public struct ShareEntry: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: String
    public let createdAt: Date
    /// The chosen chat, by the peer's user id.
    public let peerUserId: String
    public let items: [ShareItem]

    public init(version: Int = ShareEntry.currentVersion, id: String, createdAt: Date, peerUserId: String, items: [ShareItem]) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.peerUserId = peerUserId
        self.items = items
    }
}

/// A chat the extension offers.
public struct ShareRecentChat: Codable, Equatable, Sendable {
    public let peerUserId: String
    public let displayName: String
    public let lastActivity: Date

    public init(peerUserId: String, displayName: String, lastActivity: Date) {
        self.peerUserId = peerUserId
        self.displayName = displayName
        self.lastActivity = lastActivity
    }
}

public enum ShareQueueError: Error, Equatable {
    case noContainer
    case queueFull
    case tooManyItems
    case itemTooLarge
    case emptyShare
    case invalidDestination
    case writeFailed
}

/// Names and classes of shared things. Pure, so it is tested without the system.
public enum ShareRules {

    /// A file name that is safe to create inside an entry folder: no directories, no hidden or control characters, a bounded
    /// length that keeps the extension.
    public static func sanitizedFileName(_ raw: String, fallback: String) -> String {
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        name = String(name.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == ".." { return fallback }
        let maxLength = 100
        if name.count > maxLength {
            let ext = (name as NSString).pathExtension
            let keep = max(1, maxLength - (ext.isEmpty ? 0 : ext.count + 1))
            let stem = String((name as NSString).deletingPathExtension.prefix(keep))
            name = ext.isEmpty ? stem : stem + "." + ext
        }
        return name
    }

    /// The kind of a file from the type identifiers its provider registers, most specific first. `nil` when none of them is
    /// something a chat can carry as a file.
    public static func fileKind(forTypeIdentifiers identifiers: [String]) -> ShareItemKind? {
        let types = identifiers.compactMap { UTType($0) }
        if types.isEmpty { return nil }
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        if types.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) { return .video }
        if types.contains(where: { $0.conforms(to: .data) || $0.conforms(to: .item) || $0.conforms(to: .content) }) { return .file }
        return nil
    }

    /// Whether a shared plain string is a web link.
    public static func isWebLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    /// Text that fits the limit, cut on a character boundary.
    public static func clippedText(_ text: String) -> String {
        guard text.utf8.count > ShareLimits.maxTextBytes else { return text }
        var out = ""
        var bytes = 0
        for ch in text {
            let n = String(ch).utf8.count
            if bytes + n > ShareLimits.maxTextBytes { break }
            out.append(ch)
            bytes += n
        }
        return out
    }
}

/// What the app does with a picked-up entry: the files by sort of send, and the text for the composer.
public struct ShareHandoffPlan: Equatable, Sendable {
    public let images: [URL]
    public let videos: [URL]
    public let files: [URL]
    /// Texts and links, one per line, for the composer of the chat.
    public let text: String?

    public var isEmpty: Bool { images.isEmpty && videos.isEmpty && files.isEmpty && (text ?? "").isEmpty }

    public static func make(entry: ShareEntry, folder: URL) -> ShareHandoffPlan {
        var images: [URL] = [], videos: [URL] = [], files: [URL] = [], lines: [String] = []
        for item in entry.items {
            switch item.kind {
            case .text, .url:
                if let t = item.text, !t.isEmpty { lines.append(t) }
            case .image, .video, .file:
                guard let name = item.fileName, !name.isEmpty, !name.contains("/") else { continue }
                let url = folder.appendingPathComponent(name)
                switch item.kind {
                case .image: images.append(url)
                case .video: videos.append(url)
                default: files.append(url)
                }
            }
        }
        return ShareHandoffPlan(images: images, videos: videos, files: files,
                                text: lines.isEmpty ? nil : lines.joined(separator: "\n"))
    }
}

/// The queue and the recent-chats list in the App Group container. `containerURL` is the root; tests pass a temporary folder.
public struct ShareQueueStore {

    public static let appGroupId = "group.com.bcrypto.qaudion.share"
    private static let queueFolder = "share-queue"
    private static let manifestName = "manifest.json"
    private static let recentChatsName = "share-recent-chats.v1.json"
    private static let recentsHiddenName = "share-recents-hidden"

    private let root: URL?
    private let fm = FileManager.default

    public init(containerURL: URL?) { self.root = containerURL }

    public init() {
        self.root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareQueueStore.appGroupId)
    }

    private var queueURL: URL? { root?.appendingPathComponent(Self.queueFolder, isDirectory: true) }

    private static let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]

    // MARK: - Recent chats (the app writes, the extension reads)

    public func writeRecentChats(_ chats: [ShareRecentChat]) {
        guard let root else { return }
        let url = root.appendingPathComponent(Self.recentChatsName)
        let limited = Array(chats.sorted { $0.lastActivity > $1.lastActivity }.prefix(ShareLimits.maxRecentChats))
        if limited.isEmpty { try? fm.removeItem(at: url); return }
        guard let data = try? Self.encoder.encode(limited) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// While the app lock is on, the extension shows no chat names: the app marks the list as hidden (and writes it empty).
    public func setRecentsHidden(_ hidden: Bool) {
        guard let root else { return }
        let url = root.appendingPathComponent(Self.recentsHiddenName)
        if hidden { try? Data().write(to: url, options: [.atomic]) } else { try? fm.removeItem(at: url) }
    }

    public var recentsHidden: Bool {
        guard let root else { return false }
        return fm.fileExists(atPath: root.appendingPathComponent(Self.recentsHiddenName).path)
    }

    public func readRecentChats() -> [ShareRecentChat] {
        guard !recentsHidden else { return [] }
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent(Self.recentChatsName)),
              let chats = try? Self.decoder.decode([ShareRecentChat].self, from: data) else { return [] }
        return Array(chats.prefix(ShareLimits.maxRecentChats))
    }

    // MARK: - Writing an entry (the extension)

    /// Opens the folder an entry is copied into. The folder name starts with the creation time in seconds, so an interrupted
    /// copy can be recognised and dropped later without reading file dates.
    public func beginEntry(now: Date = Date()) throws -> (id: String, folder: URL) {
        guard let queue = queueURL else { throw ShareQueueError.noContainer }
        try ensureQueueFolder(queue)
        purge(now: now)
        let committed = committedEntryFolders(in: queue)
        guard committed.count < ShareLimits.maxQueuedEntries, queuedBytes(of: committed) < ShareLimits.maxQueueBytes else {
            throw ShareQueueError.queueFull
        }
        let id = UUID().uuidString
        let folder = queue.appendingPathComponent("\(Int(now.timeIntervalSince1970))-\(id)", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: Self.protection)
        } catch {
            throw ShareQueueError.writeFailed
        }
        return (id, folder)
    }

    /// Checks the entry and writes its manifest, last: an entry without a manifest does not exist for the app.
    public func commit(_ entry: ShareEntry, in folder: URL) throws {
        guard !entry.items.isEmpty else { throw ShareQueueError.emptyShare }
        guard entry.items.count <= ShareLimits.maxItems else { throw ShareQueueError.tooManyItems }
        guard !entry.peerUserId.isEmpty, entry.peerUserId.count <= 64, !entry.peerUserId.contains("/") else {
            throw ShareQueueError.invalidDestination
        }
        guard entry.items.reduce(Int64(0), { $0 + max(0, $1.byteCount) }) <= ShareLimits.maxShareBytes else {
            throw ShareQueueError.itemTooLarge
        }
        for item in entry.items {
            switch item.kind {
            case .text, .url:
                guard let text = item.text, !text.isEmpty else { throw ShareQueueError.emptyShare }
                guard text.utf8.count <= ShareLimits.maxTextBytes else { throw ShareQueueError.itemTooLarge }
            case .image, .video, .file:
                guard let name = item.fileName, name == ShareRules.sanitizedFileName(name, fallback: ""),
                      fm.fileExists(atPath: folder.appendingPathComponent(name).path),
                      !Self.isSymbolicLink(folder.appendingPathComponent(name)) else { throw ShareQueueError.writeFailed }
                guard item.byteCount <= ShareLimits.maxItemBytes else { throw ShareQueueError.itemTooLarge }
            }
        }
        do {
            let data = try Self.encoder.encode(entry)
            try data.write(to: folder.appendingPathComponent(Self.manifestName),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw ShareQueueError.writeFailed
        }
    }

    /// Removes a folder whose copy failed or was cancelled.
    public func abandon(folder: URL) { try? fm.removeItem(at: folder) }

    // MARK: - Reading entries (the app)

    /// The entries waiting for the app, oldest first, with their folders. Entries of a newer format, with a missing file or
    /// with a file name that leaves the folder are skipped.
    public func pendingEntries(now: Date = Date()) -> [(entry: ShareEntry, folder: URL)] {
        guard let queue = queueURL else { return [] }
        purge(now: now)
        var out: [(ShareEntry, URL)] = []
        for folder in committedEntryFolders(in: queue) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestName)),
                  let entry = try? Self.decoder.decode(ShareEntry.self, from: data),
                  entry.version == ShareEntry.currentVersion, isValid(entry, folder: folder) else { continue }
            out.append((entry, folder))
        }
        return out.sorted { $0.0.createdAt < $1.0.createdAt }.map { (entry: $0.0, folder: $0.1) }
    }

    /// Moves the files of an entry to `destination` (a folder of the app) and removes the entry. Returns the plan over the
    /// moved files, or `nil` when the move failed (the entry is then left in place).
    public func take(_ entry: ShareEntry, from folder: URL, into destination: URL) -> ShareHandoffPlan? {
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in entry.items {
                guard let name = item.fileName else { continue }
                guard !Self.isSymbolicLink(folder.appendingPathComponent(name)) else { throw ShareQueueError.writeFailed }
                try fm.moveItem(at: folder.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        } catch {
            try? fm.removeItem(at: destination)
            return nil
        }
        let plan = ShareHandoffPlan.make(entry: entry, folder: destination)
        try? fm.removeItem(at: folder)
        return plan
    }

    public func remove(folder: URL) { try? fm.removeItem(at: folder) }

    /// Drops expired entries and interrupted copies.
    public func purge(now: Date = Date()) {
        guard let queue = queueURL,
              let names = try? fm.contentsOfDirectory(atPath: queue.path) else { return }
        for name in names {
            let folder = queue.appendingPathComponent(name, isDirectory: true)
            let created = Self.creationSeconds(ofFolderName: name)
            let hasManifest = fm.fileExists(atPath: folder.appendingPathComponent(Self.manifestName).path)
            guard let created else { try? fm.removeItem(at: folder); continue }
            let age = now.timeIntervalSince1970 - created
            if hasManifest ? age > ShareLimits.entryLifetime : age > ShareLimits.partialLifetime {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// Removes the whole queue and the recent-chats list (sign-out, wipe).
    public func removeEverything() {
        if let queue = queueURL { try? fm.removeItem(at: queue) }
        if let root {
            try? fm.removeItem(at: root.appendingPathComponent(Self.recentChatsName))
            try? fm.removeItem(at: root.appendingPathComponent(Self.recentsHiddenName))
        }
    }

    // MARK: - Internals

    static func creationSeconds(ofFolderName name: String) -> TimeInterval? {
        guard let dash = name.firstIndex(of: "-"), let seconds = TimeInterval(name[name.startIndex..<dash]) else { return nil }
        return seconds
    }

    private func ensureQueueFolder(_ queue: URL) throws {
        do {
            try fm.createDirectory(at: queue, withIntermediateDirectories: true, attributes: Self.protection)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = queue
            try? mutable.setResourceValues(values)
        } catch {
            throw ShareQueueError.writeFailed
        }
    }

    private func committedEntryFolders(in queue: URL) -> [URL] {
        guard let names = try? fm.contentsOfDirectory(atPath: queue.path) else { return [] }
        return names.map { queue.appendingPathComponent($0, isDirectory: true) }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(Self.manifestName).path) }
    }

    private func isValid(_ entry: ShareEntry, folder: URL) -> Bool {
        guard UUID(uuidString: entry.id) != nil, !Self.isSymbolicLink(folder),
              !entry.items.isEmpty, entry.items.count <= ShareLimits.maxItems else { return false }
        for item in entry.items {
            switch item.kind {
            case .text, .url:
                if (item.text ?? "").isEmpty { return false }
            case .image, .video, .file:
                guard let name = item.fileName, name == ShareRules.sanitizedFileName(name, fallback: ""),
                      fm.fileExists(atPath: folder.appendingPathComponent(name).path),
                      !Self.isSymbolicLink(folder.appendingPathComponent(name)) else { return false }
            }
        }
        return true
    }

    /// True for a symbolic link (not followed), and for anything whose type cannot be read.
    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true
    }

    /// The declared size of the entries in `folders`.
    private func queuedBytes(of folders: [URL]) -> Int64 {
        var total: Int64 = 0
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestName)),
                  let entry = try? Self.decoder.decode(ShareEntry.self, from: data) else { continue }
            total += entry.items.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }
        }
        return total
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
