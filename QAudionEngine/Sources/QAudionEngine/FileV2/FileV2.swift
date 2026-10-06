import Foundation

/// File transfer format v2 (WIRE_SPEC section 12): AES-256-GCM, chunked, Padme padding, a 64-byte
/// header carrying a key commitment, and an end-to-end descriptor that travels inside the chat text.
///
/// One format for every file, image, video, voice note, avatar, thumbnail and group attachment, over
/// every transport, with no negotiation and no legacy path.
///
/// This directory is the FORMAT LIBRARY only: CryptoKit primitives, no network, no UI, no transport
/// and no persistence. The pipeline (parts, resume state, chat wiring) is built on top of it.
///
///  - `FileV2` (this file): the constants of section 12.1, Padme (12.3), random key material (12.2)
///  - `FileV2Error`: the common error codes of section 12.9
///  - `FileV2Header`: the 64-byte header (12.4)
///  - `FileV2Descriptor`: descriptor parsing and validation (12.7, 12.9 steps 1 and 2)
///  - `FileV2Encryptor`: the sender, per chunk and file to file (12.5, 12.8)
///  - `FileV2TagLedger`: the anti-nonce-reuse rule (12.8)
///  - `FileV2Decryptor`: the receiver, per chunk and file to file (12.6, 12.9)
///
/// Memory: nothing in this library holds a whole file. The streaming entry points work one chunk
/// (1 MiB of plaintext) at a time, so peak memory does not depend on the file size.
public enum FileV2 {

    // MARK: Constants (section 12.1)

    /// Plaintext bytes per chunk (2^20). Fixed, and absent from the header: one value, one set of vectors.
    public static let chunkSize: Int = 1 << 20
    /// GCM tag length (128 bit).
    public static let tagSize: Int = 16
    /// Sealed chunk length: `chunkSize + tagSize`.
    public static let stride: Int = chunkSize + tagSize
    /// Header length in bytes.
    public static let headerLength: Int = 64
    /// Largest plaintext file, 5 GiB.
    public static let maxSize: UInt64 = 5 << 30
    /// Largest stream, `padme(maxSize)`, which is exactly 5 GiB.
    public static let maxStream: UInt64 = 5 << 30
    /// Largest number of chunks.
    public static let maxChunks: Int = 5120
    /// Largest blob: `headerLength + maxStream + maxChunks * tagSize`.
    public static let maxBlob: UInt64 = UInt64(headerLength) + maxStream + UInt64(maxChunks * tagSize)
    /// "QAF" followed by the version byte 0x02.
    public static let magic: [UInt8] = [0x51, 0x41, 0x46, 0x02]
    /// The serialised descriptor MUST stay under 8 KiB (section 12.7).
    public static let maxDescriptorBytes: Int = 8 * 1024
    /// Largest file name, in UTF-8 bytes.
    public static let maxNameBytes: Int = 255
    /// Largest media type, in UTF-8 bytes.
    public static let maxMimeBytes: Int = 128
    /// Largest decoded preview, in bytes.
    public static let maxPreviewBytes: Int = 2048

    // MARK: Padme (section 12.3)

    /// The Padme padding function. The plaintext stream of a file of `length` bytes is extended with
    /// zero bytes up to `padme(length)`.
    ///
    /// `length` is expected in `1...maxSize`; 0 returns 0. For lengths above 2^63, which the format
    /// never accepts, the result saturates at `UInt64.max` instead of trapping on overflow.
    public static func padme(_ length: UInt64) -> UInt64 {
        guard length > 0 else { return 0 }
        let e = 63 - length.leadingZeroBitCount               // floor(log2 L)
        let s = Int.bitWidth - e.leadingZeroBitCount          // bitlen(E), with bitlen(0) = 0
        let z = e - s
        if z <= 0 { return length }
        let mask = (UInt64(1) << UInt64(z)) - 1
        let (sum, overflow) = length.addingReportingOverflow(mask)
        if overflow { return UInt64.max }
        return sum & ~mask
    }

    /// `ceil(streamLength / chunkSize)`.
    public static func chunkCount(forStreamLength streamLength: UInt64) -> UInt64 {
        let chunk = UInt64(chunkSize)
        return streamLength / chunk + (streamLength % chunk == 0 ? 0 : 1)
    }

    // MARK: Key material (section 12.2)

    /// A fresh 32-byte file key `K` from the operating system's cryptographic generator.
    /// `K` and `file_id` are never reused for a second content (section 12.2).
    public static func generateFileKey() -> Data { randomBytes(32) }

    /// A fresh 16-byte `file_id` from the operating system's cryptographic generator.
    public static func generateFileID() -> Data { randomBytes(16) }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var out = Data(count: count)
        for index in 0..<count {
            out[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return out
    }
}

/// The error codes common to the three platforms (section 12.9, telemetry and negative vectors),
/// plus the local conditions the sender and the caller can hit.
///
/// `code` is the wire/telemetry string. It never contains key material, identifiers or file names.
public enum FileV2Error: Error, Equatable, Sendable, CustomStringConvertible {
    /// Descriptor fields, lengths, `kind` or `sz` range.
    case badDescriptor
    /// Magic, `file_id != id`, `stream_len` or `total_chunks` out of range or inconsistent.
    case badHeader
    /// The commitment differs from the one derived from `K`.
    case commitMismatch
    /// The source header differs from the descriptor header.
    case headerMismatch
    /// A chunk has the wrong length, or its GCM open failed.
    case chunkAuth
    /// The padding is not all zero.
    case badPadding
    /// `stream_len != padme(sz)`, the blob length is wrong (including a missing last chunk),
    /// or the transfer ended with chunks still unverified.
    case sizeMismatch
    /// The sender cancelled.
    case cancelled
    /// Sender side, section 12.8 rule 1 and 2: the source changed under the transfer (its size, or the
    /// tag of a chunk that was already encrypted once). Nothing is transmitted; the transfer is cancelled
    /// with a new `K` and `file_id`, and the sender sends `qa_file_cancel`. Wire/telemetry code: `cancelled`.
    case contentChanged
    /// A programmer or caller error that is not a protocol condition (a size out of range, a destination
    /// that already exists, a stale resume state). Not a wire code.
    case invalidArgument(String)

    /// The code of section 12.9, or `invalid_argument` for the local-only case.
    public var code: String {
        switch self {
        case .badDescriptor: return "bad_descriptor"
        case .badHeader: return "bad_header"
        case .commitMismatch: return "commit_mismatch"
        case .headerMismatch: return "header_mismatch"
        case .chunkAuth: return "chunk_auth"
        case .badPadding: return "bad_padding"
        case .sizeMismatch: return "size_mismatch"
        case .cancelled, .contentChanged: return "cancelled"
        case .invalidArgument: return "invalid_argument"
        }
    }

    public var description: String {
        switch self {
        case .invalidArgument(let why): return "FileV2Error(invalid_argument: \(why))"
        case .contentChanged: return "FileV2Error(cancelled: content changed)"
        default: return "FileV2Error(\(code))"
        }
    }
}
