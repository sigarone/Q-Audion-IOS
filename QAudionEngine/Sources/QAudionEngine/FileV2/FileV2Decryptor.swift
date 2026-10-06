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
///
/// Concurrency: chunks may be delivered from several threads at once (parallel parts, several sources). The map of
/// verified chunks, every write to the output and `finalize` are serialised by one lock; the AES-GCM open, which is
/// the expensive part, runs outside it, so chunks are verified in parallel. Two threads delivering the SAME chunk end
/// with one `written` and one `alreadyVerified`. A `FileHandle` itself must not be used by other code while a
/// decryptor writes to it.
///
/// `close()` wipes the key material (the `Data` copies it holds; CryptoKit clears its own `SymmetricKey` when the last
/// reference goes away) and the decryptor then neither opens nor writes anything: `FileV2Error.closed`. A receiver
/// that gets `qa_file_cancel`, or gives up, closes its decryptor and deletes what it wrote.
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

    private let geometry: FileV2Geometry
    /// Guards the state below.
    private let lock = NSLock()
    private var keys: FileV2DerivedKeys?
    private var closed = false
    private var verified: [Bool]
    private var verifiedTotal: Int

    public var streamLength: UInt64 { header.streamLength }
    public var totalChunks: Int { header.totalChunks }
    /// `64 + stream_len + 16 x total_chunks`: the exact length of the blob.
    public var blobLength: UInt64 { geometry.blobLength }

    /// Section 12.9 steps 1 and 2 for the fields of a descriptor, in the order of the reference receiver
    /// (see `FileV2Header.validate`).
    ///
    /// `verifiedChunks` restores the local map of a resumed transfer, and it is TRUSTED: the library cannot re-verify a
    /// chunk whose ciphertext it no longer has (nothing but the tag proves a chunk, and the tags are not kept). The
    /// indices are range-checked (`invalidArgument` otherwise) and that is all. The trust is the one the pipeline
    /// already places in its own local state, so the pipeline owns the consequences: it persists the map only after
    /// the chunk's plaintext is written to the output, it keeps the output and the map together (never in a backup),
    /// and it calls `dropVerifiedChunksMissing(in:)` with the output before delivering anything, which unmarks every
    /// restored chunk whose bytes are no longer in the output file. A chunk it distrusts for any other reason it
    /// unmarks with `markUnverified(chunk:)` and requests again.
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
        self.geometry = FileV2Geometry(plaintextSize: size, streamLength: validated.header.streamLength,
                                       totalChunks: total)
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

    deinit {
        keys?.wipe()
    }

    // MARK: Closing

    /// Wipes the key material and refuses every later open, receive and finalize with `closed`. Idempotent. A chunk
    /// that is already being opened on another thread finishes with the key it started with, but is not written.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        keys?.wipe()
        keys = nil
    }

    private func activeKeys() throws -> FileV2DerivedKeys {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let keys = keys else { throw FileV2Error.closed }
        return keys
    }

    // MARK: Geometry

    /// The plaintext length of chunk `index` in the stream, padding included: `CHUNK` for all but the last. 0 for an
    /// index outside the file (never traps).
    public func chunkStreamLength(_ index: Int) -> Int { geometry.chunkStreamLength(index) }

    /// The exact length of the sealed chunk `index`: `STRIDE`, or the last chunk's length plus the tag. 0 for an index
    /// outside the file.
    public func sealedChunkLength(_ index: Int) -> Int { geometry.sealedChunkLength(index) }

    /// `64 + index x STRIDE`: where the sealed chunk sits in the blob. `nil` for an index outside the file.
    public func blobOffset(ofChunk index: Int) -> UInt64? { geometry.blobOffset(ofChunk: index) }

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
        let openingKeys = try activeKeys()
        guard geometry.contains(chunk: index) else { return nil }
        guard sealed.count == sealedChunkLength(index) else { throw FileV2Error.chunkAuth }
        let nonce = FileV2Crypto.chunkNonce(prefix: openingKeys.noncePrefix, index: UInt32(index))
        let aad = FileV2Crypto.chunkAAD(header: header.bytes, index: UInt32(index), final: index == totalChunks - 1)
        return try FileV2Crypto.open(sealed: sealed, key: openingKeys.encryptionKey, nonce: nonce, aad: aad)
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

    /// Takes chunk `index` out of the map of verified chunks, so that it is requested and verified again (a chunk the
    /// pipeline no longer trusts: see `init(... verifiedChunks:)`). Returns whether it was marked. An index outside
    /// the file is ignored.
    @discardableResult
    public func markUnverified(chunk index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < verified.count, verified[index] else { return false }
        verified[index] = false
        verifiedTotal -= 1
        return true
    }

    /// Checks a restored map against the output file it describes and unmarks every chunk whose plaintext is not (or no
    /// longer) fully inside it: a chunk is kept only if the output is long enough to hold its bytes. Returns the
    /// indices unmarked, ascending, so the caller requests them again. A size check only: the bytes themselves cannot
    /// be re-verified without the ciphertext, so the pipeline still owns the integrity of its local state (see
    /// `init(... verifiedChunks:)`).
    @discardableResult
    public func dropVerifiedChunksMissing(in output: FileHandle) throws -> [Int] {
        let outputLength = try output.seekToEnd()
        lock.lock(); defer { lock.unlock() }
        var dropped: [Int] = []
        for index in verified.indices where verified[index] {
            let end = UInt64(index) * UInt64(FileV2.chunkSize) + UInt64(geometry.chunkStreamLength(index))
            if outputLength < end {
                verified[index] = false
                verifiedTotal -= 1
                dropped.append(index)
            }
        }
        return dropped
    }

    /// Opens chunk `index` and, only if it verifies, writes its plaintext at `index x CHUNK` of `output` and
    /// marks it verified. An index past the end is `discarded`, a chunk already verified is `alreadyVerified`
    /// (and is not even opened). A failed chunk throws `chunk_auth`, writes nothing and leaves the map as it was,
    /// so it can be requested again, from the same or another source.
    ///
    /// Safe to call from several threads for one output (the write is serialised); a `FileHandle` itself must not be used
    /// by other code at the same time.
    public func receive(index: Int, sealed: Data, writingTo output: FileHandle) throws -> ChunkOutcome {
        _ = try activeKeys()
        guard geometry.contains(chunk: index) else { return .discarded }
        if isVerified(chunk: index) { return .alreadyVerified }
        guard let plain = try openChunk(index: index, sealed: sealed) else { return .discarded }
        lock.lock(); defer { lock.unlock() }
        // Closed while this chunk was being opened: nothing is written after `close()`.
        guard !closed else { throw FileV2Error.closed }
        if verified[index] { return .alreadyVerified }
        try output.seek(toOffset: UInt64(index) * UInt64(FileV2.chunkSize))
        try output.write(contentsOf: plain)
        verified[index] = true
        verifiedTotal += 1
        return .written
    }

    // MARK: End of the stream

    /// The source ended the stream: the server's object ends, or the direct channel sent `DONE` (section 12.9,
    /// "incomplete transfer"). If chunks of the map are still missing the transfer is INCOMPLETE and this throws
    /// `size_mismatch`, whether the stream ended at a chunk boundary or inside a chunk (the bytes of a truncated chunk
    /// are not a chunk: they are never handed to `receive`), and never `bad_padding`: the padding is checked at
    /// `finalize`, on a complete stream only. Returns normally when every chunk is verified.
    ///
    /// A connection that fails or times out is NOT an end of stream: the caller resumes from `missingChunks` and does
    /// not call this.
    public func endOfStream() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw FileV2Error.closed }
        guard verifiedTotal == totalChunks else { throw FileV2Error.sizeMismatch }
    }

    // MARK: Step 5

    /// Section 12.9 step 5: all `total_chunks` chunks verified (otherwise `size_mismatch`, as a blob with a missing
    /// chunk), the padding in `[sz, stream_len)` all zero (`bad_padding`), then truncation to `sz`.
    /// `output` must be open for reading AND writing (`FileHandle(forUpdating:)`): the padding is read back.
    public func finalize(output: FileHandle) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw FileV2Error.closed }
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
    /// stays on disk, and the map of verified chunks is emptied with it (the decryptor is fresh again, and still open:
    /// the pipeline may try another source, or `close()` it). `progress` is called after each chunk with the number
    /// of chunks done.
    ///
    /// Errors: `header_mismatch` (a blob shorter than the header, or a different header), `size_mismatch` (the blob
    /// length is not `64 + stream_len + 16 x total_chunks`, which covers a missing or extra byte and a missing last
    /// chunk), `chunk_auth`, `bad_padding`.
    public func decryptFile(from blob: URL, to destination: URL, progress: ((Int) -> Void)? = nil) throws {
        _ = try activeKeys()
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
        defer {
            if !finished {
                // The destination is gone, so the chunks it held are gone: the map must not claim them any more
                // (a later receive into another output would skip them as "already verified").
                try? fileManager.removeItem(at: destination)
                forgetEveryVerifiedChunk()
            }
        }
        // Read and write: `finalize` reads the padding back before truncating.
        let output = try FileHandle(forUpdating: destination)
        var outputClosed = false
        defer { if !outputClosed { try? output.close() } }

        for index in 0..<totalChunks {
            try autoreleasepool {
                // The length was checked, so a short read means the blob changed under us.
                guard let offset = blobOffset(ofChunk: index),
                      let sealed = try readExactly(sealedChunkLength(index), at: offset, from: input) else {
                    throw FileV2Error.sizeMismatch
                }
                _ = try receive(index: index, sealed: sealed, writingTo: output)
            }
            progress?(index + 1)
        }
        try finalize(output: output)
        outputClosed = true
        try output.close()
        finished = true
    }

    /// Empties the map of verified chunks (the output they were written to no longer exists).
    private func forgetEveryVerifiedChunk() {
        lock.lock(); defer { lock.unlock() }
        verified = [Bool](repeating: false, count: verified.count)
        verifiedTotal = 0
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
