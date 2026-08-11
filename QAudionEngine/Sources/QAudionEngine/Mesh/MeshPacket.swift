import Foundation

/// Wire packet discriminator. See ``MeshPacket`` for the envelope layout.
public enum MeshPacketType: UInt8, Equatable, Sendable {
    /// Opaque `MessageCrypto` ciphertext (single-fragment or whole message).
    case data = 0x01
    /// One fragment of a larger DATA payload — see ``MeshFragmenter``.
    case fragment = 0x02
    /// Periodic self-announce: identity + optionally the peers this node is
    /// directly connected to right now. Unlike every other packet type, an
    /// `.announce` packet's payload is NOT `MessageCrypto` ciphertext — it
    /// is this transport's own control data (``MeshAnnounce``).
    case announce = 0x03
    /// Optional transport-level delivery ack to the immediate next hop —
    /// NOT an app-level read receipt.
    case ack = 0x04
}

/// The mesh wire envelope: version, type, sender, recipient (with
/// ``MeshNodeId/broadcast`` sentinel), optional TTL, optional source-route
/// hop list, timestamp, and the opaque payload.
///
/// `encode()`/`decode(_:)` are pure and deterministic — no I/O, no
/// CoreBluetooth type — so this whole envelope is unit-testable on the bare
/// Swift Package Manager test target. `decode(_:)` never throws: malformed
/// bytes from a hostile or buggy peer simply yield `nil`.
///
/// Byte layout (all multi-byte integers big-endian):
/// ```
/// [0]        version            (u8)
/// [1]        type.rawValue      (u8)
/// [2..10)    senderId           (8 bytes)
/// [10..18)   recipientId        (8 bytes — broadcast sentinel or a real id)
/// [18]       flags              (u8: bit0=hasTtl, bit1=hasSourceRoute)
/// [..]       ttl                (u8, present iff flags.bit0)
/// [..]       hopCount           (u8, present iff flags.bit1)
/// [..]       sourceRoute hops   (hopCount * 8 bytes, present iff flags.bit1)
/// [..]       timestampMs        (i64, big-endian)
/// [..]       payloadLength      (u32, big-endian)
/// [..]       payload            (payloadLength bytes)
/// ```
public struct MeshPacket: Equatable, Sendable {

    public static let wireVersion: Int = 1

    /// Hard sanity ceiling on the WHOLE logical payload (post-reassembly,
    /// pre-fragmentation) — NOT the per-BLE-write chunk size, which is
    /// ``MeshFragmenter/threshold``.
    public static let maxPayloadBytes = 16 * 1024

    /// Default hop budget stamped onto a freshly-originated DATA packet.
    /// Consumed by ``MeshRelayPolicy`` as the TTL-fraction input to its
    /// relay-probability curve.
    public static let defaultTTL = 5

    public let version: Int
    public let type: MeshPacketType
    public let senderId: MeshNodeId
    public let recipientId: MeshNodeId
    /// Hop budget. `nil` on packet types never relayed (a direct
    /// single-hop ANNOUNCE or ACK). Present and positive on a
    /// freshly-originated DATA/FRAGMENT packet — see ``defaultTTL``.
    public let ttl: Int?
    /// Populated only when the sender already resolved a source route to
    /// `recipientId` (see ``MeshTopology/nextHop(for:maxHops:)``). Empty
    /// when the packet is being flood-relayed with no known path.
    public let sourceRoute: [MeshNodeId]
    public let timestampMs: Int64
    /// Opaque `MessageCrypto` ciphertext (or, for `.announce`, this
    /// transport's own control body — see ``MeshPacketType/announce``).
    /// This type never parses or decrypts it.
    public let payload: Data

    public enum MeshPacketError: Error, Equatable {
        case versionOutOfRange(Int)
        case ttlOutOfRange(Int)
        case sourceRouteTooLong(Int)
        case payloadTooLarge(Int)
    }

    public init(
        version: Int = MeshPacket.wireVersion,
        type: MeshPacketType,
        senderId: MeshNodeId,
        recipientId: MeshNodeId,
        ttl: Int? = nil,
        sourceRoute: [MeshNodeId] = [],
        timestampMs: Int64,
        payload: Data
    ) throws {
        guard (1...255).contains(version) else {
            throw MeshPacketError.versionOutOfRange(version)
        }
        if let ttl { guard (0...255).contains(ttl) else { throw MeshPacketError.ttlOutOfRange(ttl) } }
        guard sourceRoute.count <= 255 else {
            throw MeshPacketError.sourceRouteTooLong(sourceRoute.count)
        }
        guard payload.count <= MeshPacket.maxPayloadBytes else {
            throw MeshPacketError.payloadTooLarge(payload.count)
        }
        self.version = version
        self.type = type
        self.senderId = senderId
        self.recipientId = recipientId
        self.ttl = ttl
        self.sourceRoute = sourceRoute
        self.timestampMs = timestampMs
        self.payload = payload
    }

    /// Same field set with `ttl`/`payload` swapped out — used by the relay
    /// path (decrement TTL, re-encode, forward) without re-validating the
    /// rest of the envelope by hand at every call site.
    public func withTTL(_ newTTL: Int?) -> MeshPacket {
        // Constructing via `try!` is safe here: every field except `ttl`
        // was already validated once by `self`, and `newTTL` is always
        // produced internally by ``MeshRelayPolicy`` as `ttl - 1` of an
        // already-validated `ttl`, which can only shrink towards 0.
        try! MeshPacket(
            version: version, type: type, senderId: senderId, recipientId: recipientId,
            ttl: newTTL, sourceRoute: sourceRoute, timestampMs: timestampMs, payload: payload
        )
    }

    private static let flagHasTTL: UInt8 = 0x01
    private static let flagHasSourceRoute: UInt8 = 0x02

    public func encode() -> Data {
        var flags: UInt8 = 0
        if ttl != nil { flags |= Self.flagHasTTL }
        if !sourceRoute.isEmpty { flags |= Self.flagHasSourceRoute }

        var out = Data()
        out.reserveCapacity(19 + (ttl != nil ? 1 : 0) + (sourceRoute.isEmpty ? 0 : 1 + sourceRoute.count * MeshNodeId.sizeBytes) + 12 + payload.count)
        out.append(UInt8(version))
        out.append(type.rawValue)
        out.append(senderId.toBytes())
        out.append(recipientId.toBytes())
        out.append(flags)
        if let ttl { out.append(UInt8(ttl)) }
        if !sourceRoute.isEmpty {
            out.append(UInt8(sourceRoute.count))
            for hop in sourceRoute { out.append(hop.toBytes()) }
        }
        out.append(bigEndianBytes(timestampMs))
        out.append(bigEndianBytes(UInt32(payload.count)))
        out.append(payload)
        return out
    }

    /// Never throws — malformed/truncated bytes from a hostile or buggy
    /// peer simply yield `nil`.
    public static func decode(_ bytes: Data) -> MeshPacket? {
        var reader = ByteReader(bytes)
        guard let versionByte = reader.readUInt8() else { return nil }
        guard let typeByte = reader.readUInt8(), let type = MeshPacketType(rawValue: typeByte) else { return nil }
        guard let senderBytes = reader.readBytes(MeshNodeId.sizeBytes), let senderId = MeshNodeId.fromBytes(senderBytes) else { return nil }
        guard let recipientBytes = reader.readBytes(MeshNodeId.sizeBytes), let recipientId = MeshNodeId.fromBytes(recipientBytes) else { return nil }
        guard let flags = reader.readUInt8() else { return nil }

        var ttl: Int? = nil
        if flags & flagHasTTL != 0 {
            guard let t = reader.readUInt8() else { return nil }
            ttl = Int(t)
        }
        var sourceRoute: [MeshNodeId] = []
        if flags & flagHasSourceRoute != 0 {
            guard let hopCount = reader.readUInt8() else { return nil }
            for _ in 0..<hopCount {
                guard let hopBytes = reader.readBytes(MeshNodeId.sizeBytes), let hop = MeshNodeId.fromBytes(hopBytes) else { return nil }
                sourceRoute.append(hop)
            }
        }
        guard let timestampMs = reader.readInt64() else { return nil }
        guard let payloadLen = reader.readUInt32() else { return nil }
        guard payloadLen <= UInt32(maxPayloadBytes), let payload = reader.readBytes(Int(payloadLen)) else { return nil }

        return try? MeshPacket(
            version: Int(versionByte), type: type, senderId: senderId, recipientId: recipientId,
            ttl: ttl, sourceRoute: sourceRoute, timestampMs: timestampMs, payload: payload
        )
    }
}

// MARK: - Byte-level helpers (shared by every codec in this directory)

func bigEndianBytes(_ value: Int64) -> Data {
    let u = UInt64(bitPattern: value)
    var out = Data(capacity: 8)
    for shift in stride(from: 56, through: 0, by: -8) {
        out.append(UInt8((u >> UInt64(shift)) & 0xFF))
    }
    return out
}

func bigEndianBytes(_ value: UInt32) -> Data {
    var out = Data(capacity: 4)
    for shift in stride(from: 24, through: 0, by: -8) {
        out.append(UInt8((value >> UInt32(shift)) & 0xFF))
    }
    return out
}

/// Minimal forward-only cursor over `Data`, used by every `decode(_:)` in
/// this directory instead of raw index arithmetic — a truncated/malformed
/// buffer runs out of bytes and every subsequent `read*` call returns `nil`
/// rather than trapping.
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readUInt8() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset = data.index(after: offset) }
        return data[offset]
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0 else { return nil }
        guard let end = data.index(offset, offsetBy: count, limitedBy: data.endIndex) else { return nil }
        defer { offset = end }
        return data[offset..<end]
    }

    mutating func readInt64() -> Int64? {
        guard let bytes = readBytes(8) else { return nil }
        var v: UInt64 = 0
        for byte in bytes { v = (v << 8) | UInt64(byte) }
        return Int64(bitPattern: v)
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        var v: UInt32 = 0
        for byte in bytes { v = (v << 8) | UInt32(byte) }
        return v
    }
}
