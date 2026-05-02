import Foundation
import CryptoKit

/// File-level XChaCha20-Poly1305 encryption for chat attachments.
/// Direct port of Android's `qaudion-engine/.../crypto/
/// AttachmentEncryption.kt`. Cross-platform parity with the Desktop
/// reference TS impl is the explicit non-negotiable.
///
/// Authoritative spec: `apps/bcrypto-server/docs/WIRE_SPEC.md` §5.1.3.
///
/// **XChaCha20-Poly1305 in pure Swift / CryptoKit**
///
/// CryptoKit ships `ChaChaPoly` (RFC 8439, 12-byte nonce) but no
/// XChaCha20-Poly1305 (24-byte nonce). We synthesise XChaCha20 via the
/// standard construction (draft-irtf-cfrg-xchacha §2.1):
///
///   sub_key (32 B) = HChaCha20(key, nonce[0..16))
///   short_nonce (12 B) = 0x00000000 || nonce[16..24)
///   ciphertext = ChaCha20-Poly1305(sub_key, short_nonce, aad, plaintext)
///
/// HChaCha20 is the standard 20-round ChaCha20 inner permutation
/// returning state[0..4] || state[12..16] (32 bytes).
public enum AttachmentEncryption {

    public static let keyLen = 32
    public static let nonceLen = 24
    public static let shortNonceLen = 12
    public static let uuidLen = 16
    public static let sha256Len = 32

    private static let labelAead = Data("q-audion-attachment-aead-v1".utf8)
    private static let labelNonce = Data("q-audion-attachment-nonce-v1".utf8)

    public struct Meta: Equatable {
        public let attachmentId: Data
        public let senderUuid: Data
        public let mime: String
        public let byteLength: Int

        public init(attachmentId: Data, senderUuid: Data, mime: String, byteLength: Int) throws {
            guard attachmentId.count == uuidLen else {
                throw CryptoError.badArgument("attachmentId must be \(uuidLen) bytes")
            }
            guard senderUuid.count == uuidLen else {
                throw CryptoError.badArgument("senderUuid must be \(uuidLen) bytes")
            }
            guard byteLength >= 0 else {
                throw CryptoError.badArgument("byteLength must be non-negative")
            }
            self.attachmentId = attachmentId
            self.senderUuid = senderUuid
            self.mime = mime
            self.byteLength = byteLength
        }
    }

    public struct Encrypted: Equatable {
        public let ciphertext: Data
        public let sha256Plain: Data
        public let meta: Meta
    }

    public enum CryptoError: Error, Equatable {
        case badArgument(String)
        case sealFailed
        case openFailed
        case lengthMismatch
        case sha256Mismatch
    }

    // MARK: - Key derivation

    /// HKDF-SHA256(messageChainKey, salt=∅, info=label||CBOR{0:attId,1:senderUuid})
    /// Two derivations: one for the AEAD key, one for the 24-byte nonce.
    public static func deriveAttachmentKeys(
        messageChainKey: Data, attachmentId: Data, senderUuid: Data
    ) throws -> (key: Data, nonce: Data) {
        guard messageChainKey.count == keyLen else {
            throw CryptoError.badArgument("messageChainKey must be \(keyLen) bytes")
        }
        guard attachmentId.count == uuidLen else {
            throw CryptoError.badArgument("attachmentId must be \(uuidLen) bytes")
        }
        guard senderUuid.count == uuidLen else {
            throw CryptoError.badArgument("senderUuid must be \(uuidLen) bytes")
        }
        let cborSuffix = cborMapTwoUuids(attachmentId: attachmentId, senderUuid: senderUuid)
        var infoKey = labelAead
        infoKey.append(cborSuffix)
        var infoNonce = labelNonce
        infoNonce.append(cborSuffix)

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: messageChainKey),
            salt: Data(),
            info: infoKey,
            outputByteCount: keyLen
        ).withUnsafeBytes { Data($0) }
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: messageChainKey),
            salt: Data(),
            info: infoNonce,
            outputByteCount: nonceLen
        ).withUnsafeBytes { Data($0) }
        return (key, nonce)
    }

    // MARK: - Encrypt / Decrypt

    public static func encryptAttachment(
        messageChainKey: Data, plaintext: Data, meta: Meta
    ) throws -> Encrypted {
        guard meta.byteLength == plaintext.count else {
            throw CryptoError.lengthMismatch
        }
        let sha = sha256(plaintext)
        let aad = canonicalAad(meta: meta, sha256Plain: sha)
        let (key, nonce) = try deriveAttachmentKeys(
            messageChainKey: messageChainKey,
            attachmentId: meta.attachmentId,
            senderUuid: meta.senderUuid)
        let ct = try xChaCha20Poly1305(
            forEncryption: true, key: key, nonce24: nonce, aad: aad, input: plaintext)
        return Encrypted(ciphertext: ct, sha256Plain: sha, meta: meta)
    }

    public static func decryptAttachment(
        messageChainKey: Data, ciphertext: Data, meta: Meta, expectedSha256Plain: Data
    ) throws -> Data {
        guard expectedSha256Plain.count == sha256Len else {
            throw CryptoError.badArgument("expectedSha256Plain must be \(sha256Len) bytes")
        }
        let aad = canonicalAad(meta: meta, sha256Plain: expectedSha256Plain)
        let (key, nonce) = try deriveAttachmentKeys(
            messageChainKey: messageChainKey,
            attachmentId: meta.attachmentId,
            senderUuid: meta.senderUuid)
        let plaintext = try xChaCha20Poly1305(
            forEncryption: false, key: key, nonce24: nonce, aad: aad, input: ciphertext)
        guard plaintext.count == meta.byteLength else {
            throw CryptoError.lengthMismatch
        }
        let got = sha256(plaintext)
        guard constantTimeEqual(got, expectedSha256Plain) else {
            throw CryptoError.sha256Mismatch
        }
        return plaintext
    }

    // MARK: - XChaCha20-Poly1305 (HChaCha20 + ChaCha20-Poly1305)

    private static func xChaCha20Poly1305(
        forEncryption: Bool, key: Data, nonce24: Data, aad: Data, input: Data
    ) throws -> Data {
        precondition(key.count == keyLen)
        precondition(nonce24.count == nonceLen)
        // sub_key = HChaCha20(key, nonce[0..16))
        let nonce16 = nonce24.prefix(16)
        let subKey = hChaCha20(key: key, nonce16: Data(nonce16))
        // short_nonce = 0x00 0x00 0x00 0x00 || nonce[16..24)
        var shortNonce = Data(count: shortNonceLen)
        let tail = nonce24.suffix(8)
        shortNonce.replaceSubrange(4..<12, with: tail)

        let symKey = SymmetricKey(data: subKey)
        let ccpNonce = try ChaChaPoly.Nonce(data: shortNonce)
        if forEncryption {
            do {
                let sealed = try ChaChaPoly.seal(input, using: symKey, nonce: ccpNonce, authenticating: aad)
                return sealed.ciphertext + sealed.tag
            } catch {
                throw CryptoError.sealFailed
            }
        } else {
            guard input.count >= 16 else { throw CryptoError.openFailed }
            let ct = input.prefix(input.count - 16)
            let tag = input.suffix(16)
            do {
                let box = try ChaChaPoly.SealedBox(nonce: ccpNonce, ciphertext: ct, tag: tag)
                return try ChaChaPoly.open(box, using: symKey, authenticating: aad)
            } catch {
                throw CryptoError.openFailed
            }
        }
    }

    /// HChaCha20 — 20-round ChaCha20 inner permutation extracting
    /// state[0..4] || state[12..16] (32 bytes). Per draft-irtf-cfrg-xchacha §2.2.
    private static func hChaCha20(key: Data, nonce16: Data) -> Data {
        precondition(key.count == 32)
        precondition(nonce16.count == 16)
        var state = [UInt32](repeating: 0, count: 16)
        // sigma = "expand 32-byte k" little-endian uint32
        state[0] = 0x61707865
        state[1] = 0x3320646e
        state[2] = 0x79622d32
        state[3] = 0x6b206574
        for i in 0..<8 { state[4 + i] = leUInt32(key, offset: i * 4) }
        for i in 0..<4 { state[12 + i] = leUInt32(nonce16, offset: i * 4) }

        for _ in 0..<10 {
            qround(&state, 0, 4, 8, 12)
            qround(&state, 1, 5, 9, 13)
            qround(&state, 2, 6, 10, 14)
            qround(&state, 3, 7, 11, 15)
            qround(&state, 0, 5, 10, 15)
            qround(&state, 1, 6, 11, 12)
            qround(&state, 2, 7, 8, 13)
            qround(&state, 3, 4, 9, 14)
        }

        var out = Data(count: 32)
        for i in 0..<4 { putLeUInt32(&out, offset: i * 4, value: state[i]) }
        for i in 0..<4 { putLeUInt32(&out, offset: 16 + i * 4, value: state[12 + i]) }
        return out
    }

    private static func qround(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
    }

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 {
        return (v << n) | (v >> (32 - n))
    }

    private static func leUInt32(_ b: Data, offset: Int) -> UInt32 {
        let base = b.startIndex
        return UInt32(b[base + offset]) |
            (UInt32(b[base + offset + 1]) << 8) |
            (UInt32(b[base + offset + 2]) << 16) |
            (UInt32(b[base + offset + 3]) << 24)
    }

    private static func putLeUInt32(_ b: inout Data, offset: Int, value v: UInt32) {
        let base = b.startIndex
        b[base + offset] = UInt8(v & 0xFF)
        b[base + offset + 1] = UInt8((v >> 8) & 0xFF)
        b[base + offset + 2] = UInt8((v >> 16) & 0xFF)
        b[base + offset + 3] = UInt8((v >> 24) & 0xFF)
    }

    // MARK: - Canonical CBOR helpers

    private static func cborMapTwoUuids(attachmentId: Data, senderUuid: Data) -> Data {
        // 0xa2 = map(2), 0x00 = uint(0), 0x50 = byte-string(16),
        // 0x01 = uint(1), 0x50 = byte-string(16)
        var out = Data(capacity: 1 + 1 + 1 + uuidLen + 1 + 1 + uuidLen)
        out.append(0xA2)
        out.append(0x00)
        out.append(0x50)
        out.append(attachmentId)
        out.append(0x01)
        out.append(0x50)
        out.append(senderUuid)
        return out
    }

    private static func canonicalAad(meta: Meta, sha256Plain: Data) -> Data {
        precondition(sha256Plain.count == sha256Len)
        let mimeBytes = Data(meta.mime.utf8)
        var lenBe = Data(count: 8)
        var n = UInt64(meta.byteLength)
        for i in (0..<8).reversed() {
            lenBe[i] = UInt8(n & 0xFF)
            n >>= 8
        }
        var out = Data()
        out.append(0xA4)
        out.append(cborUintByteString(key: 0, bytes: meta.attachmentId))
        out.append(cborUintTextString(key: 1, bytes: mimeBytes))
        out.append(cborUintByteString(key: 2, bytes: sha256Plain))
        out.append(cborUintByteString(key: 3, bytes: lenBe))
        return out
    }

    private static func cborUintByteString(key: Int, bytes: Data) -> Data {
        return cborUintLengthPrefixed(key: key, bytes: bytes, majorByteString: true)
    }

    private static func cborUintTextString(key: Int, bytes: Data) -> Data {
        return cborUintLengthPrefixed(key: key, bytes: bytes, majorByteString: false)
    }

    private static func cborUintLengthPrefixed(key: Int, bytes: Data, majorByteString: Bool) -> Data {
        precondition((0...23).contains(key), "key out of canonical range: \(key)")
        let keyByte = UInt8(key & 0x1F)
        let shortHdr: UInt8 = majorByteString ? 0x40 : 0x60
        let len1Hdr: UInt8 = majorByteString ? 0x58 : 0x78
        let len2Hdr: UInt8 = majorByteString ? 0x59 : 0x79
        var out = Data()
        if bytes.count <= 23 {
            out.append(keyByte)
            out.append(shortHdr | UInt8(bytes.count))
            out.append(bytes)
        } else if bytes.count <= 0xFF {
            out.append(keyByte)
            out.append(len1Hdr)
            out.append(UInt8(bytes.count))
            out.append(bytes)
        } else {
            out.append(keyByte)
            out.append(len2Hdr)
            out.append(UInt8((bytes.count >> 8) & 0xFF))
            out.append(UInt8(bytes.count & 0xFF))
            out.append(bytes)
        }
        return out
    }

    private static func sha256(_ data: Data) -> Data {
        return Data(SHA256.hash(data: data))
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }
}
