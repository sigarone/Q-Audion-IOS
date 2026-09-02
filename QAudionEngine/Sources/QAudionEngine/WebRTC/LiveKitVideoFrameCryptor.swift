import Foundation
import CryptoKit

/// LiveKitVideoFrameCryptor — Swift port of
/// `qaudion-desktop/src/shared/sframe/LiveKitFrameCryptor.ts`, which is
/// itself a byte-exact port of libwebrtc/webrtc-sdk's native
/// `FrameCryptorTransformer` AES-GCM wire format.
///
/// W539 — interop fix for the iOS ↔ Desktop ↔ Android video E2EE path.
/// Before this commit, iOS encrypted/decrypted call video at the codec
/// layer using the Q-Audion custom `SFrameCodec` envelope, while Desktop
/// and Android used libwebrtc's native FrameCryptor envelope. The two
/// formats are mutually incompatible, so every Desktop→iOS video frame
/// failed to decrypt and was silently dropped (black screen).
///
/// This cryptor produces / consumes the EXACT wire layout the other
/// platforms emit, so once it is installed in place of the SFrame
/// sealer on iOS, cross-platform video calls render correctly.
///
/// **Wire layout — non-H264/H265 (VP8 / VP9 / AV1 / opus):**
/// ```
///   frame_header ‖ ciphertext ‖ tag(16) ‖ iv(12) ‖ trailer(2)
/// ```
///   - `frame_header`: the first `unencryptedBytes(...)` bytes of the
///     encoded frame. Kept in clear AND fed to AES-GCM as the AAD.
///   - `ciphertext + tag`: AES-128-GCM of the remaining payload bytes.
///   - `iv`: 12-byte nonce, carried on the wire (receiver reads it back).
///   - `trailer`: `[ ivLength(=12), keyIndex(=0) ]`.
///
/// **H264 / H265 deviation:** the native cryptor wraps the
/// `ciphertext ‖ iv ‖ trailer` tail through `H264::WriteRbsp` (Annex-B
/// emulation-prevention byte stuffing) so the encrypted blob can never
/// contain a start-code the native RTP packetizer would choke on.
/// Decrypt undoes it via `H264::ParseRbsp`. Both implemented below.
///
/// **Key derivation (matches native `DeriveHkdfSha256FromSecret`):**
/// ```
///   HKDF-SHA256(
///     ikm  = 32-byte PQC session key,
///     salt = empty (ratchet_salt; Q-Audion passes 0-length on all platforms),
///     info = 128 bytes of 0x00,
///     L    = 16) → AES-128-GCM key
/// ```
///
/// **keyIndex** is always `0` (Android calls `setSharedKey(0, key)` and
/// `setKeyIndex(0)`; Desktop hardcodes `KEY_INDEX = 0`).
///
/// **Rekey transparency:** the AES key is HKDF-derived on EVERY seal/open
/// call. When the audio-driven rekey scheduler rotates the underlying
/// PQC session key, the next outbound video frame automatically picks up
/// the new key without any controller-side restart. Cost: 1 HKDF per
/// frame (~2 µs on A14+, negligible at 30 fps).
public final class LiveKitVideoFrameCryptor: @unchecked Sendable {

    /// Codec families that change `unencrypted_bytes` / RBSP handling.
    public enum FrameCodec: String {
        case vp8
        case vp9
        case av1
        case h264
        case h265
        case opus
    }

    private static let ivLength: Int = 12
    private static let tagLength: Int = 16
    private static let trailerLength: Int = 2
    /// Android: keyProvider.setSharedKey(0, …) + frameCryptor.setKeyIndex(0).
    private static let keyIndex: UInt8 = 0
    /// Native: `auto info = std::vector<uint8_t>(128, 0);`
    private static let hkdfInfo: Data = Data(count: 128)
    /// Native: ratchet_salt; Q-Audion passes an empty salt on all platforms.
    private static let hkdfSalt: Data = Data()
    /// Native (AES-256 patch) `DeriveKeys(…, 256)` → 32-byte AES-256-GCM key,
    /// byte-matching Android's AES-256-patched native FrameCryptor (WS-7).
    private static let derivedKeyBytes: Int = 32

    private let keyProvider: () -> Data
    private let ivGen = FrameCryptorIvGenerator()

    /// - Parameter keyProvider: returns the current 32-byte PQC session
    ///   key. Called on every seal/open so mid-call rekeys are picked
    ///   up transparently.
    public init(keyProvider: @escaping () -> Data) {
        self.keyProvider = keyProvider
    }

    // MARK: - Key derivation

    /// Derive the AES-256-GCM frame key from the 32-byte PQC session key,
    /// byte-identical to native `DeriveHkdfSha256FromSecret`.
    public static func deriveFrameCryptorKey(pqcSessionKey: Data) -> Data {
        precondition(pqcSessionKey.count == 32, "pqcSessionKey must be 32 bytes, got \(pqcSessionKey.count)")
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pqcSessionKey),
            salt: hkdfSalt,
            info: hkdfInfo,
            outputByteCount: derivedKeyBytes
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// W-B1CRASHFRAME (2026-09-02) — was `precondition(pqc.count == 32, ...)`,
    /// a hard process trap reachable on every seal/open call (i.e. every
    /// video frame) if `keyProvider()` ever returns a malformed key (stale
    /// rekey race, earbud placeholder, peer downgrade). `seal`/`open` are
    /// already `throws` and every call site already wraps them in `try?` /
    /// `do-catch` with log+drop fallback (`SFrameVideoCodecDecorator.swift`)
    /// — so turning this into a throw reaches an existing safety net instead
    /// of taking down the whole call. `deriveFrameCryptorKey`'s own
    /// precondition below is intentionally left as-is: it is now only ever
    /// reached with a key already validated here, so it is unreachable
    /// dead-code defense, not a live trap.
    private func frameKey() throws -> SymmetricKey {
        let pqc = keyProvider()
        guard pqc.count == 32 else {
            throw CryptorError.badKeyLength(got: pqc.count, expected: 32)
        }
        let raw = Self.deriveFrameCryptorKey(pqcSessionKey: pqc)
        return SymmetricKey(data: raw)
    }

    // MARK: - unencrypted_bytes (native get_unencrypted_bytes)

    /// Compute the clear-header byte count exactly as native
    /// `get_unencrypted_bytes`.
    public static func unencryptedBytes(codec: FrameCodec, isKeyFrame: Bool, data: Data) -> Int {
        switch codec {
        case .opus:
            return 1
        case .vp8:
            return isKeyFrame ? 10 : 3
        case .vp9, .av1:
            return 0
        case .h264:
            let off = firstVclPayloadStart(data: data, h265: false)
            return off >= 0 ? off + 2 : 0
        case .h265:
            let off = firstVclPayloadStart(data: data, h265: true)
            return off >= 0 ? off + 2 : 0
        }
    }

    /// Annex-B NALU scan: returns the byte offset where the FIRST VCL
    /// slice/IDR NALU *payload* starts (just past its start code),
    /// mirroring `webrtc::H264::FindNaluIndices` +
    /// `kIdr | kSlice → payload_start_offset` selection. Returns -1 if
    /// no VCL NALU found.
    private static func firstVclPayloadStart(data: Data, h265: Bool) -> Int {
        let n = data.count
        var i = 0
        while i + 3 <= n {
            var scLen = 0
            if i + 3 <= n
                && data[i] == 0
                && data[i + 1] == 0
                && data[i + 2] == 1 {
                scLen = 3
            } else if i + 4 <= n
                && data[i] == 0
                && data[i + 1] == 0
                && data[i + 2] == 0
                && data[i + 3] == 1 {
                scLen = 4
            }
            if scLen == 0 {
                i += 1
                continue
            }
            let payloadStart = i + scLen
            if payloadStart >= n { break }
            let b0 = data[payloadStart]
            if h265 {
                // H265 NALU type = (byte0 >> 1) & 0x3F. VCL: 0..31.
                let naluType = (b0 >> 1) & 0x3f
                if naluType <= 31 { return payloadStart }
            } else {
                // H264 NALU type = byte0 & 0x1F. kSlice=1, kIdr=5.
                let naluType = b0 & 0x1f
                if naluType == 1 || naluType == 5 { return payloadStart }
            }
            i = payloadStart
        }
        return -1
    }

    // MARK: - H264/H265 RBSP emulation-prevention

    /// Insert 0x03 after every `00 00` run followed by a byte ≤ 0x03.
    private static func writeRbsp(_ input: Data) -> Data {
        var out = Data()
        out.reserveCapacity(input.count + input.count / 32) // small overestimate
        var zeroRun = 0
        for b in input {
            if zeroRun >= 2 && b <= 0x03 {
                out.append(0x03)
                zeroRun = 0
            }
            out.append(b)
            zeroRun = b == 0 ? zeroRun + 1 : 0
        }
        return out
    }

    /// True iff the buffer contains a `00 00 03` emulation-prevention seq.
    private static func needsRbspUnescaping(_ input: Data) -> Bool {
        if input.count < 3 { return false }
        var i = 0
        let n = input.count
        while i + 2 < n {
            if input[i] == 0 && input[i + 1] == 0 && input[i + 2] == 0x03 {
                return true
            }
            i += 1
        }
        return false
    }

    /// Remove 0x03 in every `00 00 03` sequence (inverse of writeRbsp).
    private static func parseRbsp(_ input: Data) -> Data {
        var out = Data()
        out.reserveCapacity(input.count)
        var i = 0
        let n = input.count
        while i < n {
            if i + 2 < n
                && input[i] == 0
                && input[i + 1] == 0
                && input[i + 2] == 0x03 {
                out.append(0)
                out.append(0)
                i += 3 // skip the 0x03
            } else {
                out.append(input[i])
                i += 1
            }
        }
        return out
    }

    private static func isAnnexBCodec(_ codec: FrameCodec) -> Bool {
        return codec == .h264 || codec == .h265
    }

    // MARK: - Seal / Open

    /// Encode an encoded-frame buffer into the FrameCryptor wire format.
    ///
    /// - Parameters:
    ///   - data: the encoded frame bytes from the video encoder.
    ///   - codec: negotiated codec for this transceiver.
    ///   - isKeyFrame: `true` for keyframes (changes VP8/H264/H265 header parsing).
    ///   - ssrc: synchronization source for IV uniqueness. Codec-decorator
    ///     callers don't have SSRC available; pass `0`. The IV is carried
    ///     on the wire so the receiver doesn't need to reconstruct it.
    ///   - rtpTimestamp: from `RTCEncodedImage.timeStamp`.
    public func seal(
        data: Data,
        codec: FrameCodec,
        isKeyFrame: Bool,
        ssrc: UInt32 = 0,
        rtpTimestamp: UInt32 = 0
    ) throws -> Data {
        let headerLen = Self.unencryptedBytes(codec: codec, isKeyFrame: isKeyFrame, data: data)
        guard headerLen <= data.count else {
            throw CryptorError.headerTooLarge(headerLen: headerLen, frameLen: data.count)
        }
        let header = data.prefix(headerLen)
        let payload = data.suffix(from: data.startIndex.advanced(by: headerLen))
        let iv = ivGen.make(ssrc: ssrc, rtpTimestamp: rtpTimestamp)
        let key = try frameKey()

        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(
            payload,
            using: key,
            nonce: nonce,
            authenticating: header
        )
        // sealed.ciphertext + sealed.tag matches BoringSSL EVP_AEAD_CTX_seal
        // output (ciphertext followed by 16-byte tag). Concatenate them.
        var ct = Data()
        ct.append(sealed.ciphertext)
        ct.append(sealed.tag)

        var trailer = Data(count: Self.trailerLength)
        trailer[0] = UInt8(Self.ivLength)
        trailer[1] = Self.keyIndex

        var tail = Data()
        tail.reserveCapacity(ct.count + iv.count + trailer.count)
        tail.append(ct)
        tail.append(iv)
        tail.append(trailer)

        let body = Self.isAnnexBCodec(codec) ? Self.writeRbsp(tail) : tail

        var out = Data()
        out.reserveCapacity(header.count + body.count)
        out.append(contentsOf: header)
        out.append(body)
        return out
    }

    /// Decode a FrameCryptor-wire buffer back to the plaintext frame.
    public func open(
        data: Data,
        codec: FrameCodec,
        isKeyFrame: Bool
    ) throws -> Data {
        let headerLen = Self.unencryptedBytes(codec: codec, isKeyFrame: isKeyFrame, data: data)
        let minBody = Self.tagLength + Self.ivLength + Self.trailerLength
        guard data.count >= headerLen + minBody else {
            throw CryptorError.frameTooShort(frameLen: data.count, headerLen: headerLen, minBody: minBody)
        }
        let header = data.prefix(headerLen)
        var body = Data(data.suffix(from: data.startIndex.advanced(by: headerLen)))
        if Self.isAnnexBCodec(codec) && Self.needsRbspUnescaping(body) {
            body = Self.parseRbsp(body)
        }
        guard body.count >= minBody else {
            throw CryptorError.frameTooShort(frameLen: data.count, headerLen: headerLen, minBody: minBody)
        }
        // Tail layout: [ ciphertext ‖ tag(16) ] iv(12) trailer(2)
        let trailerStart = body.count - Self.trailerLength
        let ivStart = trailerStart - Self.ivLength
        let trailer = body.subdata(in: trailerStart..<body.count)
        let ivLengthOnWire = Int(trailer[0])
        guard ivLengthOnWire == Self.ivLength else {
            throw CryptorError.badIvLength(got: ivLengthOnWire, expected: Self.ivLength)
        }
        let iv = body.subdata(in: ivStart..<trailerStart)
        let ctAndTag = body.subdata(in: 0..<ivStart)
        guard ctAndTag.count >= Self.tagLength else {
            throw CryptorError.frameTooShort(frameLen: data.count, headerLen: headerLen, minBody: minBody)
        }
        let tagStart = ctAndTag.count - Self.tagLength
        let ciphertext = ctAndTag.subdata(in: 0..<tagStart)
        let tag = ctAndTag.subdata(in: tagStart..<ctAndTag.count)

        let key = try frameKey()
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: header)

        var out = Data()
        out.reserveCapacity(header.count + plaintext.count)
        out.append(contentsOf: header)
        out.append(plaintext)
        return out
    }

    public enum CryptorError: Error, CustomStringConvertible {
        case headerTooLarge(headerLen: Int, frameLen: Int)
        case frameTooShort(frameLen: Int, headerLen: Int, minBody: Int)
        case badIvLength(got: Int, expected: Int)
        /// W-B1CRASHFRAME (2026-09-02) — keyProvider() returned a
        /// malformed (non-32-byte) key on this frame; was a `precondition`
        /// trap, now a droppable error.
        case badKeyLength(got: Int, expected: Int)

        public var description: String {
            switch self {
            case .headerTooLarge(let h, let f):
                return "LiveKitFrameCryptor: clear-header (\(h)B) exceeds frame size (\(f)B)"
            case .frameTooShort(let f, let h, let m):
                return "LiveKitFrameCryptor: frame too short (\(f)B, header=\(h)B, need ≥ header+\(m)B body)"
            case .badIvLength(let got, let expected):
                return "LiveKitFrameCryptor: bad ivLength \(got) on wire (expected \(expected))"
            case .badKeyLength(let got, let expected):
                return "LiveKitFrameCryptor: keyProvider returned key of size \(got)B (expected \(expected)B)"
            }
        }
    }
}

// MARK: - IV generator (native FrameCryptorTransformer::makeIv)

/// Per-SSRC IV generator. Mirrors native `makeIv`:
///   ssrc(4 BE) ‖ timestamp(4 BE) ‖ (timestamp − sendCount%0xFFFF)(4 BE)
/// The receiver reads the IV off the wire, so byte-exact parity with the
/// native algorithm is not strictly required for interop — but matching
/// it preserves the same per-(key, ssrc) nonce-uniqueness guarantee and
/// avoids GCM nonce reuse across the two send directions (distinct SSRCs).
final class FrameCryptorIvGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var sendCounts: [UInt32: UInt64] = [:]

    func make(ssrc: UInt32, rtpTimestamp: UInt32) -> Data {
        lock.lock()
        let sendCount = sendCounts[ssrc] ?? 0
        sendCounts[ssrc] = sendCount + 1
        lock.unlock()
        var iv = Data(count: 12)
        let ssrcBE = ssrc.bigEndian
        let tsBE = rtpTimestamp.bigEndian
        // (timestamp - sendCount%0xFFFF), mod 2^32, big-endian
        let tail = (rtpTimestamp &- UInt32(sendCount % 0xFFFF)).bigEndian
        iv.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.storeBytes(of: ssrcBE, as: UInt32.self)
            base.advanced(by: 4).storeBytes(of: tsBE, as: UInt32.self)
            base.advanced(by: 8).storeBytes(of: tail, as: UInt32.self)
        }
        return iv
    }
}
