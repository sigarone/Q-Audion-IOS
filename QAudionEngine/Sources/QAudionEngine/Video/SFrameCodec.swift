import Foundation
import CryptoKit

/// Q-Audion SFrame video codec — Swift port of `docs/SFRAME_VIDEO_WIRE_SPEC.md` v1.
///
/// Cross-platform contract: every implementation (Kotlin reference on Android,
/// this Swift port on iOS, the TS port on Desktop) MUST produce byte-identical
/// output for every entry in `sframe-video-kat.json`.
///
/// Wire layout (spec §2):
/// ```
///   cfg(1) [|ext(1)] | KID(0..3) | CTR(1..8) | ciphertext(N) | tag(16)
/// ```
///
/// AEAD = AES-256-GCM, AAD = exactly the header bytes (cfg + ext + KID + CTR).
///
/// Codec-agnostic: the plaintext is the encoded frame payload (HEVC NALUs with
/// start codes preserved, or H.264 fallback). The codec type is NOT stored in
/// the SFrame header — it is negotiated separately via the existing capability
/// frames and stays consistent for the lifetime of a stream.
public enum SFrameCodec {

    // MARK: - Constants (spec §3.1, §3.3)

    public static let nonceSize = 12
    public static let tagSize = 16
    public static let padBlock = 64

    private static let masterLen = 32
    private static let frameKeyLen = 32
    private static let frameSaltLen = 12

    private static let saltV1 = Data("qaudion-sframe-v1".utf8)
    private static let info1to1Master = Data("1to1-master".utf8)
    private static let infoFrameKey = Data("sframe-key".utf8)
    private static let infoFrameSalt = Data("sframe-salt".utf8)

    // MARK: - Types

    /// Simulcast layer label for the `LAYER` field of the extension byte.
    public enum Layer: Int {
        case L = 0
        case M = 1
        case H = 2

        fileprivate static func fromCode(_ c: Int) throws -> Layer {
            switch c {
            case 0: return .L
            case 1: return .M
            case 2: return .H
            default: throw SFrameError.invalidLayer(c)
            }
        }
    }

    public enum SFrameError: Error, CustomStringConvertible {
        case invalidPqcKeyLength(Int)
        case invalidChainKeyLength(Int)
        case emptySenderId
        case emptyCallId
        case invalidKidLength(Int)
        case ctrTopFourBitsReserved(UInt64)
        case invalidLayer(Int)
        case reservedBitSet
        case truncatedHeader(String)
        case extensionReservedBitsNonZero
        case layerCtrMismatch(ext: Int, ctr: Int)
        case paddedPlaintextEmpty
        case invalidPadLength(Int)
        case padLengthExceedsPlaintext(pad: Int, length: Int)
        case wireTooShort

        public var description: String {
            switch self {
            case .invalidPqcKeyLength(let n): return "pqcSessionKey must be 32 bytes, got \(n)"
            case .invalidChainKeyLength(let n): return "chainKey must be 32 bytes, got \(n)"
            case .emptySenderId: return "senderId must not be empty"
            case .emptyCallId: return "callId must not be empty"
            case .invalidKidLength(let n): return "KID must be 0..3 bytes, got \(n)"
            case .ctrTopFourBitsReserved(let c): return "CTR top 4 bits reserved for layer; got 0x\(String(c, radix: 16))"
            case .invalidLayer(let c): return "invalid SFrame layer code \(c)"
            case .reservedBitSet: return "reserved bit R must be 0"
            case .truncatedHeader(let what): return "truncated header (\(what))"
            case .extensionReservedBitsNonZero: return "extension byte reserved bits must be 0"
            case .layerCtrMismatch(let e, let c): return "layer mux/CTR mismatch: ext=\(e), ctr=\(c)"
            case .paddedPlaintextEmpty: return "padded plaintext must be non-empty"
            case .invalidPadLength(let n): return "invalid pad length \(n)"
            case .padLengthExceedsPlaintext(let p, let n): return "pad length \(p) exceeds plaintext length \(n)"
            case .wireTooShort: return "wire too short for header + tag"
            }
        }
    }

    /// Decoded SFrame header.
    public struct Header {
        public let len: Int        // CTR length minus 1, 0..7
        public let hasExt: Bool    // X bit
        public let kidLen: Int     // K, 0..3
        public let kid: Data       // length kidLen; empty for 1:1
        public let ctr: UInt64     // unsigned big-endian, 0..2^60
        public let layer: Layer    // L if no extension byte
        public let padded: Bool
        public let keyFrame: Bool
        public let bytes: Data     // exactly the AAD
    }

    /// Sealed output container. `wire = header + ciphertext + tag` concatenated.
    public struct Sealed {
        public let wire: Data
        public let header: Header
    }

    // MARK: - Master / 1:1 key derivation

    /// Derive the 1:1 SFrame master from the existing 32-byte PQC session key (spec §3.1).
    public static func deriveMaster1to1(_ pqcSessionKey: Data) throws -> Data {
        guard pqcSessionKey.count == 32 else {
            throw SFrameError.invalidPqcKeyLength(pqcSessionKey.count)
        }
        return hkdf(ikm: pqcSessionKey, salt: saltV1, info: info1to1Master, len: masterLen)
    }

    /// Derive the DIRECTIONAL 1:1 SFrame master — the WS-6 (key, nonce)-reuse fix for
    /// LIVE bidirectional video.
    ///
    /// Both call directions share one 32-byte PQC session key, so a non-directional
    /// master would let the two senders pick the same `(frameKey, nonce)` for the same
    /// CTR — a catastrophic AES-GCM nonce reuse. Binding the master to the **sender's**
    /// identity makes the two directions derive disjoint key domains:
    ///   - `senderId` binds the direction (caller vs callee never share a master);
    ///   - `callId` binds per-call freshness (a new call re-keys even with the same peers).
    ///
    /// Construction (spec §3.1 directional variant):
    /// ```
    ///   info   = UTF8("1to1-master-dir|" + senderId + "|" + callId)
    ///   master = HKDF-SHA256(ikm: pqcSessionKey, salt: saltV1, info: info, length: 32)
    /// ```
    /// `saltV1 = "qaudion-sframe-v1"`, `length = masterLen = 32`.
    ///
    /// Byte-exact cross-platform (Android == iOS == Desktop): the Kotlin reference
    /// `SFrameCodec.deriveMaster1to1Directional` produces identical output for the same
    /// inputs, proven by the shared `1to1-dir` vectors in `sframe-video-kat.json`.
    /// Construction cross-checked via nim (security mode) and or (code mode).
    public static func deriveMaster1to1Directional(_ pqcSessionKey: Data, senderId: String, callId: String) throws -> Data {
        guard pqcSessionKey.count == 32 else {
            throw SFrameError.invalidPqcKeyLength(pqcSessionKey.count)
        }
        guard !senderId.isEmpty else { throw SFrameError.emptySenderId }
        guard !callId.isEmpty else { throw SFrameError.emptyCallId }
        let info = Data(("1to1-master-dir|" + senderId + "|" + callId).utf8)
        return hkdf(ikm: pqcSessionKey, salt: saltV1, info: info, len: masterLen)
    }

    /// Derive the per-sender group SFrame master from a `GroupSenderKey` chain key (spec §3.2).
    /// `kid = SHA-256(senderUserId)[0..3]` (handled by the caller — passed into `seal`).
    /// `groupIdHex = lowercase hex(group_id_raw)`, `senderId = UTF-8 user id used by GroupSenderKey`.
    public static func deriveMasterGroup(chainKey: Data, groupIdHex: String, senderId: String) throws -> Data {
        guard chainKey.count == 32 else {
            throw SFrameError.invalidChainKeyLength(chainKey.count)
        }
        let info = Data(("group-master|" + groupIdHex + "|" + senderId).utf8)
        return hkdf(ikm: chainKey, salt: saltV1, info: info, len: masterLen)
    }

    // MARK: - Header encode/decode

    /// Compose a header. CTR length is auto-chosen (1..8 bytes) to be the shortest
    /// big-endian representation of the layer-muxed CTR; padding/keyframe/layer set
    /// the extension byte if any of them are non-default.
    public static func composeHeader(
        ctr: UInt64,
        kid: Data = Data(),
        layer: Layer = .L,
        padded: Bool = false,
        keyFrame: Bool = false
    ) throws -> Header {
        guard kid.count >= 0 && kid.count <= 3 else { throw SFrameError.invalidKidLength(kid.count) }
        // 4 most-significant bits of CTR are reserved for layer mux (spec §5).
        guard (ctr >> 60) == 0 else { throw SFrameError.ctrTopFourBitsReserved(ctr) }

        // Layer mux into CTR: encode (layer << 60) | ctr.
        let muxedCtr = (UInt64(layer.rawValue) << 60) | ctr
        let ctrLen = ctrLenBytes(muxedCtr)
        let lenField = ctrLen - 1
        let needExt = padded || keyFrame || layer != .L

        // R (bit 0) = 0; LEN (bits 1-3); X (bit 4); K (bits 5-7).
        // The diagram in the spec is MSB-first within the byte:
        //   bit 0 = MSB, bit 7 = LSB.
        // So: cfg = (R<<7) | (LEN<<4) | (X<<3) | K.
        let cfg: UInt8 = UInt8(((lenField & 0x7) << 4) |
                               ((needExt ? 1 : 0) << 3) |
                               (kid.count & 0x7))

        var header = Data()
        header.reserveCapacity(1 + (needExt ? 1 : 0) + kid.count + ctrLen)
        header.append(cfg)
        if needExt {
            // ext: LAYER (bits 0-1) << 6 | PAD (bit 2) << 5 | KEY (bit 3) << 4 | reserved
            let ext: UInt8 = UInt8(((layer.rawValue & 0x3) << 6) |
                                   ((padded ? 1 : 0) << 5) |
                                   ((keyFrame ? 1 : 0) << 4))
            header.append(ext)
        }
        if !kid.isEmpty {
            header.append(kid)
        }
        // Big-endian, length ctrLen, of muxedCtr.
        var shift: Int = (ctrLen - 1) * 8
        for _ in 0..<ctrLen {
            header.append(UInt8((muxedCtr >> shift) & 0xFF))
            shift -= 8
        }

        return Header(
            len: lenField,
            hasExt: needExt,
            kidLen: kid.count,
            kid: kid,
            ctr: ctr, // user-facing CTR (no layer mux)
            layer: layer,
            padded: padded,
            keyFrame: keyFrame,
            bytes: header
        )
    }

    /// Decode a header from the start of `buf` at `offset`. Returns the header and
    /// the offset just past it (i.e. where the ciphertext begins).
    public static func decodeHeader(_ buf: Data, offset: Int = 0) throws -> (Header, Int) {
        guard buf.count > offset else { throw SFrameError.truncatedHeader("empty buffer") }
        let cfg = Int(buf[buf.index(buf.startIndex, offsetBy: offset)])
        guard ((cfg >> 7) & 0x1) == 0 else { throw SFrameError.reservedBitSet }
        let lenField = (cfg >> 4) & 0x7
        let hasExt = ((cfg >> 3) & 0x1) == 1
        let kidLen = cfg & 0x7
        guard kidLen >= 0 && kidLen <= 3 else { throw SFrameError.invalidKidLength(kidLen) }

        var off = offset + 1
        let layer: Layer
        let padded: Bool
        let keyFrame: Bool
        if hasExt {
            guard buf.count > off else { throw SFrameError.truncatedHeader("ext") }
            let ext = Int(buf[buf.index(buf.startIndex, offsetBy: off)])
            off += 1
            layer = try Layer.fromCode((ext >> 6) & 0x3)
            padded = ((ext >> 5) & 0x1) == 1
            keyFrame = ((ext >> 4) & 0x1) == 1
            guard (ext & 0x0F) == 0 else { throw SFrameError.extensionReservedBitsNonZero }
        } else {
            layer = .L
            padded = false
            keyFrame = false
        }

        guard buf.count >= off + kidLen else { throw SFrameError.truncatedHeader("KID") }
        let kid = buf.subdata(in: off..<(off + kidLen))
        off += kidLen

        let ctrLen = lenField + 1
        guard buf.count >= off + ctrLen else { throw SFrameError.truncatedHeader("CTR") }
        var muxed: UInt64 = 0
        for i in 0..<ctrLen {
            muxed = (muxed << 8) | UInt64(buf[buf.index(buf.startIndex, offsetBy: off + i)])
        }
        off += ctrLen

        // Strip the layer mux: top 4 bits.
        let layerFromCtr = Int((muxed >> 60) & 0xF)
        let ctr = muxed & 0x0FFF_FFFF_FFFF_FFFF

        // Sanity: when the extension byte is present, layer in CTR must match.
        if hasExt {
            guard layerFromCtr == layer.rawValue else {
                throw SFrameError.layerCtrMismatch(ext: layer.rawValue, ctr: layerFromCtr)
            }
        }

        let headerBytes = buf.subdata(in: offset..<off)
        let h = Header(
            len: lenField,
            hasExt: hasExt,
            kidLen: kidLen,
            kid: kid,
            ctr: ctr,
            layer: layer,
            padded: padded,
            keyFrame: keyFrame,
            bytes: headerBytes
        )
        return (h, off)
    }

    // MARK: - Seal / open

    /// Encrypt a frame.
    ///
    /// - Parameters:
    ///   - master: 32-byte master key from `deriveMaster1to1` or `deriveMasterGroup`.
    ///   - ctr: per-(key, KID) monotonically increasing counter, top 4 bits reserved.
    ///   - plaintext: encoded HEVC NALUs (or H.264 fallback). Will be right-padded
    ///     with zero bytes to a 64-byte boundary if `padded` is true, PKCS#7-style
    ///     with the last byte holding the pad length.
    ///   - kid: 0..3 bytes; empty for 1:1 calls, 3 bytes for groups.
    ///   - layer: simulcast layer (L/M/H).
    ///   - padded: enable 64-byte plaintext padding (Q-Audion deviation §4).
    ///   - keyFrame: set the KEY flag (HEVC IDR / H.264 IDR).
    public static func seal(
        master: Data,
        ctr: UInt64,
        plaintext: Data,
        kid: Data = Data(),
        layer: Layer = .L,
        padded: Bool = false,
        keyFrame: Bool = false
    ) throws -> Data {
        let header = try composeHeader(ctr: ctr, kid: kid, layer: layer, padded: padded, keyFrame: keyFrame)
        let frameKey = hkdf(ikm: master, salt: Data(), info: infoFrameKey, len: frameKeyLen)
        let frameSalt = hkdf(ikm: master, salt: Data(), info: infoFrameSalt, len: frameSaltLen)
        let nonce = nonceFor(frameSalt: frameSalt, ctr: ctr, layer: layer)
        let pt: Data = padded ? padPlaintext(plaintext) : plaintext

        let symKey = SymmetricKey(data: frameKey)
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(pt, using: symKey, nonce: aesNonce, authenticating: header.bytes)

        var out = Data()
        out.reserveCapacity(header.bytes.count + sealed.ciphertext.count + sealed.tag.count)
        out.append(header.bytes)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Convenience overload returning the structured `Sealed` container.
    public static func sealStructured(
        master: Data,
        ctr: UInt64,
        plaintext: Data,
        kid: Data = Data(),
        layer: Layer = .L,
        padded: Bool = false,
        keyFrame: Bool = false
    ) throws -> Sealed {
        let header = try composeHeader(ctr: ctr, kid: kid, layer: layer, padded: padded, keyFrame: keyFrame)
        let frameKey = hkdf(ikm: master, salt: Data(), info: infoFrameKey, len: frameKeyLen)
        let frameSalt = hkdf(ikm: master, salt: Data(), info: infoFrameSalt, len: frameSaltLen)
        let nonce = nonceFor(frameSalt: frameSalt, ctr: ctr, layer: layer)
        let pt: Data = padded ? padPlaintext(plaintext) : plaintext
        let symKey = SymmetricKey(data: frameKey)
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(pt, using: symKey, nonce: aesNonce, authenticating: header.bytes)
        var wire = Data()
        wire.reserveCapacity(header.bytes.count + sealed.ciphertext.count + sealed.tag.count)
        wire.append(header.bytes)
        wire.append(sealed.ciphertext)
        wire.append(sealed.tag)
        return Sealed(wire: wire, header: header)
    }

    /// Decrypt a frame. Returns the plaintext (with padding stripped if `header.padded` was true).
    /// Throws `CryptoKitError.authenticationFailure` on tag mismatch.
    public static func open(master: Data, wire: Data) throws -> Data {
        guard wire.count >= 1 + tagSize else { throw SFrameError.wireTooShort }
        let (header, headerEnd) = try decodeHeader(wire, offset: 0)
        let frameKey = hkdf(ikm: master, salt: Data(), info: infoFrameKey, len: frameKeyLen)
        let frameSalt = hkdf(ikm: master, salt: Data(), info: infoFrameSalt, len: frameSaltLen)
        let nonce = nonceFor(frameSalt: frameSalt, ctr: header.ctr, layer: header.layer)

        let tagStart = wire.count - tagSize
        guard tagStart >= headerEnd else { throw SFrameError.wireTooShort }
        let ct = wire.subdata(in: headerEnd..<tagStart)
        let tag = wire.subdata(in: tagStart..<wire.count)

        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ct,
            tag: tag
        )
        let pt = try AES.GCM.open(box, using: SymmetricKey(data: frameKey), authenticating: header.bytes)
        return header.padded ? try stripPadding(pt) : pt
    }

    // MARK: - internals

    private static func ctrLenBytes(_ muxedCtr: UInt64) -> Int {
        if muxedCtr == 0 { return 1 }
        // Mirror the Kotlin loop: number of bytes needed unsigned, MSB-first.
        var n = 8
        while n > 1 && ((muxedCtr >> ((n - 1) * 8)) & 0xFF) == 0 { n -= 1 }
        return n
    }

    private static func nonceFor(frameSalt: Data, ctr: UInt64, layer: Layer) -> Data {
        // Spec §3.3: 12-byte salt XOR (zero-extended big-endian (layer<<60)|ctr).
        let muxed = (UInt64(layer.rawValue) << 60) | ctr
        var nonce = frameSalt
        // Place muxed in the trailing 8 bytes of the 12-byte nonce (indices 4..11).
        var shift: Int = 56
        for i in 4..<12 {
            let b = UInt8((muxed >> shift) & 0xFF)
            nonce[nonce.index(nonce.startIndex, offsetBy: i)] ^= b
            shift -= 8
        }
        return nonce
    }

    private static func padPlaintext(_ pt: Data) -> Data {
        let mod = pt.count % padBlock
        let pad = padBlock - mod
        let padLen = (pad == 0) ? padBlock : pad
        var out = Data(count: pt.count + padLen)
        out.replaceSubrange(0..<pt.count, with: pt)
        // PKCS#7-style: last byte = padLen (0 means 64). Since padLen ∈ [1, 64], 64 wraps to 0.
        out[out.count - 1] = UInt8(padLen & 0xFF)
        return out
    }

    private static func stripPadding(_ pt: Data) throws -> Data {
        guard !pt.isEmpty else { throw SFrameError.paddedPlaintextEmpty }
        let last = Int(pt[pt.index(pt.startIndex, offsetBy: pt.count - 1)])
        let padLen = (last == 0) ? padBlock : last
        guard padLen >= 1 && padLen <= padBlock else { throw SFrameError.invalidPadLength(padLen) }
        guard pt.count >= padLen else { throw SFrameError.padLengthExceedsPlaintext(pad: padLen, length: pt.count) }
        return pt.subdata(in: 0..<(pt.count - padLen))
    }

    private static func hkdf(ikm: Data, salt: Data, info: Data, len: Int) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: len
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
