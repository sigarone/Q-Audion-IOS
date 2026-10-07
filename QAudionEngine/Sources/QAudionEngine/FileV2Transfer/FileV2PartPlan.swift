import Foundation

/// How a v2 blob is cut into the parts of the parts protocol: part `p` holds chunks `8p ..< min(8p + 8, total)`, and its
/// bytes in the blob are `64 + p * partSize`, `partSize` long (the last part is shorter). Pure arithmetic, no I/O: the send
/// pipeline seals the chunks of a part into one body, the receive pipeline fetches a part and cuts it back into chunks.
///
/// `make` checks the plan against the server's own geometry (`FileV2Wire.partLength`), so a disagreement between the format
/// library and the protocol constants is a refused plan, never a part of the wrong length on the wire.
public struct FileV2PartPlan: Equatable, Sendable {

    public struct Part: Equatable, Sendable {
        public let index: Int
        /// Index of the first chunk of the part.
        public let firstChunk: Int
        /// Number of chunks in the part (8, or fewer for the last part).
        public let chunkCount: Int
        /// Offset of the part in the blob.
        public let blobOffset: Int64
        /// Exact length of the part, in bytes: what `Content-Length` and the `Range` of the part say.
        public let byteLength: Int

        /// The `Range` of the part, `from` and `toInclusive`.
        public var range: (from: Int64, toInclusive: Int64) { (blobOffset, blobOffset + Int64(byteLength) - 1) }
    }

    public let blobLength: Int64
    public let totalChunks: Int
    public let parts: [Part]

    /// `nil` when the lengths do not agree: `totalChunks` of 0, a blob that is not `64 + payload` for that many chunks, or a
    /// part count above `FileV2Wire.maxParts`.
    public static func make(blobLength: Int64, totalChunks: Int) -> FileV2PartPlan? {
        guard totalChunks >= 1, totalChunks <= FileV2.maxChunks else { return nil }
        let partCount = FileV2Wire.partCount(blobLength: blobLength)
        let expectedParts = totalChunks / FileV2Wire.chunksPerPart + (totalChunks % FileV2Wire.chunksPerPart == 0 ? 0 : 1)
        guard partCount == expectedParts, partCount >= 1, partCount <= FileV2Wire.maxParts else { return nil }
        var parts: [Part] = []
        parts.reserveCapacity(partCount)
        for index in 0..<partCount {
            let first = index * FileV2Wire.chunksPerPart
            let count = min(FileV2Wire.chunksPerPart, totalChunks - first)
            guard let offset = FileV2Wire.partOffset(index) else { return nil }
            let length = FileV2Wire.partLength(blobLength: blobLength, part: index)
            guard length > 0, count >= 1 else { return nil }
            // every chunk but the last is a full stride, the last is shorter by the padding it does not use
            if index < partCount - 1, length != FileV2Wire.partSize { return nil }
            parts.append(Part(index: index, firstChunk: first, chunkCount: count, blobOffset: offset, byteLength: length))
        }
        return FileV2PartPlan(blobLength: blobLength, totalChunks: totalChunks, parts: parts)
    }
}
