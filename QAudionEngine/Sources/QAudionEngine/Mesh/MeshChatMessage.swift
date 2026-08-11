import Foundation

/// App-layer envelope carried in a `.data` (``MeshPacketType/data``)
/// packet's payload for a chat message sent over the mesh.
///
/// `ciphertextB64` is the app's own `MessageCrypto`-family output — this
/// transport never decrypts it. The surrounding fields are exactly the
/// routing metadata the normal WebSocket transport already sends in
/// cleartext (sender / recipient user id, client message id): they are NOT
/// secret, and the receiver needs them to rebuild the same associated data
/// the sender bound the ciphertext to, otherwise decryption fails.
///
/// Kept deliberately small so a whole message fits in one BLE MTU where
/// possible; larger ones are link-fragmented (see ``MeshFragmenter``).
public struct MeshChatMessage: Equatable, Sendable, Codable {

    public static let wireVersion = 1

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case senderUserId = "s"
        case recipientUserId = "r"
        case clientMsgId = "c"
        case conversationId = "conv"
        case ciphertextB64 = "ct"
        case sentAtMs = "ts"
    }

    public let version: Int
    public let senderUserId: String
    public let recipientUserId: String
    public let clientMsgId: String
    public let conversationId: String
    public let ciphertextB64: String
    public let sentAtMs: Int64

    public init(
        version: Int = MeshChatMessage.wireVersion,
        senderUserId: String,
        recipientUserId: String,
        clientMsgId: String,
        conversationId: String,
        ciphertextB64: String,
        sentAtMs: Int64
    ) {
        self.version = version
        self.senderUserId = senderUserId
        self.recipientUserId = recipientUserId
        self.clientMsgId = clientMsgId
        self.conversationId = conversationId
        self.ciphertextB64 = ciphertextB64
        self.sentAtMs = sentAtMs
    }

    public func encode() -> Data {
        // Every field is a String/Int — a hand-authored Codable struct like
        // this never actually throws from JSONEncoder.
        try! JSONEncoder().encode(self)
    }

    public static func decode(_ bytes: Data) -> MeshChatMessage? {
        try? JSONDecoder().decode(MeshChatMessage.self, from: bytes)
    }
}
