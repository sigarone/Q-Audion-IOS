import Foundation

/// A delivery or read acknowledgement travelling back over the mesh.
///
/// Until this existed a mesh message stopped at one tick forever. Not because
/// the tick was wrong — the message really had left the radio — but because
/// every path that turns sent into delivered or read runs through the server:
/// delivery is the server's ack and the read receipt is a `msg_read` frame
/// keyed by a server message id, which a mesh message does not have. A
/// transport built to work with no server therefore said nothing about the
/// only question that matters when there is no server to ask.
///
/// Sealed exactly like ``MeshChatMessage`` and for the same reason: a receipt
/// is metadata about a conversation, and metadata over the air is what wire v2
/// exists to hide. In the clear it would announce that user A read a message
/// from user B at time T.
///
/// ``receiptId`` is this receipt's own random id and rides OUTSIDE the seal in
/// the ``MeshSealedShell``, because the v3.1/v4 ratchet rebuilds its associated
/// data from the message id before it can decrypt anything.
/// ``messageClientMsgId`` — the field that actually links two people to one
/// conversation — stays inside.
public struct MeshReceipt: Codable, Equatable, Sendable {
    /// Reached the peer's device and was stored. Second tick.
    public static let kindDelivered = "d"
    /// The peer opened the conversation and saw it. Blue ticks.
    public static let kindRead = "r"

    public let version: Int
    /// Who is acknowledging — i.e. the original message's recipient.
    public let senderUserId: String
    /// Who wrote the message being acknowledged.
    public let recipientUserId: String
    /// This receipt's own id; equals the shell's public id it was sealed under.
    public let receiptId: String
    /// The `clientMsgId` of the message being acknowledged.
    public let messageClientMsgId: String
    /// ``kindDelivered`` or ``kindRead``.
    public let kind: String
    public let atMs: Int64
    /// Sealed copy of the public header's addressing, checked on arrival.
    public let senderNodeHex: String
    public let recipientNodeHex: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case senderUserId = "s"
        case recipientUserId = "r"
        case receiptId = "c"
        case messageClientMsgId = "m"
        case kind = "k"
        case atMs = "ts"
        case senderNodeHex = "sn"
        case recipientNodeHex = "rn"
    }

    public init(
        version: Int = MeshChatMessage.wireVersion,
        senderUserId: String,
        recipientUserId: String,
        receiptId: String,
        messageClientMsgId: String,
        kind: String,
        atMs: Int64,
        senderNodeHex: String,
        recipientNodeHex: String
    ) {
        self.version = version
        self.senderUserId = senderUserId
        self.recipientUserId = recipientUserId
        self.receiptId = receiptId
        self.messageClientMsgId = messageClientMsgId
        self.kind = kind
        self.atMs = atMs
        self.senderNodeHex = senderNodeHex
        self.recipientNodeHex = recipientNodeHex
    }

    public func encode() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> MeshReceipt? {
        guard let r = try? JSONDecoder().decode(MeshReceipt.self, from: data) else { return nil }
        guard r.version == MeshChatMessage.wireVersion else { return nil }
        guard r.kind == kindDelivered || r.kind == kindRead else { return nil }
        return r
    }
}

/// Where a message status is allowed to go when a receipt arrives.
///
/// A flood mesh delivers the same packet more than once and in no particular
/// order, so "apply what the receipt says" is not safe: a re-delivered
/// delivered would pull a message that is already read back to two grey ticks,
/// and the user would watch a receipt they had already been given get taken
/// away. Status only ever moves forward.
///
/// Returns the new status, or nil when the current one already covers it.
public func meshReceiptStatusUpdate(current: Message.Status, kind: String) -> Message.Status? {
    func rank(_ s: Message.Status) -> Int {
        switch s {
        case .sending: return 0
        case .sent: return 1
        case .delivered: return 2
        case .read: return 3
        // A signed receipt is proof the message arrived, whatever the local
        // send path concluded.
        case .failed: return -1
        }
    }
    let target: Message.Status
    switch kind {
    case MeshReceipt.kindDelivered: target = .delivered
    case MeshReceipt.kindRead: target = .read
    default: return nil
    }
    return rank(target) > rank(current) ? target : nil
}
