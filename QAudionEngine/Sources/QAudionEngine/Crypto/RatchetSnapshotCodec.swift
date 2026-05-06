import Foundation

/// Compact binary codec for [RatchetSnapshot]. Wire byte layout matches
/// Android's `RatchetSnapshotCodec` (qaudion-engine `RatchetVault.kt`)
/// so a snapshot exported from one platform can in principle be
/// imported on the other (used by the multi-device link transfer flow).
///
/// **Layout** (all multi-byte ints big-endian, lengths are int32 BE):
/// ```
///   u8  version = 0x01
///   u32 utf8Len(epochId) | epochId
///   u32 utf8Len(selfId)  | selfId
///   u32 utf8Len(peerId)  | peerId
///   u8  sendDirFlag
///   u8  recvDirFlag
///   u32 len(ckSend) | ckSend
///   u64 nextSendIdx
///   u32 len(ckRecv) | ckRecv
///   u64 lastSeenRecvIdx (0xFFFFFFFFFFFFFFFF = nil sentinel)
///   u32 skippedCount
///   for each:
///     u64 idx
///     u32 len(key) | key
///     u32 len(nonce) | nonce
///     u64 expiresAtMs
/// ```
public enum RatchetSnapshotCodec {

    public enum CodecError: Error, Equatable {
        case versionMismatch(UInt8)
        case truncated(Int, expected: Int)
        case stringTooLong(Int)
        case skippedCountOutOfRange(Int)
    }

    public static let version: UInt8 = 0x01

    // MARK: - Encode

    public static func encode(_ snap: RatchetSnapshot) -> Data {
        var out = Data()
        out.append(version)
        appendUtf8(&out, snap.epochId)
        appendUtf8(&out, snap.selfId)
        appendUtf8(&out, snap.peerId)
        out.append(snap.sendDirFlag)
        out.append(snap.recvDirFlag)
        appendBlob(&out, snap.ckSend)
        appendUInt64BE(&out, snap.nextSendIdx)
        appendBlob(&out, snap.ckRecv)
        appendUInt64BE(&out, snap.lastSeenRecvIdx ?? UInt64.max)
        appendUInt32BE(&out, UInt32(snap.skipped.count))
        for entry in snap.skipped {
            appendUInt64BE(&out, entry.idx)
            appendBlob(&out, entry.key)
            appendBlob(&out, entry.nonce)
            // expiresAtMs is Int64 — store via reinterpret to UInt64 BE.
            appendUInt64BE(&out, UInt64(bitPattern: entry.expiresAtMs))
        }
        return out
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> RatchetSnapshot {
        var off = data.startIndex
        guard data.count >= 1 else { throw CodecError.truncated(data.count, expected: 1) }
        let v = data[off]; off += 1
        guard v == version else { throw CodecError.versionMismatch(v) }
        let epochId = try readUtf8(data, &off)
        let selfId = try readUtf8(data, &off)
        let peerId = try readUtf8(data, &off)
        try ensure(data, off, 2)
        let sendDirFlag = data[off]; off += 1
        let recvDirFlag = data[off]; off += 1
        let ckSend = try readBlob(data, &off)
        let nextSendIdx = try readUInt64BE(data, &off)
        let ckRecv = try readBlob(data, &off)
        let lastSeenRaw = try readUInt64BE(data, &off)
        let lastSeenRecvIdx: UInt64? = (lastSeenRaw == UInt64.max) ? nil : lastSeenRaw
        let count = Int(try readUInt32BE(data, &off))
        guard count >= 0, count <= MessageRatchet.skippedKeysCacheMax else {
            throw CodecError.skippedCountOutOfRange(count)
        }
        var skipped: [RatchetSnapshot.SkippedEntry] = []
        skipped.reserveCapacity(count)
        for _ in 0..<count {
            let idx = try readUInt64BE(data, &off)
            let key = try readBlob(data, &off)
            let nonce = try readBlob(data, &off)
            let exp = try readUInt64BE(data, &off)
            skipped.append(RatchetSnapshot.SkippedEntry(
                idx: idx, key: key, nonce: nonce,
                expiresAtMs: Int64(bitPattern: exp)))
        }
        return RatchetSnapshot(
            epochId: epochId, selfId: selfId, peerId: peerId,
            sendDirFlag: sendDirFlag, recvDirFlag: recvDirFlag,
            ckSend: ckSend, nextSendIdx: nextSendIdx,
            ckRecv: ckRecv, lastSeenRecvIdx: lastSeenRecvIdx,
            skipped: skipped
        )
    }

    // MARK: - Internal helpers

    private static func appendUtf8(_ out: inout Data, _ s: String) {
        let utf8 = Data(s.utf8)
        precondition(utf8.count <= 64 * 1024, "string too long: \(utf8.count)")
        appendUInt32BE(&out, UInt32(utf8.count))
        out.append(utf8)
    }

    private static func appendBlob(_ out: inout Data, _ b: Data) {
        precondition(b.count <= 64 * 1024, "blob too long: \(b.count)")
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
        for i in (0..<8).reversed() {
            out.append(UInt8((v >> (i * 8)) & 0xFF))
        }
    }

    private static func ensure(_ data: Data, _ off: Int, _ need: Int) throws {
        if data.endIndex - off < need {
            throw CodecError.truncated(data.endIndex - off, expected: need)
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
        for i in 0..<8 {
            v = (v << 8) | UInt64(data[off + i])
        }
        off += 8
        return v
    }
}
