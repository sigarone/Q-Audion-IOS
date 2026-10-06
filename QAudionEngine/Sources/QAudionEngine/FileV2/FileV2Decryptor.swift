import Foundation

/// The receiver of a v2 file (sections 12.6 and 12.9).
///
/// Building a decryptor runs the descriptor checks of section 12.9 steps 1 and 2 (the header against `K`,
/// `sz` and the id, the commitment in constant time, BEFORE any chunk is decrypted). Then:
///
///  - `verifySourceHeader` is step 3: the first 64 bytes of the blob (or the `HELLO` frame of the direct
///    channel) equal the descriptor header byte for byte (`header_mismatch`);
///  - `openChunk` is step 4 for one chunk presented on its own: an index past the end is dropped without
///    allocating anything and without an error, the length must be exact, the whole 16-byte tag is checked
///    (`chunk_auth`);
///  - `receive` opens a chunk and writes the verified plaintext at `index x CHUNK` of the output, keeping the
///    map of verified chunks: a chunk that was already verified is ignored, and completion is counted on the
///    map, never on the number of chunks received (any order, any source, any number of times);
///  - `finalize` is step 5: every chunk verified, the padding all zero, truncation to `sz`;
///  - `decryptFile` runs steps 3 to 5 for a blob stored in a file, one chunk at a time.
///
/// No plaintext byte is written before its chunk is verified. Peak memory is one chunk, whatever the file size.
/// A decryptor is for one file and one output.
public final class FileV2Decryptor: @unchecked Sendable {

    /// What `receive` did with a chunk.
    public enum ChunkOutcome: Equatable, Sendable {
        /// Verified and written.
        case written
        /// Already verified earlier: ignored.
        case alreadyVerified
        /// An index past the end of the file: dropped, no error.
        case discarded
    }

    public let header: FileV2Header
    /// The real size of the file (`sz`).
    public let plaintextSize: UInt64

    private let keys: FileV2DerivedKeys
    private let lock = NSLock()
    private var verified: [Bool]
    private var verifiedTotal: Int

    public var streamLength: UInt64 { header.streamLength }
    public var totalChunks: Int { header.totalChunks }
    /// `64 + stream_len + 16 x total_chunks`: the exact length of the blob.
    public var blobLength: UInt64 {
        UInt64(FileV2.headerLength) + header.streamLength + UInt64(header.totalChunks) * UInt64(FileV2.tagSize)
    }

    /// Section 12.9 steps 1 and 2 for the fields of a descriptor, in the order of the reference receiver
    /// (see `FileV2Header.validate`). `verifiedChunks` restores the local map of a resumed transfer: the
    /// receiver's own persisted state, trusted as such.
    public init(fileID: Data, fileKey: Data, header headerBytes: Data, size: UInt64,
                verifiedChunks: Set<Int> = []) throws {
        let validated = try FileV2Header.validate(headerBytes: headerBytes, fileID: fileID,
                                                  fileKey: fileKey, size: size)
        let total = validated.header.totalChunks
        guard verifiedChunks.allSatisfy({ $0 >= 0 && $0 < total }) else {
            throw FileV2Error.invalidArgument("resume state")
        }
        self.header = validated.header
        self.plaintextSize = size
        self.keys = validated.keys
        var map = [Bool](repeating: false, count: total)
        for index in verifiedChunks { map[index] = true }
        self.verified = map
        self.verifiedTotal = verifiedChunks.count
    }

    /// A decryptor for a parsed descriptor. Its header was validated by `FileV2Descriptor.parse`; it is checked again here (cheap).
    public convenience init(descriptor: FileV2Descriptor, verifiedChunks: Set<Int> = []) throws {
        try self.init(fileID: descriptor.fileID, fileKey: descriptor.fileKey, header: descriptor.header.bytes,
                      size: descriptor.size, verifiedChunks: verifiedChunks)
    }

    // MARK: Geometry

    /// The plaintext length of chunk `index` in the stream, padding included: `CHUNK` for all but the last.
    public func chunkStreamLength(_ index: Int) -> Int {
        if index < totalChunks - 1 { return FileV2.chunkSize }
        return Int(streamLength - UInt64(totalChunks - 1) * UInt64(FileV2.chunkSize))
    }

    /// The exact length of the sealed chunk `index`: `STRIDE`, or the last chunk's length plus the tag.
    public func sealedChunkLength(_ index: Int) -> Int { chunkStreamLength(index) + FileV2.tagSize }

    /// `64 + index x STRIDE`: where the sealed chunk sits in the blob.
    public func blobOffset(ofChunk index: Int) -> UInt64 {
        UInt64(FileV2.headerLength) + UInt64(index) * UInt64(FileV2.stride)
    }

    // MARK: Step 3

    /// Section 12.9 step 3: the header of the source equals the header of the descriptor, byte for byte.
    /// Throws `header_mismatch`.
    public func verifySourceHeader(_ sourceHeader: Data) throws {
        guard sourceHeader.count == FileV2.headerLength, sourceHeader == header.bytes else {
            throw FileV2Error.headerMismatch
        }
    }

    // MARK: Step 4

    /// Opens one sealed chunk (`ciphertext || tag`) presented on its own and returns its plaintext (padding
    /// included). Returns `nil`, with no error and nothing allocated, for an index outside the file. A wrong
    /// length or a failed GCM open is `chunk_auth`.
    public func openChunk(index: Int, sealed: Data) throws -> Data? {
        guard index >= 0, index < totalChunks else { return nil }
        guard sealed.count == sealedChunkLength(index) else { throw FileV2Error.chunkAuth }
        let nonce = FileV2Crypto.chunkNonce(prefix: keys.noncePrefix, index: UInt32(index))
        let aad = FileV2Crypto.chunkAAD(header: header.bytes, index: UInt32(index), final: index == totalChunks - 1)
        return try FileV2Crypto.open(sealed: sealed, key: keys.encryptionKey, nonce: nonce, aad: aad)
    }

    // MARK: The map of verified chunks

    public var verifiedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return verifiedTotal
    }

    public var isComplete: Bool { verifiedCount == totalChunks }

    public func isVerified(chunk index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return index >= 0 && index < verified.count && verified[index]
    }

    /// The indices still to be received, ascending.
    public var missingChunks: [Int] {
        lock.lock(); defer { lock.unlock() }
        return verified.indices.filter { !verified[$0] }
    }

    /// The verified indices: what the local resume state persists.
    public var verifiedChunks: Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return Set(verified.indices.filter { verified[$0] })
    }

    /// Opens chunk `index` and, only if it verifies, writes its plaintext at `index x CHUNK` of `output` and
    /// marks it verified. An index past the end is `discarded`, a chunk already verified is `alreadyVerified`
    /// (and is not even opened). A failed chunk throws `chunk_auth`, writes nothing and leaves the map as it was,
    /// so it can be requested again, from the same or another source.
    ///
    /// Safe to call from several threads for one output (the write is serialised); a `FileHandle` itself must not be used
    /// by other code at the same time.
    public func receive(index: Int, sealed: Data, writingTo output: FileHandle) throws -> ChunkOutcome {
        guard index >= 0, index < totalChunks else { return .discarded }
        if isVerified(chunk: index) { return .alreadyVerified }
        guard let plain = try openChunk(index: index, sealed: sealed) else { return .discarded }
        lock.lock(); defer { lock.unlock() }
        if verified[index] { return .alreadyVerified }
        try output.seek(toOffset: UInt64(index) * UInt64(FileV2.chunkSize))
        try output.write(contentsOf: plain)
        verified[index] = true
        verifiedTotal += 1
        return .written
    }

    // MARK: Step 5

    /// Section 12.9 step 5: all `total_chunks` chunks verified (otherwise `size_mismatch`, as a blob with a missing
    /// chunk), the padding in `[sz, stream_len)` all zero (`bad_padding`), then truncation to `sz`.
    /// `output` must be open for reading AND writing (`FileHandle(forUpdating:)`): the padding is read back.
    public func finalize(output: FileHandle) throws {
        lock.lock(); defer { lock.unlock() }
        guard verifiedTotal == totalChunks else { throw FileV2Error.sizeMismatch }
        if streamLength > plaintextSize {
            try output.seek(toOffset: plaintextSize)
            var remaining = streamLength - plaintextSize
            while remaining > 0 {
                let wanted = Int(min(remaining, UInt64(FileV2.chunkSize)))
                guard let block = try output.read(upToCount: wanted), !block.isEmpty else {
                    throw FileV2Error.sizeMismatch
                }
                if block.contains(where: { $0 != 0 }) { throw FileV2Error.badPadding }
                remaining -= UInt64(block.count)
            }
        }
        try output.truncate(atOffset: plaintextSize)
    }

    // MARK: File to file

    /// Decrypts the blob stored at `blob` into the plaintext file `destination`, steps 3 to 5, one chunk at a
    /// time (the blob is never loaded whole). `destination` must not exist and the decryptor must be a fresh one
    /// (nothing verified yet); on any failure the destination is removed, so no unverified or partial plaintext
    /// stays on disk. `progress` is called after each chunk with the number of chunks done.
    ///
    /// Errors: `header_mismatch` (a blob shorter than the header, or a different header), `size_mismatch` (the blob
    /// length is not `64 + stream_len + 16 x total_chunks`, which covers a missing or extra byte and a missing last
    /// chunk), `chunk_auth`, `bad_padding`.
    public func decryptFile(from blob: URL, to destination: URL, progress: ((Int) -> Void)? = nil) throws {
        guard verifiedCount == 0 else { throw FileV2Error.invalidArgument("decryptFile needs a fresh decryptor") }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileV2Error.invalidArgument("destination exists")
        }
        let input = try FileHandle(forReadingFrom: blob)
        defer { try? input.close() }
        let length = try input.seekToEnd()

        // Step 3, then the blob length.
        guard length >= UInt64(FileV2.headerLength) else { throw FileV2Error.headerMismatch }
        try verifySourceHeader(try readExactly(FileV2.headerLength, at: 0, from: input) ?? Data())
        guard length == blobLength else { throw FileV2Error.sizeMismatch }

        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw FileV2Error.invalidArgument("cannot create destination")
        }
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: destination) } }
        // Read and write: `finalize` reads the padding back before truncating.
        let output = try FileHandle(forUpdating: destination)
        var outputClosed = false
        defer { if !outputClosed { try? output.close() } }

        for index in 0..<totalChunks {
            try autoreleasepool {
                // The length was checked, so a short read means the blob changed under us.
                guard let sealed = try readExactly(sealedChunkLength(index), at: blobOffset(ofChunk: index),
                                                   from: input) else { throw FileV2Error.sizeMismatch }
                _ = try receive(index: index, sealed: sealed, writingTo: output)
            }
            progress?(index + 1)
        }
        try finalize(output: output)
        outputClosed = true
        try output.close()
        finished = true
    }

    /// Reads exactly `count` bytes at `offset`; `nil` if the file ends first.
    private func readExactly(_ count: Int, at offset: UInt64, from handle: FileHandle) throws -> Data? {
        try handle.seek(toOffset: offset)
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let piece = try handle.read(upToCount: count - data.count), !piece.isEmpty else { return nil }
            data.append(piece)
        }
        return data
    }
}
