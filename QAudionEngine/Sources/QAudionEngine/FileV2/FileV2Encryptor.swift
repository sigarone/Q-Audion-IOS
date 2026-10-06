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
/// Every `sealChunk` goes through the `FileV2TagLedger` (section 12.8 rule 2): a chunk that was already
/// encrypted once must give the same tag again, otherwise nothing is returned and
/// `FileV2Error.contentChanged` is thrown. `K` and `file_id` are never reused for a second content:
/// a forwarded or re-sent file is a new encryptor.
public final class FileV2Encryptor: @unchecked Sendable {
    /// The 32-byte file key `K`. Secret: it only leaves this object inside the end-to-end descriptor.
    public let fileKey: Data
    public let header: FileV2Header
    /// The real size of the file, `1...maxSize`.
    public let plaintextSize: UInt64
    public let tagLedger: FileV2TagLedger

    private let keys: FileV2DerivedKeys

    public var fileID: Data { header.fileID }
    public var streamLength: UInt64 { header.streamLength }
    public var totalChunks: Int { header.totalChunks }
    /// `64 + stream_len + 16 x total_chunks`.
    public var blobLength: UInt64 {
        UInt64(FileV2.headerLength) + header.streamLength + UInt64(header.totalChunks) * UInt64(FileV2.tagSize)
    }

    /// An encryptor for a file of `plaintextSize` bytes under the given key material (a resume, or a test).
    /// `plaintextSize` must be in `1...maxSize` and `K` 32 bytes, `file_id` 16 bytes.
    public init(fileKey: Data, fileID: Data, plaintextSize: UInt64,
                tagLedger: FileV2TagLedger = FileV2TagLedger()) throws {
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
        self.fileKey = Data(fileKey)
        self.plaintextSize = plaintextSize
        self.tagLedger = tagLedger
        self.keys = derived
        self.header = FileV2Header(fileID: Data(fileID), streamLength: streamLength, totalChunks: Int(total),
                                   commitment: derived.commitment)
    }

    /// A new file: a fresh random `K` and `file_id` from the operating system's generator.
    public static func makeNew(plaintextSize: UInt64,
                               tagLedger: FileV2TagLedger = FileV2TagLedger()) throws -> FileV2Encryptor {
        try FileV2Encryptor(fileKey: FileV2.generateFileKey(), fileID: FileV2.generateFileID(),
                            plaintextSize: plaintextSize, tagLedger: tagLedger)
    }

    // MARK: Geometry

    /// The length of chunk `index` in the stream, padding included: `CHUNK` for all but the last.
    public func chunkStreamLength(_ index: Int) -> Int {
        if index < totalChunks - 1 { return FileV2.chunkSize }
        return Int(streamLength - UInt64(totalChunks - 1) * UInt64(FileV2.chunkSize))
    }

    /// How many REAL file bytes chunk `index` carries (the rest of the chunk is zero padding).
    public func chunkFileLength(_ index: Int) -> Int {
        let start = UInt64(index) * UInt64(FileV2.chunkSize)
        guard start < plaintextSize else { return 0 }
        return Int(min(UInt64(chunkStreamLength(index)), plaintextSize - start))
    }

    /// The length of the sealed chunk `index`: its stream length plus the 16-byte tag.
    public func sealedChunkLength(_ index: Int) -> Int { chunkStreamLength(index) + FileV2.tagSize }

    /// `64 + index x STRIDE`: where the sealed chunk sits in the blob.
    public func blobOffset(ofChunk index: Int) -> UInt64 {
        UInt64(FileV2.headerLength) + UInt64(index) * UInt64(FileV2.stride)
    }

    // MARK: Chunks

    /// Seals chunk `index` from its real file bytes (`chunkFileLength(index)` of them; the zero padding is added
    /// here) and returns `ciphertext || tag(16)`, `sealedChunkLength(index)` bytes.
    ///
    /// Deterministic: the same content gives the same bytes on every call, so a retry or a resume may
    /// call it again. If the chunk was sealed before and the tag differs, throws `contentChanged` and returns
    /// nothing (section 12.8 rule 2).
    public func sealChunk(index: Int, fileBytes: Data) throws -> Data {
        guard index >= 0, index < totalChunks else { throw FileV2Error.invalidArgument("chunk index") }
        guard fileBytes.count == chunkFileLength(index) else {
            throw FileV2Error.invalidArgument("chunk content length")
        }
        return try seal(index: index, final: index == totalChunks - 1, fileBytes: fileBytes)
    }

    /// Seals chunk `index` reading its bytes from `handle` (a short read, which means the source shrank, is
    /// `contentChanged`). A handle is not shared between threads: parallel workers use one handle each.
    public func sealChunk(index: Int, from handle: FileHandle) throws -> Data {
        guard index >= 0, index < totalChunks else { throw FileV2Error.invalidArgument("chunk index") }
        let length = chunkFileLength(index)
        var content = Data()
        if length > 0 {
            try handle.seek(toOffset: UInt64(index) * UInt64(FileV2.chunkSize))
            content.reserveCapacity(length)
            while content.count < length {
                guard let piece = try handle.read(upToCount: length - content.count), !piece.isEmpty else {
                    throw FileV2Error.contentChanged
                }
                content.append(piece)
            }
        }
        return try seal(index: index, final: index == totalChunks - 1, fileBytes: content)
    }

    private func seal(index: Int, final: Bool, fileBytes: Data) throws -> Data {
        var plain = fileBytes
        let streamLength = chunkStreamLength(index)
        if plain.count < streamLength { plain.append(Data(count: streamLength - plain.count)) }
        let nonce = FileV2Crypto.chunkNonce(prefix: keys.noncePrefix, index: UInt32(index))
        let aad = FileV2Crypto.chunkAAD(header: header.bytes, index: UInt32(index), final: final)
        let sealed = try FileV2Crypto.seal(plaintext: plain, key: keys.encryptionKey, nonce: nonce, aad: aad)
        // Section 12.8 rule 2: the tag must match T[i] before the chunk leaves the process.
        try tagLedger.checkOrRecord(index: index, tag: Data(sealed.suffix(FileV2.tagSize)))
        return sealed
    }

    // MARK: File to file

    /// Encrypts the whole file at `source` into the blob `destination` (header, then every chunk), one chunk
    /// at a time. `destination` must not exist; on any failure it is removed.
    ///
    /// The source must still be `plaintextSize` bytes long at the start and at the end (section 12.8 rule 1:
    /// a source that changed cancels the transfer), otherwise `contentChanged`. `progress` is called after each
    /// chunk with the number of chunks done.
    public func encryptFile(from source: URL, to destination: URL, progress: ((Int) -> Void)? = nil) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileV2Error.invalidArgument("destination exists")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.seekToEnd() == plaintextSize else { throw FileV2Error.contentChanged }

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
        guard try input.seekToEnd() == plaintextSize else { throw FileV2Error.contentChanged }
        outputClosed = true
        try output.close()
        finished = true
    }
}
