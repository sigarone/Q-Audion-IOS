import Foundation

/// App-layer envelope carried in a `.data` (``MeshPacketType/data``)
/// packet's payload for a chat message sent over the mesh.
///
/// WIRE VERSION 2 — this whole structure is plaintext that never touches the
/// air. It is serialised, encrypted as one unit with the peer's message key,
/// and only the resulting ciphertext travels, wrapped in ``MeshSealedShell``.
///
/// Version 1 did the opposite and said so here: it carried `senderUserId`,
/// `recipientUserId`, `conversationId`, `clientMsgId` and a timestamp in
/// cleartext around an encrypted body, because "they are exactly the routing
/// metadata the normal WebSocket transport already sends in cleartext" and
/// "are NOT secret". That does not survive the change of medium: on the
/// WebSocket those fields ride inside a TLS tunnel to a server that already
/// knows them, here they are broadcast to whoever is within Bluetooth range,
/// as real user UUIDs.
///
/// ``senderNodeHex`` and ``recipientNodeHex`` are a sealed copy of the two
/// addressing fields the public packet header also carries. The receiver
/// compares them with the header the packet actually arrived in, which is how
/// a relay is stopped from re-addressing traffic it forwards. Associated data
/// would have been the obvious mechanism and does not work: for a v3.1 or v4
/// peer the ratchet rebuilds the AAD internally as canonical CBOR and discards
/// the caller's, so any AAD-based header binding is silently inert.
///
/// Byte-identical to the Android sibling (`MeshChatMessage.kt`), field names
/// and all — the two interoperate on the same wire.
///
/// Kept deliberately small so a whole message fits in one BLE MTU where
/// possible; larger ones are link-fragmented (see ``MeshFragmenter``).
public struct MeshChatMessage: Equatable, Sendable, Codable {

    /// 2 = sealed envelope. 1 was the cleartext-metadata layout and is
    /// rejected rather than supported: accepting it would preserve a downgrade
    /// path back to the leak.
    public static let wireVersion = 2

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case senderUserId = "s"
        case recipientUserId = "r"
        case clientMsgId = "c"
        case conversationId = "conv"
        case body = "b"
        case senderNodeHex = "sn"
        case recipientNodeHex = "rn"
        case sentAtMs = "ts"
    }

    public let version: Int
    public let senderUserId: String
    public let recipientUserId: String
    public let clientMsgId: String
    public let conversationId: String
    /// Message body, in the clear INSIDE the sealed envelope — never on the wire.
    public let body: String
    /// Sealed copy of the packet header's sender node id.
    public let senderNodeHex: String
    /// Sealed copy of the packet header's recipient node id.
    public let recipientNodeHex: String
    public let sentAtMs: Int64

    public init(
        version: Int = MeshChatMessage.wireVersion,
        senderUserId: String,
        recipientUserId: String,
        clientMsgId: String,
        conversationId: String,
        body: String,
        sentAtMs: Int64,
        senderNodeHex: String,
        recipientNodeHex: String
    ) {
        self.version = version
        self.senderUserId = senderUserId
        self.recipientUserId = recipientUserId
        self.clientMsgId = clientMsgId
        self.conversationId = conversationId
        self.body = body
        self.senderNodeHex = senderNodeHex
        self.recipientNodeHex = recipientNodeHex
        self.sentAtMs = sentAtMs
    }

    public func encode() -> Data {
        // Every field is a String/Int — a hand-authored Codable struct like
        // this never actually throws from JSONEncoder.
        try! JSONEncoder().encode(self)
    }

    public static func decode(_ bytes: Data) -> MeshChatMessage? {
        guard let decoded = try? JSONDecoder().decode(MeshChatMessage.self, from: bytes),
              decoded.version == MeshChatMessage.wireVersion else { return nil }
        return decoded
    }
}

/// The thin, unavoidably-public shell the sealed envelope travels in.
///
/// It carries exactly one field beyond the ciphertext, and only because the
/// cryptography demands it. For a v3.1 or v4 peer the ratchet rebuilds its
/// associated data internally over `{m, r, s}` — message id, recipient,
/// sender — so the RECEIVER must know the message id before it can decrypt
/// anything. Sealing it inside the payload makes it unreachable at exactly the
/// moment it is needed, and every message from a modern peer would fail to
/// open.
///
/// So `clientMsgId` stays outside. It is a random UUID minted per message: it
/// identifies a message, not a person, and says nothing about who is talking
/// to whom or about what. Everything that does is inside `sealedB64`.
///
/// Byte-identical to the Android sibling's `MeshSealedShell`.
public struct MeshSealedShell: Equatable, Sendable, Codable {

    enum CodingKeys: String, CodingKey {
        case clientMsgId = "c"
        case sealedB64 = "e"
    }

    public let clientMsgId: String
    public let sealedB64: String

    public init(clientMsgId: String, sealedB64: String) {
        self.clientMsgId = clientMsgId
        self.sealedB64 = sealedB64
    }

    public func encode() -> Data {
        // Both fields are Strings — a hand-authored Codable struct like this
        // never actually throws from JSONEncoder.
        try! JSONEncoder().encode(self)
    }

    public static func decode(_ bytes: Data) -> MeshSealedShell? {
        try? JSONDecoder().decode(MeshSealedShell.self, from: bytes)
    }
}

/// Associated data binding a sealed mesh payload to the public header it
/// travels in.
///
/// Kept for the v2-ratchet path, which does honour a caller-supplied AAD. For
/// v3.1 and v4 peers the ratchet rebuilds its own and this is ignored — which
/// is why the header binding that actually protects every peer is the sealed
/// copy of the node ids inside ``MeshChatMessage``, not this.
///
/// Byte-identical to the Android sibling's `meshPacketAad`: same string, same
/// order, same separators, and the type rendered UNSIGNED so a code of 0x80 or
/// above cannot render as "-128" on one platform and "128" on the other.
public func meshPacketAad(
    version: Int,
    typeWireCode: UInt8,
    senderId: MeshNodeId,
    recipientId: MeshNodeId
) -> Data {
    Data("mesh:v\(version):\(typeWireCode):\(senderId.hex):\(recipientId.hex)".utf8)
}
