import Foundation

/// Compact binary codec for [GroupState] snapshots (mirror of the
/// 1:1 RatchetSnapshotCodec layout, scaled out to N recv chains).
///
/// **Wire layout** (big-endian):
/// ```
///   u8  version = 0x01
///   u32 len(groupId) | groupId
///   u32 groupEpoch
///   u32 utf8Len(selfId) | selfId
///   u32 memberCount  | (utf8Len | utf8) per member
///   u32 adminCount   | (utf8Len | utf8) per admin
///   <send chain block>
///   u32 recvChainCount
///   for each: utf8Len | senderId | <chain block>
///
///   <chain block> =
///     u32 len(ck) | ck
///     u64 nextIdx
///     u64 lastSeenIdx (UInt64.max = nil sentinel)
///     u32 skippedCount
///     for each: u64 idx | u32 len | key | u32 len | nonce | u64 expiresAtMs
/// ```
public enum GroupSessionSnapshotCodec {

    public enum CodecError: Error, Equatable {
        case versionMismatch(UInt8)
        case truncated(remaining: Int, expected: Int)
        case stringTooLong(Int)
        case countOutOfRange(Int)
    }

    public static let version: UInt8 = 0x01

    // MARK: - Public encode / decode

    public static func encode(_ state: GroupState) -> Data {
        var out = Data()
        out.append(version)
        appendBlob(&out, state.groupIdBytes)
        appendUInt32BE(&out, state.groupEpoch)
        appendUtf8(&out, state.selfId)
        appendStringList(&out, state.members)
        appendStringList(&out, state.admins)
        appendChain(&out, state.sendChain)
        appendUInt32BE(&out, UInt32(state.recvChains.count))
        for (senderId, chain) in state.recvChains {
            appendUtf8(&out, senderId)
            appendChain(&out, chain)
        }
        return out
    }

    public static func decode(_ data: Data) throws -> GroupState {
        var off = data.startIndex
        try ensure(data, off, 1)
        let v = data[off]; off += 1
        guard v == version else { throw CodecError.versionMismatch(v) }
        let groupId = try readBlob(data, &off)
        let epoch = try readUInt32BE(data, &off)
        let selfId = try readUtf8(data, &off)
        let members = try readStringList(data, &off)
        let admins = try readStringList(data, &off)
        let sendChain = try readChain(data, &off)
        let recvCount = Int(try readUInt32BE(data, &off))
        guard recvCount >= 0, recvCount <= 1024 else {
            throw CodecError.countOutOfRange(recvCount)
        }
        var recvChains: [(String, GroupSenderChain)] = []
        recvChains.reserveCapacity(recvCount)
        for _ in 0..<recvCount {
            let sid = try readUtf8(data, &off)
            let chain = try readChain(data, &off)
            recvChains.append((sid, chain))
        }
        return GroupState(
            groupIdBytes: groupId,
            groupEpoch: epoch,
            members: members,
            admins: admins,
            selfId: selfId,
            sendChain: sendChain,
            recvChains: recvChains
        )
    }

    // MARK: - Chain block

    private static func appendChain(_ out: inout Data, _ chain: GroupSenderChain) {
        appendBlob(&out, chain.ck)
        appendUInt64BE(&out, chain.nextIdx)
        appendUInt64BE(&out, chain.lastSeenIdx ?? UInt64.max)
        appendUInt32BE(&out, UInt32(chain.skipped.count))
        for (idx, sk) in chain.skipped {
            appendUInt64BE(&out, idx)
            appendBlob(&out, sk.key)
            appendBlob(&out, sk.nonce)
            appendUInt64BE(&out, UInt64(bitPattern: sk.expiresAtMs))
        }
    }

    private static func readChain(_ data: Data, _ off: inout Int) throws -> GroupSenderChain {
        let ck = try readBlob(data, &off)
        let nextIdx = try readUInt64BE(data, &off)
        let lastSeenRaw = try readUInt64BE(data, &off)
        let lastSeen: UInt64? = (lastSeenRaw == UInt64.max) ? nil : lastSeenRaw
        let count = Int(try readUInt32BE(data, &off))
        guard count >= 0, count <= GroupSenderKey.skippedKeysCacheMax else {
            throw CodecError.countOutOfRange(count)
        }
        var skipped: [(UInt64, GroupSkippedKey)] = []
        skipped.reserveCapacity(count)
        for _ in 0..<count {
            let idx = try readUInt64BE(data, &off)
            let key = try readBlob(data, &off)
            let nonce = try readBlob(data, &off)
            let exp = try readUInt64BE(data, &off)
            skipped.append((idx, GroupSkippedKey(
                key: key, nonce: nonce, expiresAtMs: Int64(bitPattern: exp))))
        }
        return GroupSenderChain(
            ck: ck, nextIdx: nextIdx, lastSeenIdx: lastSeen, skipped: skipped)
    }

    // MARK: - String list

    private static func appendStringList(_ out: inout Data, _ items: [String]) {
        appendUInt32BE(&out, UInt32(items.count))
        for s in items { appendUtf8(&out, s) }
    }

    private static func readStringList(_ data: Data, _ off: inout Int) throws -> [String] {
        let n = Int(try readUInt32BE(data, &off))
        guard n >= 0, n <= 1024 else { throw CodecError.countOutOfRange(n) }
        var out: [String] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try readUtf8(data, &off)) }
        return out
    }

    // MARK: - Primitives

    private static func appendUtf8(_ out: inout Data, _ s: String) {
        let utf8 = Data(s.utf8)
        precondition(utf8.count <= 64 * 1024)
        appendUInt32BE(&out, UInt32(utf8.count))
        out.append(utf8)
    }

    private static func appendBlob(_ out: inout Data, _ b: Data) {
        precondition(b.count <= 64 * 1024)
        appendUInt32BE(&out, UInt32(b.count))
        out.append(b)
    }

    private static func appendUInt32BE(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func appendUInt64BE(_ out: inout Data, _ v: UInt64) {
        for i in (0..<8).reversed() { out.append(UInt8((v >> (i * 8)) & 0xFF)) }
    }

    private static func ensure(_ data: Data, _ off: Int, _ need: Int) throws {
        if data.endIndex - off < need {
            throw CodecError.truncated(remaining: data.endIndex - off, expected: need)
        }
    }

    private static func readUtf8(_ data: Data, _ off: inout Int) throws -> String {
        let len = Int(try readUInt32BE(data, &off))
        guard len >= 0, len <= 64 * 1024 else { throw CodecError.stringTooLong(len) }
        try ensure(data, off, len)
        let s = String(data: data.subdata(in: off..<(off + len)), encoding: .utf8) ?? ""
        off += len
        return s
    }

    private static func readBlob(_ data: Data, _ off: inout Int) throws -> Data {
        let len = Int(try readUInt32BE(data, &off))
        guard len >= 0, len <= 64 * 1024 else { throw CodecError.stringTooLong(len) }
        try ensure(data, off, len)
        let b = data.subdata(in: off..<(off + len))
        off += len
        return b
    }

    private static func readUInt32BE(_ data: Data, _ off: inout Int) throws -> UInt32 {
        try ensure(data, off, 4)
        let v = (UInt32(data[off]) << 24) |
                (UInt32(data[off + 1]) << 16) |
                (UInt32(data[off + 2]) << 8) |
                 UInt32(data[off + 3])
        off += 4
        return v
    }

    private static func readUInt64BE(_ data: Data, _ off: inout Int) throws -> UInt64 {
        try ensure(data, off, 8)
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[off + i]) }
        off += 8
        return v
    }
}
