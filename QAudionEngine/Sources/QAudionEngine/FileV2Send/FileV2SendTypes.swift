import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLError lives here on Linux (the scratch harness); on Apple platforms it is Foundation
#endif

// File transfer v2, step 2c: the SEND PIPELINE (WIRE_SPEC 12.7, 12.8 and 12.10). The types the pipeline is built from and
// reports with. There is no HTTP client here (the pipeline talks to the `FileV2Server` interface), no chat integration (the
// descriptor goes through `FileV2DescriptorChannel`) and no user interface (progress is a stream of `FileV2SendState`).

/// What the chat can do for the pipeline. Two things only: say whether a descriptor can be carried to a conversation now, and
/// carry it. The descriptor is the body of an ordinary chat message (1:1) or of a group payload (WIRE_SPEC 12.7): if the channel
/// cannot send a text message to the conversation, the file MUST NOT be sent either, so the answer is asked BEFORE anything is
/// uploaded.
public protocol FileV2DescriptorChannel: Sendable {
    /// Can a text message reach `conversation` now? `false` fails the send with `channelUnavailable` and nothing is uploaded.
    func canCarryDescriptor(to conversation: FileV2Conversation) async -> Bool

    /// Hands `body` (a descriptor built by `FileV2DescriptorBuilder`) to the chat. `idempotencyKey` is the id of the transfer: a
    /// chat that is asked twice for the same key (a crash between the hand-over and the answer) can send one message.
    func announce(_ body: String, to conversation: FileV2Conversation, idempotencyKey: String) async -> FileV2AnnounceOutcome

    /// Hands a control message (`qa_file_cancel`) to the chat. Best effort: there is no retry.
    func sendControl(_ body: String, to conversation: FileV2Conversation) async -> FileV2AnnounceOutcome
}

/// What the chat did with a descriptor. The pipeline reports `sent` only on `.sent`.
public enum FileV2AnnounceOutcome: Sendable, Equatable {
    /// The chat sent the message.
    case sent
    /// The chat accepted it into its outbox and will send it when it can.
    case queued
    /// The chat could not carry it (and did not queue it): nothing went out.
    case unavailable
}

/// Time for the pipeline, injectable: the backoff between two tries and the waits of the retry policy. A test makes it
/// instantaneous (and moves its clock by what was asked); production sleeps.
public protocol FileV2Sleeper: Sendable {
    /// Sleeps `ms` milliseconds. Throws `CancellationError` when the task is cancelled.
    func sleep(milliseconds ms: Int64) async throws
}

public struct FileV2SystemSleeper: FileV2Sleeper {
    public init() {}

    public func sleep(milliseconds ms: Int64) async throws {
        let clamped = UInt64(max(0, min(ms, 3_600_000)))
        try await Task.sleep(nanoseconds: clamped * 1_000_000)
    }
}

/// A `FileV2Server` that can tell the pipeline how many bytes of a part body have left, so the part timeout can be progress
/// based (`FileV2ProgressDeadline`: expired when no byte has moved for the idle limit, whatever the total time). The HTTP client
/// of the next step implements it with the upload delegate's `didSendBodyData`. A server that does not conform gets a single
/// total deadline of `FileV2PartTimeout.slowestLegitimateSeconds` plus a margin.
public protocol FileV2PartProgressReporting: FileV2Server {
    /// `progress` is called with the number of bytes that moved since the last call.
    func putPart(obj: String, part: Int, body: Data, sha256: Data, progress: @escaping @Sendable (Int) -> Void) async throws
        -> FileV2PutResult
}

/// Counters for telemetry (WIRE_SPEC program item I6): numbers and fixed words only, never an id, a name, a path or a size.
public enum FileV2SendTelemetryEvent: Sendable, Equatable {
    case started(resumed: Bool)
    case partUploaded(bytes: Int, duplicate: Bool)
    /// A request or a part was tried again after a failure.
    case retried
    case parallelismChanged(from: Int, to: Int)
    case objectRecreated
    case orphansDeleted(count: Int)
    case contentChanged
    /// `code` is `sent`, `announce_pending`, `interrupted` or a `FileV2SendFailure.Reason` raw value.
    case finished(code: String)
}

public protocol FileV2SendTelemetry: Sendable {
    func record(_ event: FileV2SendTelemetryEvent)
}

/// Why a transfer failed, in the taxonomy the user interface acts on. The error text is a fixed word; the numbers a UI shows
/// (`used` and `limit` of a quota, the limit of unfinished uploads) are in `details`.
public struct FileV2SendFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// The source is empty (WIRE_SPEC 12.7: `sz` is 1...`MAX_SIZE`).
        case emptySource = "empty_source"
        /// The source cannot be read at all when the transfer starts.
        case sourceUnavailable = "source_unavailable"
        /// The source is larger than `MAX_SIZE` (5 GiB).
        case sourceTooLarge = "source_too_large"
        /// The chat cannot carry a descriptor to the conversation now (WIRE_SPEC 12.7: then the file is not sent either).
        case channelUnavailable = "channel_unavailable"
        /// The account has no `feat.files` (402).
        case entitlement
        /// The account's storage is full, or the object is too large (413).
        case quota
        /// The server has no room (507).
        case serverFull = "server_full"
        /// The account holds as many unfinished uploads or objects as it may and the pipeline could not free any: the user must delete something.
        case userRemedy = "user_remedy"
        /// Retries of a 429 are spent.
        case rateLimited = "rate_limited"
        /// The network or the server failed and the retries are spent: the transfer pauses (its state is kept) and can be resumed.
        case network
        /// 403: the account may not do this.
        case auth
        /// The source changed under the transfer (its size or time, a chunk whose tag differs, a part the server holds with other bytes): cancelled.
        case sourceChanged = "source_changed"
        /// The transfer's state cannot be trusted or read (a lost key, a corrupt journal, a part on the server with no tag in the journal): cancelled.
        case stateLost = "state_lost"
        /// The request is wrong: a client bug or a server this client does not speak to.
        case badRequest = "bad_request"
        /// The descriptor would not stay under 8 KiB.
        case descriptorTooLarge = "descriptor_too_large"
        /// The blob is on the server but the chat did not take the descriptor: the state is kept and a retry only announces again (no upload).
        case announceNotSent = "announce_not_sent"
        /// The transfer was cancelled by the user.
        case cancelled
        /// The device could not keep the transfer's state (a full disk, a refused write): nothing was sent that the state does not cover.
        case storage
        /// A transfer with that id is already running.
        case alreadyRunning = "already_running"
    }

    public let reason: Reason
    /// The taxonomy value of the transport layer this comes from, when there is one.
    public let transferError: FileV2TransferError?
    /// The numbers of the server's error body (`used`, `limit`, ...), when there are any.
    public let details: FileV2ErrorDetails?
    /// The `code` of the server's error body (1 to 64 lowercase letters, digits and `_`: never free text), when there is one.
    public let code: String?

    public init(_ reason: Reason, transferError: FileV2TransferError? = nil, details: FileV2ErrorDetails? = nil, code: String? = nil) {
        self.reason = reason
        self.transferError = transferError
        self.details = details
        self.code = code
    }

    /// The failure of a transport taxonomy value.
    public init(transfer error: FileV2TransferError, details: FileV2ErrorDetails? = nil, code: String? = nil) {
        let reason: Reason
        switch error {
        case .entitlement: reason = .entitlement
        case .quota: reason = .quota
        case .serverFull: reason = .serverFull
        case .rateLimited: reason = .rateLimited
        case .network: reason = .network
        case .auth: reason = .auth
        case .noSpace: reason = .storage
        case .sourceChanged: reason = .sourceChanged
        case .badRequest: reason = .badRequest
        case .announceNotSent: reason = .announceNotSent
        case .descriptorTooLarge: reason = .descriptorTooLarge
        }
        self.init(reason, transferError: error, details: details, code: code)
    }

    /// The state of the transfer survives this failure, so `resume` can go on from it (the transfer paused, it did not end).
    public var keepsState: Bool {
        switch reason {
        case .network, .rateLimited, .auth, .entitlement, .serverFull, .userRemedy, .announceNotSent, .storage: return true
        default: return false
        }
    }

    public var description: String { "FileV2SendFailure(\(reason.rawValue))" }
}

/// How far an upload has got.
public struct FileV2SendProgress: Sendable, Equatable {
    public let partsDone: Int
    public let partsTotal: Int
    /// Bytes of the parts the server has confirmed, and the bytes of all the parts: the blob without its 64-byte header, which the create writes.
    public let bytesDone: Int64
    public let bytesTotal: Int64

    public init(partsDone: Int, partsTotal: Int, bytesDone: Int64, bytesTotal: Int64) {
        self.partsDone = partsDone
        self.partsTotal = partsTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }
}

/// The states a transfer reports. The terminal ones are `sentOk`, `sentAnnouncePending`, `failed` and `interrupted`.
public enum FileV2SendState: Sendable, Equatable {
    /// Preflight, key material, the object on the server.
    case preparing
    /// The first part is being encrypted.
    case sealing
    case uploading(FileV2SendProgress)
    /// Every part is up; the server is asked to close the object.
    case completing
    /// The descriptor is being handed to the chat.
    case announcing
    /// The chat SENT the descriptor. Only ever reported on the channel's `.sent`.
    case sentOk
    /// The chat accepted the descriptor into its outbox. The transfer is done on this side.
    case sentAnnouncePending
    case failed(FileV2SendFailure)
    /// The task running the transfer was cancelled (the app is going away) with no request to cancel the transfer: its state is
    /// kept, and `resume` goes on from it.
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .sentOk, .sentAnnouncePending, .failed, .interrupted: return true
        default: return false
        }
    }
}

/// Receives the states of a transfer, in order. Called from the task that runs the transfer; keep it short.
public typealias FileV2SendStateSink = @Sendable (FileV2SendState) -> Void

/// What the caller asks for. Its description shows 8 characters of the id and the kind of the conversation, nothing else.
public struct FileV2SendRequest: Sendable, CustomStringConvertible, CustomReflectable {
    /// The local id of the transfer (1 to 64 characters of lowercase letters, digits and `-`): the handle for `cancel` and
    /// `resume`. Default: a fresh lowercase UUID.
    public var transferID: String
    public var source: FileV2SendSource
    public var conversation: FileV2Conversation
    public var metadata: FileV2SendMetadata

    public init(transferID: String = UUID().uuidString.lowercased(), source: FileV2SendSource, conversation: FileV2Conversation,
                metadata: FileV2SendMetadata) {
        self.transferID = transferID
        self.source = source
        self.conversation = conversation
        self.metadata = metadata
    }

    public var description: String { "FileV2SendRequest(id=(fileV2ShortID(transferID)), (conversation.kind.rawValue))" }

    public var customMirror: Mirror {
        Mirror(self, children: ["id": fileV2ShortID(transferID), "conversation": conversation.kind.rawValue], displayStyle: .struct)
    }
}

/// A transfer whose state is on the device, for the list a restart shows.
public struct FileV2ResumableTransfer: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let transferID: String
    public let phase: FileV2SendPhase
    public let conversation: FileV2Conversation
    public let source: FileV2SourceIdentity
    public let createdMs: Int64
    /// Parts the server confirmed, a hint from the journal.
    public let confirmedParts: Int
    /// The transfer is running in this process right now.
    public let isRunning: Bool

    public var description: String {
        "FileV2ResumableTransfer(id=\(fileV2ShortID(transferID)), phase=\(phase), parts=\(confirmedParts), running=\(isRunning))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["id": fileV2ShortID(transferID), "phase": phase, "confirmedParts": confirmedParts,
                                "isRunning": isRunning], displayStyle: .struct)
    }
}

/// The numbers of the last runs, for tests and diagnostics. No identifier, no name.
public struct FileV2SendDiagnostics: Sendable, Equatable {
    /// The most bytes the pipeline held in memory at once (sealed parts and the plaintext chunks being sealed).
    public let peakHeldBytes: Int64
    /// The most parts held (being sealed or uploaded) at once.
    public let peakConcurrentParts: Int
}

/// The configuration of a pipeline. The defaults are production values.
public struct FileV2SendConfiguration: Sendable {
    /// The memory the app may use, in MiB (on iOS the available memory of the process, `os_proc_available_memory()`): the memory
    /// budget is `min(6 parts, this / 6)` (`FileV2MemBudget`).
    public var availableMemoryMiB: Int = 1024
    /// A metered network (cellular with data saver, a hotspot): at most 3 parts in flight.
    public var metered = false
    /// `max_uses` of the token of a 1:1 conversation.
    public var directMaxUses = 30
    /// `max_uses` of the token of a group (`nil`: the server's default, per presenting account).
    public var groupMaxUses: Int?
    /// `ttl_seconds` of the token (`nil`: the server's default, 7 days).
    public var tokenTTLSeconds: Int64?
    public var retryPolicy = FileV2RetryPolicy()
    /// A part whose body has not moved for this long (milliseconds on the monotonic clock) is timed out and retried. The server
    /// itself cuts a body that stays under 64 kbit/s for 30 seconds.
    public var partIdleTimeoutMs: Int64 = 90_000
    /// The total time of a part when the server cannot report progress: the slowest legitimate part plus a margin.
    public var partTotalTimeoutMs: Int64 = (Int64(FileV2PartTimeout.slowestLegitimateSeconds) + 120) * 1000
    /// How often the watchdog of a part looks at its deadline, in real milliseconds.
    public var watchdogPollMs: Int64 = 2_000
    /// An unfinished object that is not in any local journal is an orphan only when it has been idle this long (milliseconds, by
    /// the wall clock): it may be a live upload of another device of the account.
    public var orphanMinIdleMs: Int64 = 10 * 60_000
    /// A token that expires within this many milliseconds is replaced before it goes into a descriptor.
    public var tokenRefreshMarginMs: Int64 = 3_600_000
    /// How many times a request answered 401 is repeated after `refreshAuth` succeeded.
    public var maxAuthRefreshes = 2
    /// How many times `complete` is repeated after 409 `incomplete`.
    public var maxCompleteRounds = 3
    /// How many times a transfer re-creates an object the server deleted under it.
    public var maxObjectRecreations = 3

    public init() {}
}

/// Everything the pipeline needs from outside.
public struct FileV2SendDependencies: Sendable {
    public var server: FileV2Server
    public var store: FileV2SendStore
    public var secrets: FileV2SecretWrapper
    /// Finds a source again from its identity after a restart.
    public var sources: FileV2SendSourceProvider
    public var channel: FileV2DescriptorChannel
    public var clock: FileV2Clock
    public var sleeper: FileV2Sleeper
    public var telemetry: FileV2SendTelemetry?
    /// Refreshes the access token after a 401; returns whether it did.
    public var refreshAuth: (@Sendable () async -> Bool)?

    public init(server: FileV2Server, store: FileV2SendStore, secrets: FileV2SecretWrapper, sources: FileV2SendSourceProvider,
                channel: FileV2DescriptorChannel, clock: FileV2Clock = FileV2SystemClock(),
                sleeper: FileV2Sleeper = FileV2SystemSleeper(), telemetry: FileV2SendTelemetry? = nil,
                refreshAuth: (@Sendable () async -> Bool)? = nil) {
        self.server = server
        self.store = store
        self.secrets = secrets
        self.sources = sources
        self.channel = channel
        self.clock = clock
        self.sleeper = sleeper
        self.telemetry = telemetry
        self.refreshAuth = refreshAuth
    }
}
