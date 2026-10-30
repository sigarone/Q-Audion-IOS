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
        case challengeHex = "ch"
        case peerVerified = "pv"
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
    /// The 16-byte challenge of this link as 32 lowercase hex characters (section 8.5); nil when the sender sends none.
    public let challengeHex: String?
    /// `pv`: the sender has verified the proof of this link's peer (section 8.5). Only stops the peer resending; never routing.
    public let peerVerified: Bool

    public init(
        version: Int = MeshAnnounce.wireVersion,
        nodeIdHex: String,
        identityFingerprintHex: String,
        displayHint: String? = nil,
        neighborNodeIdsHex: [String] = [],
        challengeHex: String? = nil,
        peerVerified: Bool = false
    ) {
        self.version = version
        self.nodeIdHex = nodeIdHex
        self.identityFingerprintHex = identityFingerprintHex
        self.displayHint = displayHint
        self.neighborNodeIdsHex = neighborNodeIdsHex
        self.challengeHex = challengeHex
        self.peerVerified = peerVerified
    }

    /// Canonical wire JSON (docs/mesh/MESH_LINK_SPEC.md section 8.2): members
    /// `v`, `node`, `fp`, `nbrs` in that order, UTF-8, no whitespace, and no
    /// `hint`. `nbrs` lists at most ``maxNeighbors`` node ids. Every value is a
    /// number or lowercase hex, so nothing needs escaping.
    public func encode() -> Data {
        let neighbors = neighborNodeIdsHex.prefix(Self.maxNeighbors).map { "\"" + $0 + "\"" }.joined(separator: ",")
        var json = "{\"v\":\(version),\"node\":\"\(nodeIdHex)\",\"fp\":\"\(identityFingerprintHex)\",\"nbrs\":[\(neighbors)]"
        if let challengeHex, Self.isChallengeHex(challengeHex) {
            json += ",\"ch\":\"\(challengeHex)\""
            if peerVerified { json += ",\"pv\":1" }
        }
        json += "}"
        return Data(json.utf8)
    }

    /// Why an ANNOUNCE body was refused.
    public enum DecodeError: String, Error, Equatable, Sendable {
        case notJson = "not_json"
        case version
        case neighbors
        case node
        case fingerprint
    }

    /// Strict receiver rules of section 8.2. Key order and escaping do not matter.
    /// Rejected: `v` absent or not 1; `node` or `fp` absent or not 16 lowercase hex
    /// characters; `node` equal to the broadcast id. Accepted: `hint` absent, null
    /// or a string, unknown members (ignored), `nbrs` absent (empty). Entries of
    /// `nbrs` that are not valid node ids are dropped first, then the first
    /// ``maxNeighbors`` valid ones are kept.
    public static func decodeStrict(_ bytes: Data) -> Result<MeshAnnounce, DecodeError> {
        // `v` must be the integer 1 as written (1.0 and "1" are not), and `nbrs`, when present, must be an array
        // (null, a string or an object reject the ANNOUNCE): both need the raw text of the member, which a decoded
        // number no longer has.
        guard let members = topLevelMembers(bytes) else { return .failure(.notJson) }
        guard members["v"] == "1" else { return .failure(.version) }
        if let rawNeighbors = members["nbrs"], !rawNeighbors.hasPrefix("[") { return .failure(.neighbors) }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: bytes) else { return .failure(.notJson) }
        guard wire.v == wireVersion else { return .failure(.version) }
        guard let node = wire.node, isNodeIdHex(node), node != MeshNodeId.broadcast.hex else { return .failure(.node) }
        guard let fp = wire.fp, isNodeIdHex(fp) else { return .failure(.fingerprint) }
        let valid: [String] = (wire.nbrs ?? []).compactMap { entry in
            guard let id = entry.value, isNodeIdHex(id) else { return nil }
            return id
        }
        let neighbors: [String] = Array(valid.prefix(maxNeighbors))
        return .success(MeshAnnounce(
            version: wireVersion, nodeIdHex: node, identityFingerprintHex: fp,
            displayHint: wire.hint?.value, neighborNodeIdsHex: neighbors,
            // `ch` is optional; anything but 32 lowercase hex characters reads as absent (a peer without proofs).
            challengeHex: wire.ch?.value.flatMap { isChallengeHex($0) ? $0 : nil },
            // `pv` is read strictly: only the number 1 as written counts; a string, a boolean, 1.0 or anything else reads as absent.
            peerVerified: members["pv"] == "1" && (wire.ch?.value.map { isChallengeHex($0) } ?? false)
        ))
    }

    /// The raw JSON text of every member of the top-level object, keyed by member name (last one wins). Nested
    /// values are skipped as a whole. Nil if the bytes are not a JSON object this scanner can walk; a body it walks
    /// but that is otherwise invalid is still refused by the decoder after it.
    static func topLevelMembers(_ data: Data) -> [String: String]? {
        let b = [UInt8](data)
        var i = 0
        func skipWhitespace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }
        /// Index just past the string literal that starts at `start` (a quote).
        func endOfString(_ start: Int) -> Int? {
            var j = start + 1
            while j < b.count {
                if b[j] == 0x5C { j += 2; continue }
                if b[j] == 0x22 { return j + 1 }
                j += 1
            }
            return nil
        }
        skipWhitespace()
        guard i < b.count, b[i] == 0x7B else { return nil }
        i += 1
        var members: [String: String] = [:]
        skipWhitespace()
        if i < b.count, b[i] == 0x7D { return members }
        while i < b.count {
            skipWhitespace()
            guard i < b.count, b[i] == 0x22, let keyEnd = endOfString(i) else { return nil }
            let keyText = String(decoding: b[i..<keyEnd], as: UTF8.self)
            guard let key = try? JSONDecoder().decode(String.self, from: Data(keyText.utf8)) else { return nil }
            i = keyEnd
            skipWhitespace()
            guard i < b.count, b[i] == 0x3A else { return nil }
            i += 1
            skipWhitespace()
            let valueStart = i
            var depth = 0
            while i < b.count {
                let c = b[i]
                if c == 0x22 {
                    guard let end = endOfString(i) else { return nil }
                    i = end
                    continue
                }
                if c == 0x7B || c == 0x5B { depth += 1 }
                if c == 0x7D || c == 0x5D {
                    if depth == 0 { break }
                    depth -= 1
                }
                if c == 0x2C && depth == 0 { break }
                i += 1
            }
            guard i < b.count else { return nil }
            var valueEnd = i
            while valueEnd > valueStart, b[valueEnd - 1] == 0x20 || b[valueEnd - 1] == 0x09 || b[valueEnd - 1] == 0x0A || b[valueEnd - 1] == 0x0D { valueEnd -= 1 }
            members[key] = String(decoding: b[valueStart..<valueEnd], as: UTF8.self)
            if b[i] == 0x2C { i += 1; continue }
            return members
        }
        return nil
    }

    /// A string member that may be present with any other JSON type: the other type reads as absent.
    private struct LenientString: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    /// The members the receiver looks at. A wrong type for `v`, `node` or `fp` fails the decode (and with it the
    /// ANNOUNCE); unknown members are ignored.
    private struct Wire: Decodable {
        let v: Int?
        let node: String?
        let fp: String?
        let hint: LenientString?
        let nbrs: [LenientString]?
        let ch: LenientString?
    }

    public static func decode(_ bytes: Data) -> MeshAnnounce? {
        if case .success(let announce) = decodeStrict(bytes) { return announce }
        return nil
    }

    static func isChallengeHex(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func isNodeIdHex(_ value: String) -> Bool {
        (try? MeshNodeId(hex: value)) != nil
    }
}
