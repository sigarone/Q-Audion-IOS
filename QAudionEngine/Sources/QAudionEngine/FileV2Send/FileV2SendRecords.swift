import Foundation

// File transfer v2, step 2b: the SEND STATE STORE (WIRE_SPEC 12.8).
//
// A transfer's local state is ONE append-only journal file (FileV2Journal.swift, FileV2SendStore.swift). The records below
// are what it holds. Nothing here is secret in the clear: the file key `K` and the download token are held by a
// `FileV2SecretWrapper` (the Keychain, `ThisDeviceOnly`, in production) and the journal keeps only the opaque blob it
// hands back. The descriptor (which carries K and the token) is never stored: it is rebuilt from the unwrapped values when it
// is needed.
//
// Every public type here that holds an identifier prints a redacted `description` and `dump`: at most 8 characters of an
// id, never a key, a tag, a token, a path or a file name.

/// The conversation a file is sent to: it decides the download token's scope (a recipient, or a group) and where the
/// descriptor goes. `id` is the chat layer's user or group identifier; it is never printed in full.
public struct FileV2Conversation: Sendable, Equatable, Hashable, Codable, CustomStringConvertible, CustomReflectable {
    public enum Kind: String, Sendable, Codable {
        case direct, group
    }

    public let kind: Kind
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func direct(userID: String) -> FileV2Conversation { FileV2Conversation(kind: .direct, id: userID) }

    public static func group(groupID: String) -> FileV2Conversation { FileV2Conversation(kind: .group, id: groupID) }

    public var description: String { "FileV2Conversation(\(kind.rawValue))" }

    public var customMirror: Mirror { Mirror(self, children: ["kind": kind.rawValue], displayStyle: .struct) }
}

/// What a source looked like when the transfer started (WIRE_SPEC 12.8: "the source identity (path or URI, size,
/// modification time)"). Rule 1: before a resume, if the identity changed, the transfer is cancelled.
///
/// The spec asks for the size and the modification time. Those two alone are what a tool that rewrites a file and puts its time
/// back does not change, and the nonce rule's ledger is the last line of defence against exactly that. So this identity is
/// hardened, as an addition to what the spec requires: the modification time to the nanosecond, the file's number (the inode: a
/// file replaced by another one, as an editor that saves atomically does, has another), its creation time, and a SHA-256 of the
/// first and of the last 64 KiB. Everything that a source provides is compared; see `isUnchanged`.
///
/// What this does NOT cover: an edit in the middle of a file that keeps the size, the modification time to the nanosecond, the
/// inode and the creation time (that takes a tool that sets the times by hand). The ledger of tags catches that edit for every chunk
/// that was sealed before, and the cross-check of a resume for every part the server still holds. What none of them can see is the
/// coincidence of all of these: the journal lost the tags of a part that was transmitted, the server's copy of the object is gone
/// (6 hours of idleness, 24 hours at the latest) and the middle of the file was edited without touching anything the identity
/// holds. That needs three independent faults at once.
///
/// `locator` is where to find the source again (a path or a URI). It is NOT part of the comparison: an iOS container path
/// changes with an app update, and the caller re-resolves the source from it. It is personal data: it is never printed, and neither
/// are the file number, the times or the digests.
public struct FileV2SourceIdentity: Sendable, Equatable, Codable, CustomStringConvertible, CustomReflectable {
    /// How many bytes at each end of the file the digests cover.
    public static let sampleLength = 64 * 1024

    public let locator: String
    public let size: UInt64
    /// Modification time, epoch milliseconds.
    public let modifiedMs: Int64
    /// Modification time to the nanosecond (epoch), `nil` for a source that cannot tell it.
    public let modifiedNs: Int64?
    /// The file number (the inode), `nil` for a source that has none.
    public let fileNumber: UInt64?
    /// Creation time, epoch milliseconds, `nil` where the platform does not keep it.
    public let createdMs: Int64?
    /// SHA-256 of the first `sampleLength` bytes (of the whole file when it is shorter), `nil` for a source that does not read them.
    public let headDigest: Data?
    /// SHA-256 of the last `sampleLength` bytes, `nil` for a source that does not read them.
    public let tailDigest: Data?

    public init(locator: String, size: UInt64, modifiedMs: Int64, modifiedNs: Int64? = nil, fileNumber: UInt64? = nil,
                createdMs: Int64? = nil, headDigest: Data? = nil, tailDigest: Data? = nil) {
        self.locator = locator
        self.size = size
        self.modifiedMs = modifiedMs
        self.modifiedNs = modifiedNs
        self.fileNumber = fileNumber
        self.createdMs = createdMs
        self.headDigest = headDigest
        self.tailDigest = tailDigest
    }

    /// Rule 1 of 12.8: the same file as far as the file system and the two samples can tell. Every member that either side holds must
    /// be held by both and be equal: a member the transfer started with and the source no longer provides (or the other way round) is
    /// a change, because it cannot be verified. Two sources that provide only a size and a time (the tests' generated source, a
    /// provider that has no more to give) are compared on those.
    public func isUnchanged(comparedTo other: FileV2SourceIdentity) -> Bool {
        size == other.size && modifiedMs == other.modifiedMs && modifiedNs == other.modifiedNs
            && fileNumber == other.fileNumber && createdMs == other.createdMs
            && headDigest == other.headDigest && tailDigest == other.tailDigest
    }

    public var description: String { "FileV2SourceIdentity(size=\(size))" }

    public var customMirror: Mirror { Mirror(self, children: ["size": size], displayStyle: .struct) }
}

/// The descriptor metadata a sender chooses (the members of 12.7 that are not derived from the file): kept in the journal so
/// that a descriptor can be rebuilt after a restart. `name` and `preview` are personal data and are never printed.
public struct FileV2SendMetadata: Sendable, Equatable, Codable, CustomStringConvertible, CustomReflectable {
    /// Cosmetic hints of the file's own kind (`m`).
    public struct Media: Sendable, Equatable, Codable {
        public var w: Int64?
        public var h: Int64?
        public var dur: Int64?
        public var wave: [Int64]?

        public init(w: Int64? = nil, h: Int64? = nil, dur: Int64? = nil, wave: [Int64]? = nil) {
            self.w = w
            self.h = h
            self.dur = dur
            self.wave = wave
        }

        var descriptorMedia: FileV2Descriptor.Media { FileV2Descriptor.Media(w: w, h: h, dur: dur, wave: wave) }
    }

    /// `FileV2Descriptor.Kind.rawValue` (a string, so that the journal does not depend on a `Codable` conformance of the kind).
    public var kindRawValue: String
    public var name: String?
    public var mimeType: String?
    public var media: Media?
    /// At most 2048 bytes.
    public var preview: Data?
    /// `-1` view once, `0` no timer, `N` seconds; `nil` is not written.
    public var ex: Int64?
    /// `0` export blocked, `1` allowed; `nil` is not written.
    public var xp: Int64?

    public init(kind: FileV2Descriptor.Kind, name: String? = nil, mimeType: String? = nil, media: Media? = nil,
                preview: Data? = nil, ex: Int64? = nil, xp: Int64? = nil) {
        self.kindRawValue = kind.rawValue
        self.name = name
        self.mimeType = mimeType
        self.media = media
        self.preview = preview
        self.ex = ex
        self.xp = xp
    }

    /// `nil` when the journal holds a kind this build does not know.
    public var kind: FileV2Descriptor.Kind? { FileV2Descriptor.Kind(rawValue: kindRawValue) }

    public var description: String { "FileV2SendMetadata(kind=\(kindRawValue))" }

    public var customMirror: Mirror { Mirror(self, children: ["kind": kindRawValue], displayStyle: .struct) }
}

/// The first record of a journal, immutable: everything that identifies the transfer and its file.
public struct FileV2SendBeginRecord: Sendable, Equatable, Codable, CustomStringConvertible, CustomReflectable {
    /// The format of this record (1).
    public var version: Int
    /// The local id of the transfer: 1 to 64 characters of lowercase letters, digits and `-`.
    public var transferID: String
    public var createdMs: Int64
    /// `file_id`, 16 bytes.
    public var fileID: Data
    /// The 64-byte header of the blob: it is what the server's create idempotency is keyed on, so a resume after a lost answer finds the object again.
    public var header: Data
    /// `K` as the `FileV2SecretWrapper` returned it (opaque; never `K` itself).
    public var wrappedKey: Data
    /// The real size of the file, `1...maxSize`.
    public var plaintextSize: UInt64
    public var source: FileV2SourceIdentity
    public var conversation: FileV2Conversation
    public var metadata: FileV2SendMetadata

    public static let currentVersion = 1

    public init(transferID: String, createdMs: Int64, fileID: Data, header: Data, wrappedKey: Data, plaintextSize: UInt64,
                source: FileV2SourceIdentity, conversation: FileV2Conversation, metadata: FileV2SendMetadata) {
        self.version = FileV2SendBeginRecord.currentVersion
        self.transferID = transferID
        self.createdMs = createdMs
        self.fileID = fileID
        self.header = header
        self.wrappedKey = wrappedKey
        self.plaintextSize = plaintextSize
        self.source = source
        self.conversation = conversation
        self.metadata = metadata
    }

    public var description: String {
        "FileV2SendBeginRecord(id=\(fileV2ShortID(transferID)), size=\(plaintextSize), \(conversation.kind.rawValue))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["id": fileV2ShortID(transferID), "plaintextSize": plaintextSize,
                                "conversation": conversation.kind.rawValue], displayStyle: .struct)
    }
}

/// The server object of the transfer (written after every create that made or found one). A new object (the old one was
/// deleted: 404) starts with nothing confirmed.
public struct FileV2SendObjectRecord: Sendable, Equatable, Codable, CustomStringConvertible, CustomReflectable {
    /// The server's object id, exactly as the server returned it.
    public var obj: String
    public var blobLength: Int64
    public var parts: Int

    public init(obj: String, blobLength: Int64, parts: Int) {
        self.obj = obj
        self.blobLength = blobLength
        self.parts = parts
    }

    public var description: String { "FileV2SendObjectRecord(obj=\(fileV2ShortID(obj)), parts=\(parts))" }

    public var customMirror: Mirror {
        Mirror(self, children: ["obj": fileV2ShortID(obj), "parts": parts], displayStyle: .struct)
    }
}

/// The download token the server issued, its value wrapped (it is a secret: it goes into the descriptor and nowhere else).
public struct FileV2SendTokenRecord: Sendable, Equatable, Codable, CustomStringConvertible, CustomReflectable {
    /// `src.tok.v` as the `FileV2SecretWrapper` returned it (opaque).
    public var wrappedValue: Data
    /// Epoch milliseconds, `src.tok.exp`.
    public var exp: Int64
    public var max: Int
    public var scope: String

    public init(wrappedValue: Data, exp: Int64, max: Int, scope: String) {
        self.wrappedValue = wrappedValue
        self.exp = exp
        self.max = max
        self.scope = scope
    }

    public var description: String { "FileV2SendTokenRecord(scope=\(scope), max=\(max))" }

    public var customMirror: Mirror {
        Mirror(self, children: ["scope": scope, "max": max], displayStyle: .struct)
    }
}

/// `T[i]` of one chunk: the GCM tag of a chunk that was sealed (WIRE_SPEC 12.8). Tags are not secret (they travel at the end
/// of every chunk), but they are never printed.
public struct FileV2SendTag: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let index: Int
    /// 16 bytes.
    public let tag: Data

    public init(index: Int, tag: Data) {
        self.index = index
        self.tag = tag
    }

    public var description: String { "FileV2SendTag(index=\(index))" }

    public var customMirror: Mirror { Mirror(self, children: ["index": index], displayStyle: .struct) }
}

/// Where a transfer is. Journalled so that a restart knows what to do and what it must not assume.
public enum FileV2SendPhase: UInt8, Sendable, Equatable, Codable {
    /// Parts are being sealed and uploaded (the state after the begin record).
    case uploading = 0
    /// The server closed the object (POST complete); the descriptor is not out yet.
    case completed = 1
    /// The descriptor is being handed to the channel and the outcome is not known: it MAY have gone out. A cancel after this
    /// phase sends `qa_file_cancel`.
    case announcing = 2
    /// The channel said it could not carry the descriptor: nothing went out; a retry only announces again.
    case announcePending = 3
    /// The transfer is being cancelled: a restart finishes the clean-up instead of resuming.
    case cancelled = 4
}

/// One event appended to a journal after the begin record.
public enum FileV2SendJournalEvent: Sendable, Equatable {
    case object(FileV2SendObjectRecord)
    case token(FileV2SendTokenRecord)
    /// The tags of the chunks of part `part` that were not yet in the journal. MUST be durable BEFORE the part is PUT.
    case tags(part: Int, entries: [FileV2SendTag])
    /// The server confirmed part `part` (a progress hint: the server's parts map is what a resume trusts).
    case partDone(Int)
    case phase(FileV2SendPhase)
}

/// What replaying a journal gives.
public struct FileV2SendRecovered: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let begin: FileV2SendBeginRecord
    public private(set) var object: FileV2SendObjectRecord?
    public private(set) var token: FileV2SendTokenRecord?
    /// `T[i]` of every chunk sealed (and journalled) so far, by chunk index: what `FileV2Encryptor.resume` loads.
    public private(set) var tags: [Int: Data]
    /// The parts the server confirmed for the CURRENT object (a hint).
    public private(set) var confirmedParts: Set<Int>
    public private(set) var phase: FileV2SendPhase
    /// A descriptor MAY have been handed to the channel (the `announcing` phase was reached at some point).
    public private(set) var descriptorMayHaveBeenSent: Bool
    /// Two records disagreed about the tag of one chunk: the journal cannot be trusted for the nonce rule.
    public private(set) var hasConflictingTags: Bool
    /// Bytes at the end of the file that were ignored (a torn or corrupt tail).
    public let droppedTailBytes: Int

    init(begin: FileV2SendBeginRecord, droppedTailBytes: Int) {
        self.begin = begin
        self.object = nil
        self.token = nil
        self.tags = [:]
        self.confirmedParts = []
        self.phase = .uploading
        self.descriptorMayHaveBeenSent = false
        self.hasConflictingTags = false
        self.droppedTailBytes = droppedTailBytes
    }

    mutating func apply(_ event: FileV2SendJournalEvent) {
        switch event {
        case .object(let record):
            object = record
            confirmedParts = []
            // A new object has none of the parts: whatever was complete or announced is to be done again. The "maybe announced" flag stays.
            if phase == .completed || phase == .announcing || phase == .announcePending { phase = .uploading }
        case .token(let record):
            token = record
        case .tags(_, let entries):
            for entry in entries {
                if let known = tags[entry.index] {
                    if known != entry.tag { hasConflictingTags = true }
                } else {
                    tags[entry.index] = entry.tag
                }
            }
        case .partDone(let part):
            confirmedParts.insert(part)
        case .phase(let next):
            phase = next
            if next == .announcing { descriptorMayHaveBeenSent = true }
        }
    }

    public var description: String {
        "FileV2SendRecovered(\(begin), phase=\(phase), tags=\(tags.count), confirmed=\(confirmedParts.count))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["begin": begin, "phase": phase, "tags": tags.count, "confirmedParts": confirmedParts.count],
               displayStyle: .struct)
    }
}

/// Why a store operation failed. Never carries a path, an id or a key.
public enum FileV2SendStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No journal with that id.
    case notFound
    /// A journal with that id already exists.
    case alreadyExists
    /// The journal cannot be read as one: no valid begin record, an undecodable record, or a foreign file. `reason` is a fixed word.
    case corrupt(String)
    /// The transfer id is not 1 to 64 characters of lowercase letters, digits and `-`.
    case invalidIdentifier
    /// A file system operation failed. `operation` is a fixed word (`write`, `sync`, `rename`...), never a path.
    case io(String)
    /// Another holder (another pipeline of this process, or another process that shares the directory) has the exclusive lock of
    /// this transfer. Nothing was touched.
    case busy
    /// The device's protected data is not available (a launch before the first unlock): nothing that depends on reading the
    /// journals or the secure store may be decided now.
    case protectedDataUnavailable

    public var description: String {
        switch self {
        case .notFound: return "FileV2SendStoreError(not_found)"
        case .alreadyExists: return "FileV2SendStoreError(already_exists)"
        case .corrupt(let reason): return "FileV2SendStoreError(corrupt: \(reason))"
        case .invalidIdentifier: return "FileV2SendStoreError(invalid_identifier)"
        case .io(let operation): return "FileV2SendStoreError(io: \(operation))"
        case .busy: return "FileV2SendStoreError(busy)"
        case .protectedDataUnavailable: return "FileV2SendStoreError(protected_data_unavailable)"
        }
    }
}

/// The send state store: the journals of the transfers in progress. A store method that returns has made its effect DURABLE
/// (the journal is flushed with `fsync`, `F_FULLFSYNC` where the platform has it): `append` of the `tags` event is what
/// section 12.8's nonce rule leans on, because the part is PUT only after it returns.
///
/// An implementation is thread safe. `begin` is atomic: a transfer either exists with a valid begin record or does not exist.
///
/// One writer per transfer, whatever the number of store instances and processes over the same state: `acquireLock` is the claim
/// on a transfer. The pipeline takes it before it reads the journal of a transfer and gives it up when the operation is over;
/// nothing else may call `begin`, `append` or `remove` for a transfer whose lock it does not hold.
public protocol FileV2SendStore: Sendable {
    /// Claims the transfer for the caller, WITHOUT waiting: throws `busy` when another holder has it (another pipeline of this
    /// process, another process over the same directory). The claim is exclusive across instances and across processes, and it is
    /// given up by `release()` of the returned lock (or when the lock object goes away, or the process dies). Throws
    /// `invalidIdentifier` for an id that is not a transfer id.
    func acquireLock(_ transferID: String) throws -> FileV2SendTransferLock


    /// Creates the journal of a new transfer. Throws `alreadyExists` when the id is taken.
    func begin(_ record: FileV2SendBeginRecord) throws

    /// Appends one event and makes it durable before returning.
    func append(_ event: FileV2SendJournalEvent, to transferID: String) throws

    /// Replays the journal. A truncated or corrupt tail is ignored (`droppedTailBytes` says how much); a journal without a
    /// valid begin record is `corrupt`.
    func load(_ transferID: String) throws -> FileV2SendRecovered

    /// The ids of the journals present (some may be corrupt: `load` says).
    func listTransferIDs() throws -> [String]

    /// Deletes the journal. Idempotent.
    func remove(_ transferID: String) throws
}

/// Valid local transfer ids: 1 to 64 bytes of `a-z`, `0-9` and `-` (a lowercase UUID qualifies). Checked on bytes, so no
/// canonical-equivalence trap and no way to build a path out of an id.
func fileV2IsValidTransferID(_ id: String) -> Bool {
    let bytes = Array(id.utf8)
    guard (1...64).contains(bytes.count) else { return false }
    return bytes.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
}
