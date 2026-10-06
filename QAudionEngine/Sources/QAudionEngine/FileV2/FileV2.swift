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
///  - `FileV2JSON` (internal): the strict JSON profile, integers and canonical base64 (12.7.2, 12.7.3), on bytes
///  - `FileV2Descriptor`: descriptor parsing and validation (12.7.2 to 12.7.5, 12.9 steps 1 and 2)
///  - `FileV2Message`: recognition by byte prefix and the control messages `qa_file_src` and `qa_file_cancel`
///    (12.7.1, 12.7.6)
///  - `FileV2DescriptorBuilder`: the canonical builders of the descriptor and of the control messages (12.7.1)
///  - `FileV2Encryptor`: the sender, per chunk and file to file (12.5, 12.8), owner of the nonce ledger
///    (`FileV2TagLedger`, the anti-nonce-reuse rule of 12.8)
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
    /// The only version of a file message this format defines (`qa_file`, `qa_file_src`, `qa_file_cancel`).
    public static let descriptorVersion: Int64 = 2
    /// Most nested containers (objects and arrays) a descriptor may hold, the top-level object being depth 1
    /// (section 12.7.2 rule 4): `th` holding `src` holding `tok`, or `th`, `m`, `wave`.
    public static let maxDescriptorDepth: Int = 4
    /// The largest integer of the format, 2^53 - 1 (not exact beyond it in a JavaScript number; section 12.7.3).
    public static let maxJSONInteger: Int64 = (1 << 53) - 1
    /// Smallest and largest `ex` (`-1` view once, `0` no timer, `N` seconds): section 12.7.4.
    public static let minEx: Int64 = -1
    public static let maxEx: Int64 = (1 << 31) - 1
    /// Largest `src.tok.max`: the server keeps it in an int32.
    public static let maxTokenMax: Int64 = (1 << 31) - 1
    /// Length of `src.tok.v`: lowercase hex of an HMAC-SHA-256.
    public static let tokenValueHexLength: Int = 64
    /// Length of `src.obj`: a lowercase hyphenated UUID in the server's format.
    public static let objectIDLength: Int = 36

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
    /// A recognised file message (`qa_file`, `qa_file_src`, `qa_file_cancel`) whose version is a plain integer
    /// other than 2 (section 12.7.1). The rest of the body is not examined.
    case unsupportedVersion
    /// Sender side, section 12.8 rule 1 and 2: the source changed under the transfer (its size, or the
    /// tag of a chunk that was already encrypted once). Nothing is transmitted; the transfer is cancelled
    /// with a new `K` and `file_id`, and the sender sends `qa_file_cancel`. Wire/telemetry code: `cancelled`.
    case contentChanged
    /// The sealer or the receiver was used after `close()`: its key material is gone, so it neither seals nor
    /// opens anything any more. Local condition, not a wire code.
    case closed
    /// A programmer or caller error that is not a protocol condition (a size out of range, a destination
    /// that already exists, a stale resume state). Not a wire code.
    case invalidArgument(String)

    /// The code of section 12.9, or `invalid_argument` / `closed` for the local-only cases.
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
        case .unsupportedVersion: return "unsupported_version"
        case .closed: return "closed"
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
