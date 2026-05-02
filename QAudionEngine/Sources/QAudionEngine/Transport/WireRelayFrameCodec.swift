import Foundation

/// Android-compatible wire codec for the BcryptoWsRelay path
/// (audio_frame / video_frame).
///
/// This codec is byte-for-byte compatible with
/// `feature/feature-call/.../domain/FrameRelayTransport.kt`
/// (DefaultFrameRelayTransport.send / sendVideo / decode).
///
/// Wire envelope (AUDIO):
///     u8  0x01             // mux byte
///     u8[12] nonce
///     u64 seq              // big-endian
///     u16 ct_len           // big-endian
///     u8[ct_len] ct        // ciphertext || tag (concatenated)
///
/// Wire envelope (VIDEO):
///     u8  0x02             // mux byte
///     u16 fragIdx          // big-endian
///     u16 totalFrags       // big-endian
///     u8  isKey            // 0 or 1
///     u8[12] nonce
///     u64 seq              // big-endian
///     u16 ct_len           // big-endian
///     u8[ct_len] ct        // ciphertext || tag (concatenated)
///
/// Notes on cross-platform mapping:
/// - iOS [EncryptedFrame] stores `payload` and `tag` separately, while the
///   Kotlin EncryptedFrame keeps them concatenated as `ciphertext`. Encode
///   appends `payload || tag`; decode splits the trailing 16 bytes back into
///   the iOS-side `tag`.
/// - The Android wire has no timestamp / version / flags fields. On decode
///   we synthesize sane defaults (timestamp = 0, version = 0x01, flags = 0)
///   so iOS upstream consumers (JitterBuffer, AdaptivePadding) keep working.
/// - The Android wire seq is u64; iOS [EncryptedFrame] keeps a UInt32. When
///   encoding we zero-extend; when decoding we truncate to the low 32 bits.
///   Fine for any single-call sequence (a 50 ms RTP-like cadence overflows
///   2^32 at ~6.8 years).
public enum WireRelayFrameCodec {

    public static let muxAudio: UInt8 = 0x01
    public static let muxVideo: UInt8 = 0x02

    public static let nonceSize = 12
    public static let tagSize = 16
    public static let audioHeaderSize = 1 + nonceSize + 8 + 2          // 23
    public static let videoHeaderSize = 1 + 2 + 2 + 1 + nonceSize + 8 + 2 // 28

    public enum Kind {
        case audio
        case video(fragIdx: UInt16, totalFrags: UInt16, isKey: Bool)
    }

    public struct DecodedFrame {
        public let kind: Kind
        public let frame: EncryptedFrame
        public init(kind: Kind, frame: EncryptedFrame) {
            self.kind = kind
            self.frame = frame
        }
    }

    public enum CodecError: Error, Equatable {
        case empty
        case truncated(expected: Int, got: Int)
        case ciphertextTooSmall(Int)            // < 16 → no room for AEAD tag
        case unknownMux(UInt8)
        case payloadTooLarge(Int)
    }

    // MARK: - Audio

    /// Encode an iOS [EncryptedFrame] as an Android-compatible audio_frame
    /// payload. The deepfake score is dropped (not on the wire) — call sites
    /// that need it should send a side-channel WS message.
    public static func encodeAudio(_ frame: EncryptedFrame) -> Data {
        let ct = frame.payload + frame.tag
        let ctLen = ct.count
        var out = Data(capacity: audioHeaderSize + ctLen)
        out.append(muxAudio)
        out.append(frame.nonce)
        appendUInt64BigEndian(&out, UInt64(frame.sequenceNumber))
        appendUInt16BigEndian(&out, UInt16(truncatingIfNeeded: ctLen))
        out.append(ct)
        return out
    }

    // MARK: - Video

    /// Encode an iOS [EncryptedFrame] as an Android-compatible video_frame
    /// payload (per-fragment).
    public static func encodeVideo(
        _ frame: EncryptedFrame,
        fragIdx: UInt16,
        totalFrags: UInt16,
        isKey: Bool
    ) -> Data {
        let ct = frame.payload + frame.tag
        let ctLen = ct.count
        var out = Data(capacity: videoHeaderSize + ctLen)
        out.append(muxVideo)
        appendUInt16BigEndian(&out, fragIdx)
        appendUInt16BigEndian(&out, totalFrags)
        out.append(isKey ? 1 : 0)
        out.append(frame.nonce)
        appendUInt64BigEndian(&out, UInt64(frame.sequenceNumber))
        appendUInt16BigEndian(&out, UInt16(truncatingIfNeeded: ctLen))
        out.append(ct)
        return out
    }

    // MARK: - Decode

    /// Best-effort decode of an inbound payload. The mux byte (0x01/0x02)
    /// disambiguates audio vs video. Unknown / missing mux byte (legacy
    /// pre-mux Android builds) falls back to AUDIO.
    public static func decode(_ data: Data) throws -> DecodedFrame {
        guard !data.isEmpty else { throw CodecError.empty }
        let head = data[data.startIndex]
        switch head {
        case muxAudio:
            return try decodeAudio(data, headerSize: 1, kind: .audio)
        case muxVideo:
            return try decodeVideo(data)
        default:
            // Legacy untagged audio (pre-mux Android builds). Treat the whole
            // payload as audio with no leading byte.
            return try decodeAudio(data, headerSize: 0, kind: .audio)
        }
    }

    private static func decodeVideo(_ data: Data) throws -> DecodedFrame {
        guard data.count >= videoHeaderSize else {
            throw CodecError.truncated(expected: videoHeaderSize, got: data.count)
        }
        let base = data.startIndex
        var off = base + 1 // skip mux byte
        let fragIdx = readUInt16BigEndian(data, offset: off); off += 2
        let totalFrags = readUInt16BigEndian(data, offset: off); off += 2
        let isKey = data[off] != 0; off += 1
        return try parseTail(
            data,
            tailStart: off,
            kind: .video(fragIdx: fragIdx, totalFrags: totalFrags, isKey: isKey)
        )
    }

    private static func decodeAudio(_ data: Data, headerSize: Int, kind: Kind) throws -> DecodedFrame {
        let base = data.startIndex
        let tailStart = base + headerSize
        return try parseTail(data, tailStart: tailStart, kind: kind)
    }

    /// Parse the common nonce|seq|ctLen|ct trailer. Caller has already moved
    /// past the per-kind header (mux byte for audio, full 6-byte preamble
    /// for video).
    private static func parseTail(_ data: Data, tailStart: Int, kind: Kind) throws -> DecodedFrame {
        let need = nonceSize + 8 + 2
        guard data.endIndex - tailStart >= need else {
            throw CodecError.truncated(expected: need, got: data.endIndex - tailStart)
        }
        var off = tailStart
        let nonce = data.subdata(in: off..<(off + nonceSize)); off += nonceSize
        let seq = readUInt64BigEndian(data, offset: off); off += 8
        let ctLen = Int(readUInt16BigEndian(data, offset: off)); off += 2

        guard ctLen <= TransportConstants.maxPayloadSize + tagSize else {
            throw CodecError.payloadTooLarge(ctLen)
        }
        guard data.endIndex - off >= ctLen else {
            throw CodecError.truncated(expected: ctLen, got: data.endIndex - off)
        }
        guard ctLen >= tagSize else {
            throw CodecError.ciphertextTooSmall(ctLen)
        }
        let ct = data.subdata(in: off..<(off + ctLen))
        let payload = ct.prefix(ctLen - tagSize)
        let tag = ct.suffix(tagSize)

        let frame = EncryptedFrame(
            version: TransportConstants.frameVersion,
            flags: 0x00,
            sequenceNumber: UInt32(truncatingIfNeeded: seq),
            timestamp: 0,
            nonce: Data(nonce),
            payload: Data(payload),
            tag: Data(tag),
            deepfakeScore: nil
        )
        return DecodedFrame(kind: kind, frame: frame)
    }

    // MARK: - BE helpers

    private static func appendUInt16BigEndian(_ data: inout Data, _ value: UInt16) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 2))
    }
    private static func appendUInt64BigEndian(_ data: inout Data, _ value: UInt64) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 8))
    }
    private static func readUInt16BigEndian(_ data: Data, offset: Int) -> UInt16 {
        var v: UInt16 = 0
        for i in 0..<2 { v = (v << 8) | UInt16(data[offset + i]) }
        return v
    }
    private static func readUInt64BigEndian(_ data: Data, offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[offset + i]) }
        return v
    }
}
