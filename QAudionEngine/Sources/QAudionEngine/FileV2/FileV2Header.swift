import Foundation

/// The 64-byte header of a v2 blob (section 12.4).
///
/// ```
/// offset  len  field
/// 0       4    magic_version = 51 41 46 02
/// 4       16   file_id
/// 20      8    stream_len     u64be, 1..MAX_STREAM
/// 28      4    total_chunks   u32be = ceil(stream_len / CHUNK), 1..MAX_CHUNKS
/// 32      32   commitment
/// ```
///
/// The header is a shared object: the same 64 bytes for every recipient of the blob, and the whole header
/// is bound into the AAD of every chunk (section 12.5), so `bytes` is what the AAD carries.
public struct FileV2Header: Equatable, Sendable {
    public let fileID: Data
    public let streamLength: UInt64
    public let totalChunks: Int
    public let commitment: Data
    /// The exact 64 serialised bytes.
    public let bytes: Data

    /// Builds the header of a file (sender side). The caller has already checked the ranges.
    init(fileID: Data, streamLength: UInt64, totalChunks: Int, commitment: Data) {
        var raw = Data()
        raw.reserveCapacity(FileV2.headerLength)
        raw.append(contentsOf: FileV2.magic)
        raw.append(fileID)
        raw.append(contentsOf: FileV2Crypto.bigEndian(streamLength))
        raw.append(contentsOf: FileV2Crypto.bigEndian(UInt32(truncatingIfNeeded: totalChunks)))
        raw.append(commitment)
        self.fileID = fileID
        self.streamLength = streamLength
        self.totalChunks = totalChunks
        self.commitment = commitment
        self.bytes = raw
    }

    private init(parsedBytes: Data, streamLength: UInt64, totalChunks: Int) {
        self.fileID = parsedBytes.subdata(in: 4..<20)
        self.streamLength = streamLength
        self.totalChunks = totalChunks
        self.commitment = parsedBytes.subdata(in: 32..<64)
        self.bytes = parsedBytes
    }

    /// Structural parse of a received header: length, magic, `stream_len` in `1...maxStream`,
    /// `total_chunks` in `1...maxChunks` and equal to `ceil(stream_len / CHUNK)`. Anything wrong is
    /// `bad_header`. The commitment and the Padme rule need `K` and `sz` and are checked by
    /// `validate(headerBytes:fileID:fileKey:size:)`.
    public static func parse(_ data: Data) throws -> FileV2Header {
        guard data.count == FileV2.headerLength else { throw FileV2Error.badHeader }
        let octets = [UInt8](data)
        let raw = Data(octets)  // zero-based copy, whatever slice the caller passed
        guard Array(octets.prefix(4)) == FileV2.magic else { throw FileV2Error.badHeader }
        var streamLength: UInt64 = 0
        for index in 20..<28 { streamLength = (streamLength << 8) | UInt64(octets[index]) }
        var total: UInt64 = 0
        for index in 28..<32 { total = (total << 8) | UInt64(octets[index]) }
        guard streamLength >= 1, streamLength <= FileV2.maxStream else { throw FileV2Error.badHeader }
        guard total >= 1, total <= UInt64(FileV2.maxChunks),
              total == FileV2.chunkCount(forStreamLength: streamLength) else { throw FileV2Error.badHeader }
        return FileV2Header(parsedBytes: raw, streamLength: streamLength, totalChunks: Int(total))
    }

    /// Section 12.9 steps 1 and 2 for the header of a descriptor, in the order of the reference receiver:
    ///
    /// 1. `sz` in `1...maxSize` and the lengths of `id` (16), `K` (32) and the header (64): `bad_descriptor`
    /// 2. magic, `file_id == id`, `stream_len` and `total_chunks` in range and coherent: `bad_header`
    /// 3. `stream_len == padme(sz)`: `size_mismatch`
    /// 4. the commitment equals the one derived from `K`, in constant time: `commit_mismatch`
    ///
    /// Returns the parsed header and the keys derived from `K` (so the caller derives once).
    static func validate(headerBytes: Data, fileID: Data, fileKey: Data, size: UInt64)
        throws -> (header: FileV2Header, keys: FileV2DerivedKeys) {
        guard size >= 1, size <= FileV2.maxSize,
              fileID.count == 16, fileKey.count == 32,
              headerBytes.count == FileV2.headerLength else { throw FileV2Error.badDescriptor }
        let header = try parse(headerBytes)
        guard header.fileID == fileID else { throw FileV2Error.badHeader }
        guard header.streamLength == FileV2.padme(size) else { throw FileV2Error.sizeMismatch }
        let keys = FileV2Crypto.derive(fileKey: fileKey, fileID: fileID)
        guard FileV2Crypto.constantTimeEqual(header.commitment, keys.commitment) else {
            throw FileV2Error.commitMismatch
        }
        return (header, keys)
    }
}
