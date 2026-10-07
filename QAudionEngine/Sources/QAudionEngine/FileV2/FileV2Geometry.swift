import Foundation

/// The chunk geometry of one file (sections 12.4, 12.5 and 12.10), as TOTAL functions: an index outside
/// `0..<totalChunks`, negative included, never traps (no `UInt64(index)` of a negative number, no overflow): the
/// lengths of a chunk that does not exist are 0 and its offset is `nil`.
struct FileV2Geometry: Sendable {
    /// The real size of the file (`sz`).
    let plaintextSize: UInt64
    /// `padme(sz)`.
    let streamLength: UInt64
    let totalChunks: Int

    func contains(chunk index: Int) -> Bool { index >= 0 && index < totalChunks }

    /// The length of chunk `index` in the stream, padding included: `CHUNK` for all but the last.
    func chunkStreamLength(_ index: Int) -> Int {
        guard contains(chunk: index) else { return 0 }
        if index < totalChunks - 1 { return FileV2.chunkSize }
        return Int(streamLength - UInt64(totalChunks - 1) * UInt64(FileV2.chunkSize))
    }

    /// How many REAL file bytes chunk `index` carries (the rest of the chunk is zero padding).
    func chunkFileLength(_ index: Int) -> Int {
        guard contains(chunk: index) else { return 0 }
        let start = UInt64(index) * UInt64(FileV2.chunkSize)
        guard start < plaintextSize else { return 0 }
        return Int(min(UInt64(chunkStreamLength(index)), plaintextSize - start))
    }

    /// The length of the sealed chunk `index`: its stream length plus the 16-byte tag.
    func sealedChunkLength(_ index: Int) -> Int {
        guard contains(chunk: index) else { return 0 }
        return chunkStreamLength(index) + FileV2.tagSize
    }

    /// `64 + index x STRIDE`: where the sealed chunk sits in the blob; `nil` for an index outside the file.
    func blobOffset(ofChunk index: Int) -> UInt64? {
        guard contains(chunk: index) else { return nil }
        return UInt64(FileV2.headerLength) + UInt64(index) * UInt64(FileV2.stride)
    }

    /// `64 + stream_len + 16 x total_chunks`.
    var blobLength: UInt64 {
        UInt64(FileV2.headerLength) + streamLength + UInt64(totalChunks) * UInt64(FileV2.tagSize)
    }
}
