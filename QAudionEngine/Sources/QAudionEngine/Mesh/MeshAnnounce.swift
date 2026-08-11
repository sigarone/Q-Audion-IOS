import Foundation

/// Control body carried in a `.announce` (``MeshPacketType/announce``)
/// packet's payload.
///
/// An ANNOUNCE is the one packet type whose payload is NOT `MessageCrypto`
/// ciphertext (see ``MeshPacketType/announce``) — it is this transport's own
/// discovery metadata, so it needs an explicit schema. It carries no secret:
/// only the sender's node id, the hex of its long-term identity fingerprint
/// (so a receiver can match it to a known contact and decide trust), and the
/// node ids this sender is currently directly connected to (its neighbor
/// list, feeding ``MeshTopology`` for multi-hop routing).
public struct MeshAnnounce: Equatable, Sendable, Codable {

    public static let wireVersion = 1

    /// Sender-side cap on the advertised neighbor list, mirroring the
    /// topology-gossip fan-out limit.
    public static let maxNeighbors = 10

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case nodeIdHex = "node"
        case identityFingerprintHex = "fp"
        case displayHint = "hint"
        case neighborNodeIdsHex = "nbrs"
    }

    public let version: Int
    public let nodeIdHex: String
    /// Lowercase hex of the first 8 bytes of SHA-256 over the sender's raw
    /// long-term identity key — the same value ``MeshNodeId/from(identityKeyRaw:)``
    /// derives. Equal to `nodeIdHex` in this scheme (node id IS the identity
    /// fingerprint), kept as a distinct field so a future scheme can decouple
    /// a rotating session node id from the stable identity fingerprint
    /// without a wire change.
    public let identityFingerprintHex: String
    /// Optional short display hint (nickname). Never a secret; purely a UX
    /// affordance before a contact match resolves the real name.
    public let displayHint: String?
    /// Hex node ids this sender is directly connected to right now — its
    /// neighbor list. Capped by the sender to bound packet size.
    public let neighborNodeIdsHex: [String]

    public init(
        version: Int = MeshAnnounce.wireVersion,
        nodeIdHex: String,
        identityFingerprintHex: String,
        displayHint: String? = nil,
        neighborNodeIdsHex: [String] = []
    ) {
        self.version = version
        self.nodeIdHex = nodeIdHex
        self.identityFingerprintHex = identityFingerprintHex
        self.displayHint = displayHint
        self.neighborNodeIdsHex = neighborNodeIdsHex
    }

    public func encode() -> Data {
        // A hand-authored Codable struct with only String/Int/[String]
        // fields never throws from JSONEncoder — force-unwrap is safe.
        try! JSONEncoder().encode(self)
    }

    public static func decode(_ bytes: Data) -> MeshAnnounce? {
        try? JSONDecoder().decode(MeshAnnounce.self, from: bytes)
    }
}
