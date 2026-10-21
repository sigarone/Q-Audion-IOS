import Foundation

/// One mesh send the outbox is responsible for (docs/mesh/MESH_LINK_SPEC.md
/// section 10.2).
///
/// A MESSAGE entry stays in the outbox after the first hop accepted it and is
/// retransmitted every 20 s until a valid delivery receipt arrives or the outbox
/// gives up (1 h). A RECEIPT entry has no acknowledgement of its own: it leaves the
/// outbox once a first hop accepted it. `payloadB64` is the already-sealed
/// `MeshSealedShell` bytes, so the entry carries no plaintext and no key material;
/// every retransmission is a new packet (new timestamp, new set ids) around the
/// SAME shell, which is why the receiver's duplicate check on the shell id makes a
/// second copy harmless.
public struct MeshOutboxEntry: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case message
        case receipt
    }

    /// Unique key. A message: its `clientMsgId`. A receipt: ``receiptKey(acknowledging:kind:)``.
    public let id: String
    public let kind: Kind
    /// The app-level message the entry belongs to (the message itself, or the one a receipt acknowledges).
    public let messageId: String
    /// Empty for a receipt.
    public let conversationId: String
    public let peerUserId: String
    public let targetNodeHex: String
    public let payloadB64: String
    public let createdAtMs: Int64
    public var attempts: Int
    public var lastAttemptMs: Int64?
    /// True once a first hop accepted the packet at least once.
    public var firstHopAccepted: Bool

    public init(
        id: String, kind: Kind, messageId: String, conversationId: String, peerUserId: String,
        targetNodeHex: String, payloadB64: String, createdAtMs: Int64,
        attempts: Int = 0, lastAttemptMs: Int64? = nil, firstHopAccepted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.messageId = messageId
        self.conversationId = conversationId
        self.peerUserId = peerUserId
        self.targetNodeHex = targetNodeHex
        self.payloadB64 = payloadB64
        self.createdAtMs = createdAtMs
        self.attempts = attempts
        self.lastAttemptMs = lastAttemptMs
        self.firstHopAccepted = firstHopAccepted
    }

    /// A newer receipt for the same message and kind replaces a queued one, so they share a key.
    public static func receiptKey(acknowledging clientMsgId: String, kind: String) -> String {
        "rcpt:\(clientMsgId):\(kind)"
    }

    /// The packet type the entry travels as.
    public var packetType: MeshPacketType {
        kind == .receipt ? .receipt : .data
    }
}

public enum MeshOutboxPolicy {
    /// A message that is not acknowledged is sent again this often.
    public static let retryMs: Int64 = 20_000
    /// An entry older than this is given up.
    public static let giveUpMs: Int64 = 60 * 60 * 1000
    /// A target that just became reachable is retried without waiting a full interval, but never faster than this.
    public static let reachableMinGapMs: Int64 = 3_000
}

/// The outbox as a plain value: no storage, no clock, no radio. The app keeps it in
/// `UserDefaults` and drives it from a timer and from reachability changes.
public struct MeshOutboxQueue: Codable, Equatable, Sendable {

    public private(set) var entries: [MeshOutboxEntry]

    public init(entries: [MeshOutboxEntry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func contains(id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    public func entry(id: String) -> MeshOutboxEntry? {
        entries.first { $0.id == id }
    }

    /// Replaces any existing entry with the same id (an enqueue is idempotent, not a duplicate).
    public mutating func enqueue(_ entry: MeshOutboxEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
    }

    @discardableResult
    public mutating func remove(id: String) -> MeshOutboxEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    /// A delivery (or read) receipt for `clientMsgId` arrived: the message leaves the outbox.
    @discardableResult
    public mutating func acknowledge(clientMsgId: String) -> MeshOutboxEntry? {
        guard let index = entries.firstIndex(where: { $0.kind == .message && $0.id == clientMsgId }) else { return nil }
        return entries.remove(at: index)
    }

    /// Entries to send now, oldest first: never tried, or last tried at least ``MeshOutboxPolicy/retryMs``
    /// ago. An entry whose target is in `reachableTargets` is also due once ``MeshOutboxPolicy/reachableMinGapMs``
    /// passed. Entries past the give-up age are not due (see ``expired(nowMs:)``).
    public func due(
        nowMs: Int64,
        reachableTargets: Set<String> = [],
        retryMs: Int64 = MeshOutboxPolicy.retryMs
    ) -> [MeshOutboxEntry] {
        entries
            .filter { entry in
                guard nowMs - entry.createdAtMs <= MeshOutboxPolicy.giveUpMs else { return false }
                guard let last = entry.lastAttemptMs else { return true }
                let gap = nowMs - last
                if gap >= retryMs { return true }
                return reachableTargets.contains(entry.targetNodeHex) && gap >= MeshOutboxPolicy.reachableMinGapMs
            }
            .sorted { $0.createdAtMs < $1.createdAtMs }
    }

    /// Entries the outbox gives up on.
    public func expired(nowMs: Int64, giveUpMs: Int64 = MeshOutboxPolicy.giveUpMs) -> [MeshOutboxEntry] {
        entries.filter { nowMs - $0.createdAtMs > giveUpMs }
    }

    public enum AttemptOutcome: Equatable {
        /// The entry is gone (not queued, or a receipt that a first hop accepted).
        case removed
        /// The first hop accepted a message for the first time: the application state becomes "sent".
        case firstAcceptance
        /// Still queued.
        case retained
    }

    /// Records the result of one transmission attempt.
    @discardableResult
    public mutating func recordAttempt(id: String, nowMs: Int64, accepted: Bool) -> AttemptOutcome {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return .removed }
        entries[index].attempts += 1
        entries[index].lastAttemptMs = nowMs
        guard accepted else { return .retained }
        if entries[index].kind == .receipt {
            entries.remove(at: index)
            return .removed
        }
        if entries[index].firstHopAccepted { return .retained }
        entries[index].firstHopAccepted = true
        return .firstAcceptance
    }
}
