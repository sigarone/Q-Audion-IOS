import Foundation
import CryptoKit

/// SEC-WIREUNIFY (2026-08-03) — XChaCha20-Poly1305 chunk seal/open for the
/// cross-platform file-attachment pipeline (`qa_fa_announce:1`).
///
/// Byte-exact port of Android `qaudion-engine/.../file/FileAttachmentCipher.kt`,
/// verified against that file's own KAT-vector generator
/// (`FileAttachmentCrossPlatformKatGeneratorTest.kt`) — see
/// `FileAttachmentCipherKatTests.swift`. A DEDICATED AAD prefix
/// (`qaudion-fa-v1|`) keeps this pipeline KAT-isolated from both the
/// voice-note cipher and the older `AttachmentEncryption` (`qa_ctl:1`)
/// pipeline — a ciphertext sealed for one can never verify against another.
///
/// # Algorithm (must match Android exactly)
///
///   nonce_24 = HKDF-SHA256(
///       ikm  = contentKey,          // 32 B per-file random
///       salt = fileId || senderId,  // 32 B
///       info = "qaudion-fa-v1-nonce|" || u32_BE(chunkIdx),
///       L    = 24,
///   )
///   aad = "qaudion-fa-v1|"           // 14 B prefix
///       || fileId                    // 16 B
///       || senderId                  // 16 B
///       || u32_BE(chunkIdx)          // 4 B
///       || u32_BE(totalChunks)       // 4 B  → 54 B AAD total
///   ciphertext = XChaCha20-Poly1305(contentKey, nonce, aad, plaintext)
///
/// XChaCha20-Poly1305 construction (draft-irtf-cfrg-xchacha §2.2) mirrors
/// `AttachmentEncryption.swift`'s proven HChaCha20 + CryptoKit ChaChaPoly
/// implementation — duplicated here (not shared) for the same KAT-isolation
/// reason Android's own file header gives for duplicating it from
/// `VoiceNoteCipher`.
public enum FileAttachmentCipher {

    public static let contentKeyLen = 32
    public static let idLen = 16
    public static let nonceLen = 24
    public static let shortNonceLen = 12
    public static let poly1305TagLen = 16
    public static let aadLen = 54

    private static let aadPrefix = Data("qaudion-fa-v1|".utf8)
    private static let nonceInfoPrefix = Data("qaudion-fa-v1-nonce|".utf8)

    public enum CryptoError: Error, Equatable {
        case badArgument(String)
        case sealFailed
        case openFailed
    }

    /// Seal one plaintext chunk for `(fileId, senderId, contentKey)`.
    /// Returns ciphertext = plaintext + 16 B Poly1305 tag.
    public static func sealChunk(
        contentKey: Data, fileId: Data, senderId: Data,
        chunkIdx: Int, totalChunks: Int, plaintext: Data
    ) throws -> Data {
        try validateCommon(contentKey: contentKey, fileId: fileId, senderId: senderId,
                            chunkIdx: chunkIdx, totalChunks: totalChunks)
        guard !plaintext.isEmpty else {
            throw CryptoError.badArgument("plaintext must not be empty")
        }
        let nonce = try deriveNonce(contentKey: contentKey, fileId: fileId, senderId: senderId, chunkIdx: chunkIdx)
        let aad = try buildAad(fileId: fileId, senderId: senderId, chunkIdx: chunkIdx, totalChunks: totalChunks)
        return try xChaCha20Poly1305(forEncryption: true, key: contentKey, nonce24: nonce, aad: aad, input: plaintext)
    }

    /// Verify + decrypt one ciphertext chunk. Throws on AEAD verify failure
    /// or any caller-supplied parameter out of bounds.
    public static func openChunk(
        contentKey: Data, fileId: Data, senderId: Data,
        chunkIdx: Int, totalChunks: Int, ciphertext: Data
    ) throws -> Data {
        try validateCommon(contentKey: contentKey, fileId: fileId, senderId: senderId,
                            chunkIdx: chunkIdx, totalChunks: totalChunks)
        guard ciphertext.count >= poly1305TagLen else {
            throw CryptoError.badArgument("ciphertext too short for Poly1305 tag: \(ciphertext.count)")
        }
        let nonce = try deriveNonce(contentKey: contentKey, fileId: fileId, senderId: senderId, chunkIdx: chunkIdx)
        let aad = try buildAad(fileId: fileId, senderId: senderId, chunkIdx: chunkIdx, totalChunks: totalChunks)
        return try xChaCha20Poly1305(forEncryption: false, key: contentKey, nonce24: nonce, aad: aad, input: ciphertext)
    }

    /// Build the 54-byte AAD bound to `(fileId, senderId, chunkIdx, totalChunks)`.
    public static func buildAad(fileId: Data, senderId: Data, chunkIdx: Int, totalChunks: Int) throws -> Data {
        guard fileId.count == idLen else { throw CryptoError.badArgument("fileId len") }
        guard senderId.count == idLen else { throw CryptoError.badArgument("senderId len") }
        guard chunkIdx >= 0 else { throw CryptoError.badArgument("chunkIdx >= 0") }
        guard totalChunks > 0 else { throw CryptoError.badArgument("totalChunks > 0") }
        guard chunkIdx < totalChunks else { throw CryptoError.badArgument("chunkIdx < totalChunks") }
        var aad = Data(capacity: aadLen)
        aad.append(aadPrefix)
        aad.append(fileId)
        aad.append(senderId)
        aad.append(beUInt32(UInt32(chunkIdx)))
        aad.append(beUInt32(UInt32(totalChunks)))
        precondition(aad.count == aadLen)
        return aad
    }

    /// HKDF-SHA256(ikm = contentKey, salt = fileId||senderId,
    /// info = "qaudion-fa-v1-nonce|" || u32_BE(chunkIdx), L = 24).
    public static func deriveNonce(contentKey: Data, fileId: Data, senderId: Data, chunkIdx: Int) throws -> Data {
        guard contentKey.count == contentKeyLen else { throw CryptoError.badArgument("contentKey len") }
        guard fileId.count == idLen else { throw CryptoError.badArgument("fileId len") }
        guard senderId.count == idLen else { throw CryptoError.badArgument("senderId len") }
        guard chunkIdx >= 0 else { throw CryptoError.badArgument("chunkIdx >= 0") }
        var salt = Data(capacity: idLen * 2)
        salt.append(fileId)
        salt.append(senderId)
        var info = nonceInfoPrefix
        info.append(beUInt32(UInt32(chunkIdx)))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: contentKey),
            salt: salt,
            info: info,
            outputByteCount: nonceLen
        ).withUnsafeBytes { Data($0) }
    }

    // MARK: - Internals

    private static func validateCommon(
        contentKey: Data, fileId: Data, senderId: Data, chunkIdx: Int, totalChunks: Int
    ) throws {
        guard contentKey.count == contentKeyLen else { throw CryptoError.badArgument("contentKey: expected \(contentKeyLen) bytes") }
        guard fileId.count == idLen else { throw CryptoError.badArgument("fileId: expected \(idLen) bytes") }
        guard senderId.count == idLen else { throw CryptoError.badArgument("senderId: expected \(idLen) bytes") }
        guard totalChunks > 0 else { throw CryptoError.badArgument("totalChunks > 0") }
        guard (0..<totalChunks).contains(chunkIdx) else {
            throw CryptoError.badArgument("chunkIdx \(chunkIdx) out of [0, \(totalChunks))")
        }
    }

    /// XChaCha20-Poly1305 = HChaCha20(key, nonce[0..16)) as sub-key, then
    /// ChaCha20-Poly1305(subKey, 0x00000000||nonce[16..24), aad, input).
    /// Identical construction to `AttachmentEncryption.xChaCha20Poly1305`;
    /// duplicated (not shared) to keep the two wire protocols KAT-isolated.
    private static func xChaCha20Poly1305(
        forEncryption: Bool, key: Data, nonce24: Data, aad: Data, input: Data
    ) throws -> Data {
        precondition(key.count == contentKeyLen)
        precondition(nonce24.count == nonceLen)
        let nonce16 = nonce24.prefix(16)
        let subKey = hChaCha20(key: key, nonce16: Data(nonce16))
        var shortNonce = Data(count: shortNonceLen)
        let tail = nonce24.suffix(8)
        shortNonce.replaceSubrange(4..<12, with: tail)

        let symKey = SymmetricKey(data: subKey)
        let ccpNonce = try ChaChaPoly.Nonce(data: shortNonce)
        if forEncryption {
            do {
                let sealed = try ChaChaPoly.seal(input, using: symKey, nonce: ccpNonce, authenticating: aad)
                // Same CryptoKit zero-index footgun fixed in
                // AttachmentEncryption.swift — force a fresh, contiguous,
                // zero-indexed copy at creation.
                return Data(sealed.ciphertext + sealed.tag)
            } catch {
                throw CryptoError.sealFailed
            }
        } else {
            guard input.count >= poly1305TagLen else { throw CryptoError.openFailed }
            let ct = input.prefix(input.count - poly1305TagLen)
            let tag = input.suffix(poly1305TagLen)
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
        state[0] = 0x6170_7865
        state[1] = 0x3320_646e
        state[2] = 0x7962_2d32
        state[3] = 0x6b20_6574
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
        (v << n) | (v >> (32 - n))
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

    private static func beUInt32(_ v: UInt32) -> Data {
        Data([
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF),
        ])
    }
}
