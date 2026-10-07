import Foundation

/// The on-disk format of a send journal (one file per transfer, append only).
///
/// ```
/// file   = magic(4) || record*
/// magic  = 51 53 4A 01                      "QSJ" and the format version
/// record = len(4, big endian) || type(1) || payload(len) || crc32(4, big endian)
/// crc32  = IEEE CRC-32 of  type || payload
/// ```
///
/// Types: 1 begin, 2 object, 3 token, 4 tags, 5 part done, 6 phase. `begin`, `object` and `token` carry JSON (the records of
/// FileV2SendRecords.swift); `tags` is binary (`u32 part`, `u8 count`, then `count` x (`u32 chunk index`, 16 bytes of tag));
/// `part done` is the `u32` part; `phase` is one byte.
///
/// Reading. The first record must be the begin record. Reading stops at the first record that is incomplete (a length that
/// runs past the end of the file), too large, of an unknown type, or whose CRC does not match, and everything from there on is a
/// torn or corrupt TAIL: it is ignored, and the next append truncates the file back to the last good record. A record whose CRC
/// is right but whose payload cannot be decoded is `corrupt` (a bug or another version, never a torn write).
///
/// Why ignoring a tail is safe for the nonce rule (WIRE_SPEC 12.8). A `tags` record is appended and flushed BEFORE the part it
/// covers is PUT, and a flush that fails (`fsync`, `F_FULLFSYNC`) fails the append, so the part is not PUT. A record that a crash
/// tore was therefore never followed by a PUT of its part.
///
/// What this does NOT make impossible: a `tags` record that the platform reported as flushed and then lost, or that media damage
/// destroyed (the scan then drops it and everything after it as a tail). The pipeline narrows that case but does not close it:
///
/// - after a resume it checks that every part the server still holds has all its chunk tags in the journal, and cancels the
///   transfer if one is missing. That compares against an object that EXISTS: if the server has deleted it (6 hours idle, 24 hours
///   at the latest) the object is created again and there is nothing to compare;
/// - the source identity (`FileV2SourceIdentity`: size, modification time to the nanosecond, inode, creation time, SHA-256 of the
///   first and last 64 KiB) is checked before anything is sealed, so a source that was replaced or edited at its ends is found.
///
/// What is left is the coincidence of three independent faults: the journal lost the tags of a part that was transmitted, the
/// server no longer holds the object, and the file was edited in its middle without any of the things the identity holds changing.
/// The first needs the platform or the media to lose a write it acknowledged, the third a tool that restores times by hand.
///
/// A record type this version does not know (written by a newer version of the app) ends the scan like a corrupt record does:
/// after a downgrade the next append cuts it off. The cross-check above covers the parts the server still holds.
enum FileV2JournalFormat {
    static let magic: [UInt8] = [0x51, 0x53, 0x4A, 0x01]
    /// Largest payload a record may declare: a corrupt length must never size an allocation.
    static let maxPayload = 1 << 20
    static let frameOverhead = 4 + 1 + 4

    enum RecordType: UInt8 {
        case begin = 1, object = 2, token = 3, tags = 4, partDone = 5, phase = 6
    }

    // MARK: Encoding

    static func headerBytes() -> Data { Data(magic) }

    static func encodeBegin(_ record: FileV2SendBeginRecord) throws -> Data {
        frame(.begin, try json(record))
    }

    static func encode(_ event: FileV2SendJournalEvent) throws -> Data {
        switch event {
        case .object(let record): return frame(.object, try json(record))
        case .token(let record): return frame(.token, try json(record))
        case .tags(let part, let entries):
            guard part >= 0, entries.count <= 255 else { throw FileV2SendStoreError.corrupt("tags") }
            var payload = Data()
            payload.append(contentsOf: FileV2Crypto.bigEndian(UInt32(truncatingIfNeeded: part)))
            payload.append(UInt8(entries.count))
            for entry in entries {
                guard entry.index >= 0, entry.tag.count == FileV2.tagSize else { throw FileV2SendStoreError.corrupt("tags") }
                payload.append(contentsOf: FileV2Crypto.bigEndian(UInt32(truncatingIfNeeded: entry.index)))
                payload.append(entry.tag)
            }
            return frame(.tags, payload)
        case .partDone(let part):
            guard part >= 0 else { throw FileV2SendStoreError.corrupt("part") }
            return frame(.partDone, Data(FileV2Crypto.bigEndian(UInt32(truncatingIfNeeded: part))))
        case .phase(let phase):
            return frame(.phase, Data([phase.rawValue]))
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(value) } catch { throw FileV2SendStoreError.corrupt("encode") }
    }

    private static func frame(_ type: RecordType, _ payload: Data) -> Data {
        var body = Data()
        body.reserveCapacity(1 + payload.count)
        body.append(type.rawValue)
        body.append(payload)
        var out = Data()
        out.reserveCapacity(frameOverhead + payload.count)
        out.append(contentsOf: FileV2Crypto.bigEndian(UInt32(truncatingIfNeeded: payload.count)))
        out.append(body)
        out.append(contentsOf: FileV2Crypto.bigEndian(FileV2CRC32.checksum(body)))
        return out
    }

    // MARK: Decoding

    /// One record that passed the length and CRC checks.
    struct RawRecord {
        let type: RecordType
        let payload: Data
    }

    struct Scan {
        let records: [RawRecord]
        /// The length of the file up to the end of the last good record (the magic included).
        let validLength: Int
        let droppedTailBytes: Int
    }

    /// Splits `bytes` into records. Throws `corrupt` only when the magic is missing or wrong; a bad record ends the scan.
    static func scan(_ bytes: [UInt8]) throws -> Scan {
        guard bytes.count >= magic.count, Array(bytes[0..<magic.count]) == magic else {
            throw FileV2SendStoreError.corrupt("magic")
        }
        var position = magic.count
        var records: [RawRecord] = []
        while position < bytes.count {
            guard bytes.count - position >= frameOverhead else { break }
            let length = Int(readU32(bytes, position))
            guard length <= maxPayload else { break }
            let end = position + frameOverhead + length
            guard end <= bytes.count else { break }
            let typeByte = bytes[position + 4]
            let payloadStart = position + 5
            let payloadEnd = payloadStart + length
            let stored = readU32(bytes, payloadEnd)
            let computed = FileV2CRC32.checksum(bytes[(position + 4)..<payloadEnd])
            guard stored == computed, let type = RecordType(rawValue: typeByte) else { break }
            records.append(RawRecord(type: type, payload: Data(bytes[payloadStart..<payloadEnd])))
            position = end
        }
        return Scan(records: records, validLength: position, droppedTailBytes: bytes.count - position)
    }

    /// The begin record and the events of a scan, replayed.
    static func replay(_ scan: Scan) throws -> FileV2SendRecovered {
        guard let first = scan.records.first, first.type == .begin else { throw FileV2SendStoreError.corrupt("begin") }
        let begin: FileV2SendBeginRecord
        do { begin = try JSONDecoder().decode(FileV2SendBeginRecord.self, from: first.payload) } catch {
            throw FileV2SendStoreError.corrupt("begin")
        }
        guard begin.version == FileV2SendBeginRecord.currentVersion else { throw FileV2SendStoreError.corrupt("version") }
        var recovered = FileV2SendRecovered(begin: begin, droppedTailBytes: scan.droppedTailBytes)
        for record in scan.records.dropFirst() {
            recovered.apply(try decodeEvent(record))
        }
        return recovered
    }

    static func decodeEvent(_ record: RawRecord) throws -> FileV2SendJournalEvent {
        let decoder = JSONDecoder()
        let bytes = Array(record.payload)
        switch record.type {
        case .begin:
            throw FileV2SendStoreError.corrupt("second begin")
        case .object:
            do { return .object(try decoder.decode(FileV2SendObjectRecord.self, from: record.payload)) } catch {
                throw FileV2SendStoreError.corrupt("object")
            }
        case .token:
            do { return .token(try decoder.decode(FileV2SendTokenRecord.self, from: record.payload)) } catch {
                throw FileV2SendStoreError.corrupt("token")
            }
        case .tags:
            guard bytes.count >= 5 else { throw FileV2SendStoreError.corrupt("tags") }
            let part = Int(readU32(bytes, 0))
            let count = Int(bytes[4])
            guard bytes.count == 5 + count * (4 + FileV2.tagSize) else { throw FileV2SendStoreError.corrupt("tags") }
            var entries: [FileV2SendTag] = []
            var offset = 5
            for _ in 0..<count {
                let index = Int(readU32(bytes, offset))
                entries.append(FileV2SendTag(index: index, tag: Data(bytes[(offset + 4)..<(offset + 4 + FileV2.tagSize)])))
                offset += 4 + FileV2.tagSize
            }
            return .tags(part: part, entries: entries)
        case .partDone:
            guard bytes.count == 4 else { throw FileV2SendStoreError.corrupt("part") }
            return .partDone(Int(readU32(bytes, 0)))
        case .phase:
            guard bytes.count == 1, let phase = FileV2SendPhase(rawValue: bytes[0]) else {
                throw FileV2SendStoreError.corrupt("phase")
            }
            return .phase(phase)
        }
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

/// IEEE CRC-32 (polynomial 0xEDB88320, reflected), the checksum of every journal record.
enum FileV2CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
