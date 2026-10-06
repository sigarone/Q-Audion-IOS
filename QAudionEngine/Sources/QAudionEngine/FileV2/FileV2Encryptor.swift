import Foundation

/// The sender of a v2 file (sections 12.2 to 12.6 and 12.8).
///
/// One encryptor is one file: one (`K`, `file_id`), one size, one header. It seals chunk by chunk
/// (`sealChunk`), which is what the part uploads and the retries use, or writes the whole blob from a source
/// file to a destination file (`encryptFile`), one chunk at a time: peak memory does not depend on the
/// file size, only on the 1 MiB chunk.
///
/// ```
/// blob        = header(64) || C_0 || C_1 || ... || C_{n-1}
/// offset(C_i) = 64 + i x STRIDE
/// len(blob)   = 64 + stream_len + 16 x n
/// ```
///
/// The stream is `file || 0x00 x (stream_len - size)`, with `stream_len = padme(size)`. The padding is
/// produced here: callers hand over the REAL bytes of the file only.
///
/// How an encryptor is made decides what its nonce ledger holds, and the ledger is OWNED by the encryptor:
///  - `makeNew(plaintextSize:)`: a new file, fresh random `K` and `file_id`, nothing encrypted yet: an empty ledger is
///    right;
///  - `resume(fileKey:fileID:plaintextSize:persistedTags:)`: a transfer that already encrypted chunks. The ledger is
///    loaded from the persisted tags (`tagEntries` of the previous run) AT CONSTRUCTION. There is no public way to
///    build an encryptor for given key material with an empty ledger: a resume that forgot its tags would encrypt
///    an edited chunk under a nonce already used, which breaks AES-GCM.
///
/// Every `sealChunk` goes through the ledger (section 12.8 rule 2): a chunk that was already encrypted once must
/// give the same tag again, otherwise nothing is returned and `FileV2Error.contentChanged` is thrown. The first
/// conflict (and a source that changed size, which is the same rule 1 case) CANCELS the encryptor for good:
/// `isCancelled` stays true, every later seal throws `contentChanged` even for a chunk whose content is unchanged
/// (the transfer is over: the sender sends `qa_file_cancel` and starts a NEW file with a new `K` and `file_id`),
/// and the key material is wiped. `K` and `file_id` are never reused for a second content: a forwarded or re-sent
/// file is a new encryptor.
///
/// `close()` wipes the key material too (the `Data` copies it holds; CryptoKit clears its own `SymmetricKey` when the
/// last reference goes away) and an encryptor never seals after it: `FileV2Error.closed`.
///
/// Thread safety: parallel workers, one index each (and one `FileHandle` each), share one encryptor.
public final class FileV2Encryptor: @unchecked Sendable {
    public let header: FileV2Header
    /// The real size of the file, `1...maxSize`.
    public let plaintextSize: UInt64
    /// The nonce ledger. Owned by this encryptor and never exposed: `tagEntries` is its persistable snapshot.
    let tagLedger: FileV2TagLedger

    private let geometry: FileV2Geometry
    /// Guards the state below.
    private let lock = NSLock()
    private var keyBytes: Data
    private var keys: FileV2DerivedKeys?
    private var cancelled = false
    private var closed = false

    public var fileID: Data { header.fileID }
    public var streamLength: UInt64 { header.streamLength }
    public var totalChunks: Int { header.totalChunks }
    /// `64 + stream_len + 16 x total_chunks`.
    public var blobLength: UInt64 { geometry.blobLength }

    /// The 32-byte file key `K`. Secret: it only leaves this object inside the end-to-end descriptor. Empty once the
    /// encryptor is closed or cancelled.
    public var fileKey: Data {
        lock.lock(); defer { lock.unlock() }
        return keyBytes
    }

    /// The tag of every chunk encrypted so far, by index: what the local transfer state persists (at most 80 KiB) and
    /// hands back to `resume`. Never goes into a backup.
    public var tagEntries: [Int: Data] { tagLedger.entries }

    /// `true` after the first conflict of section 12.8 (a changed chunk or a changed source). Sticky.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// The one designated initialiser: validates the material and loads the ledger from `persistedTags`.
    private init(fileKey: Data, fileID: Data, plaintextSize: UInt64, persistedTags: [Int: Data]) throws {
        guard fileKey.count == 32, fileID.count == 16 else {
            throw FileV2Error.invalidArgument("key or file id length")
        }
        guard plaintextSize >= 1, plaintextSize <= FileV2.maxSize else {
            throw FileV2Error.invalidArgument("size out of range")
        }
        let streamLength = FileV2.padme(plaintextSize)
        guard streamLength <= FileV2.maxStream else { throw FileV2Error.invalidArgument("size out of range") }
        let total = FileV2.chunkCount(forStreamLength: streamLength)
        guard total >= 1, total <= UInt64(FileV2.maxChunks) else {
            throw FileV2Error.invalidArgument("size out of range")
        }
        let derived = FileV2Crypto.derive(fileKey: fileKey, fileID: fileID)
        self.tagLedger = try FileV2TagLedger(entries: persistedTags, chunkCount: Int(total))
        self.keyBytes = Data([UInt8](fileKey))        // an own storage, so that `close()` can wipe it
        self.plaintextSize = plaintextSize
        self.keys = derived
        self.geometry = FileV2Geometry(plaintextSize: plaintextSize, streamLength: streamLength,
                                       totalChunks: Int(total))
        self.header = FileV2Header(fileID: Data(fileID), streamLength: streamLength, totalChunks: Int(total),
                                   commitment: derived.commitment)
    }

    /// An encryptor for a NEW file under the given key material, with an empty ledger. Internal: a caller that holds
    /// key material cannot know whether anything was ever encrypted under it, which is why the public entry points are
    /// `makeNew` (fresh random material) and `resume` (the persisted ledger). Used by `makeNew` and by the
    /// known-answer tests, whose keys are public test keys.
    convenience init(fileKey: Data, fileID: Data, plaintextSize: UInt64) throws {
        try self.init(fileKey: fileKey, fileID: fileID, plaintextSize: plaintextSize, persistedTags: [:])
    }

    /// A new file: a fresh random `K` and `file_id` from the operating system's generator, an empty ledger.
    public static func makeNew(plaintextSize: UInt64) throws -> FileV2Encryptor {
        try FileV2Encryptor(fileKey: FileV2.generateFileKey(), fileID: FileV2.generateFileID(),
                            plaintextSize: plaintextSize)
    }

    /// A transfer that already encrypted chunks (section 12.8): the key material of the local transfer state and the
    /// tags the previous run persisted (`tagEntries`), loaded into the ledger before anything can be sealed.
    ///
    /// Section 12.8 rule 1 (the source's size or modification time changed: cancel, new `K` and `file_id`) is checked
    /// by the caller against its own state before it resumes; rule 2 is enforced here from the first seal on.
    /// `persistedTags` may be empty only for a transfer that really sealed nothing. A corrupted state (an index
    /// outside the file, a tag that is not 16 bytes) is `invalidArgument`, never silently ignored.
    public static func resume(fileKey: Data, fileID: Data, plaintextSize: UInt64,
                              persistedTags: [Int: Data]) throws -> FileV2Encryptor {
        try FileV2Encryptor(fileKey: fileKey, fileID: fileID, plaintextSize: plaintextSize,
                            persistedTags: persistedTags)
    }

    deinit {
        FileV2Secret.wipe(&keyBytes)
        keys?.wipe()
    }

    // MARK: Closing and cancelling

    /// Wipes the key material and refuses every later seal with `closed`. Idempotent. A seal that is already in flight
    /// on another thread finishes with the key it started with.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        releaseKeyMaterialLocked()
    }

    private func releaseKeyMaterialLocked() {
        FileV2Secret.wipe(&keyBytes)
        keys?.wipe()
        keys = nil
    }

    /// The conflict of section 12.8: latch the cancellation (sticky) and wipe the key. Returns the error to throw.
    private func cancelForContentChange() -> FileV2Error {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        releaseKeyMaterialLocked()
        return FileV2Error.contentChanged
    }

    /// The keys to seal with, or the reason there is nothing to seal with: `contentChanged` after a conflict (sticky),
    /// `closed` after `close()`.
    private func activeKeys() throws -> FileV2DerivedKeys {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw FileV2Error.contentChanged }
        guard !closed, let keys = keys else { throw FileV2Error.closed }
        return keys
    }

    // MARK: Geometry

    /// The length of chunk `index` in the stream, padding included: `CHUNK` for all but the last. 0 for an index
    /// outside the file (never traps).
    public func chunkStreamLength(_ index: Int) -> Int { geometry.chunkStreamLength(index) }

    /// How many REAL file bytes chunk `index` carries (the rest of the chunk is zero padding). 0 for an index outside
    /// the file (never traps).
    public func chunkFileLength(_ index: Int) -> Int { geometry.chunkFileLength(index) }

    /// The length of the sealed chunk `index`: its stream length plus the 16-byte tag. 0 for an index outside the file.
    public func sealedChunkLength(_ index: Int) -> Int { geometry.sealedChunkLength(index) }

    /// `64 + index x STRIDE`: where the sealed chunk sits in the blob. `nil` for an index outside the file.
    public func blobOffset(ofChunk index: Int) -> UInt64? { geometry.blobOffset(ofChunk: index) }

    // MARK: Chunks

    /// Seals chunk `index` from its real file bytes (`chunkFileLength(index)` of them; the zero padding is added
    /// here) and returns `ciphertext || tag(16)`, `sealedChunkLength(index)` bytes.
    ///
    /// Deterministic: the same content gives the same bytes on every call, so a retry or a resume may
    /// call it again. If the chunk was sealed before and the tag differs, throws `contentChanged`, returns
    /// nothing and cancels the encryptor for good (section 12.8 rule 2).
    public func sealChunk(index: Int, fileBytes: Data) throws -> Data {
        _ = try activeKeys()
        guard geometry.contains(chunk: index) else { throw FileV2Error.invalidArgument("chunk index") }
        guard fileBytes.count == chunkFileLength(index) else {
            throw FileV2Error.invalidArgument("chunk content length")
        }
        return try seal(index: index, fileBytes: fileBytes)
    }

    /// Seals chunk `index` reading its bytes from `handle` (a short read, which means the source shrank, is
    /// `contentChanged` and cancels the encryptor). A handle is not shared between threads: parallel workers use one
    /// handle each.
    public func sealChunk(index: Int, from handle: FileHandle) throws -> Data {
        _ = try activeKeys()
        guard geometry.contains(chunk: index) else { throw FileV2Error.invalidArgument("chunk index") }
        let length = chunkFileLength(index)
        var content = Data()
        if length > 0 {
            try handle.seek(toOffset: UInt64(index) * UInt64(FileV2.chunkSize))
            content.reserveCapacity(length)
            while content.count < length {
                guard let piece = try handle.read(upToCount: length - content.count), !piece.isEmpty else {
                    throw cancelForContentChange()
                }
                content.append(piece)
            }
        }
        return try seal(index: index, fileBytes: content)
    }

    private func seal(index: Int, fileBytes: Data) throws -> Data {
        let sealingKeys = try activeKeys()
        var plain = fileBytes
        let streamLength = chunkStreamLength(index)
        if plain.count < streamLength { plain.append(Data(count: streamLength - plain.count)) }
        let nonce = FileV2Crypto.chunkNonce(prefix: sealingKeys.noncePrefix, index: UInt32(index))
        let aad = FileV2Crypto.chunkAAD(header: header.bytes, index: UInt32(index), final: index == totalChunks - 1)
        let sealed = try FileV2Crypto.seal(plaintext: plain, key: sealingKeys.encryptionKey, nonce: nonce, aad: aad)
        // Section 12.8 rule 2: the tag must match T[i] before the chunk leaves the process. The first conflict
        // cancels for good.
        do {
            try tagLedger.checkOrRecord(index: index, tag: Data(sealed.suffix(FileV2.tagSize)))
        } catch FileV2Error.contentChanged {
            throw cancelForContentChange()
        }
        // Another worker may have cancelled while this one was sealing: nothing leaves after a cancellation.
        _ = try activeKeys()
        return sealed
    }

    // MARK: File to file

    /// Encrypts the whole file at `source` into the blob `destination` (header, then every chunk), one chunk
    /// at a time. `destination` must not exist; on any failure it is removed.
    ///
    /// The source must still be `plaintextSize` bytes long at the start and at the end (section 12.8 rule 1:
    /// a source that changed cancels the transfer), otherwise `contentChanged` and the encryptor is cancelled for
    /// good. `progress` is called after each chunk with the number of chunks done.
    public func encryptFile(from source: URL, to destination: URL, progress: ((Int) -> Void)? = nil) throws {
        _ = try activeKeys()
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileV2Error.invalidArgument("destination exists")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.seekToEnd() == plaintextSize else { throw cancelForContentChange() }

        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw FileV2Error.invalidArgument("cannot create destination")
        }
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        var outputClosed = false
        defer { if !outputClosed { try? output.close() } }

        try output.write(contentsOf: header.bytes)
        for index in 0..<totalChunks {
            try autoreleasepool {
                let sealed = try sealChunk(index: index, from: input)
                try output.write(contentsOf: sealed)
            }
            progress?(index + 1)
        }
        // The source must not have grown or shrunk while it was read.
        guard try input.seekToEnd() == plaintextSize else { throw cancelForContentChange() }
        outputClosed = true
        try output.close()
        finished = true
    }
}
