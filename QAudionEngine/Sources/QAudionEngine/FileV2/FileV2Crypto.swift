import Foundation
import CryptoKit

/// Everything derived from (`K`, `file_id`) with HKDF-SHA256 (section 12.2).
struct FileV2DerivedKeys {
    /// `HKDF-Extract(salt = file_id, IKM = K)`. Exposed to the known-answer tests only.
    let prk: Data
    /// `K_enc`: the AES-256 key of the chunks. `K` itself is never used as an AES key.
    let encryptionKey: SymmetricKey
    /// The first 8 bytes of every chunk nonce.
    let noncePrefix: Data
    /// The 32-byte key commitment stored in the header.
    let commitment: Data
}

/// The primitives of sections 12.2, 12.5 and 12.6: key derivation, nonce, AAD, per-chunk
/// AES-256-GCM seal and open. CryptoKit only: `AES.GCM` with a 12-byte nonce and `HKDF<SHA256>`.
enum FileV2Crypto {

    static let infoEncryption = Data("qaudion-file-v2-enc".utf8)
    static let infoNonce = Data("qaudion-file-v2-nonce".utf8)
    static let infoCommitment = Data("qaudion-file-v2-commit".utf8)
    static let aadLabel = Data("qaudion-file-v2-chunk".utf8)

    /// `PRK = HKDF-Extract(file_id, K)`; `K_enc`, `nonce_prefix` and `commitment` are HKDF-Expand of
    /// the PRK with the three ASCII `info` strings (no terminator), 32, 8 and 32 bytes.
    static func derive(fileKey: Data, fileID: Data) -> FileV2DerivedKeys {
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: fileKey), salt: fileID)
        let encryptionKey = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: infoEncryption, outputByteCount: 32)
        let noncePrefix = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: infoNonce, outputByteCount: 8)
        let commitment = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: infoCommitment, outputByteCount: 32)
        return FileV2DerivedKeys(
            prk: prk.withUnsafeBytes { Data($0) },
            encryptionKey: encryptionKey,
            noncePrefix: noncePrefix.withUnsafeBytes { Data($0) },
            commitment: commitment.withUnsafeBytes { Data($0) })
    }

    /// `nonce_i = nonce_prefix || u32be(i)` (12 bytes).
    static func chunkNonce(prefix: Data, index: UInt32) -> Data {
        var nonce = Data()
        nonce.reserveCapacity(12)
        nonce.append(prefix)
        nonce.append(contentsOf: bigEndian(index))
        return nonce
    }

    /// `AAD_i = "qaudion-file-v2-chunk" || header(64) || u32be(i) || final_i` (90 bytes).
    static func chunkAAD(header: Data, index: UInt32, final: Bool) -> Data {
        var aad = Data()
        aad.reserveCapacity(aadLabel.count + header.count + 5)
        aad.append(aadLabel)
        aad.append(header)
        aad.append(contentsOf: bigEndian(index))
        aad.append(final ? 0x01 : 0x00)
        return aad
    }

    /// `C_i = AES-256-GCM(K_enc, nonce_i, AAD_i, P_i) = ciphertext || tag(16)`.
    static func seal(plaintext: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce, authenticating: aad)
        var sealed = Data()
        sealed.reserveCapacity(plaintext.count + FileV2.tagSize)
        sealed.append(box.ciphertext)
        sealed.append(box.tag)
        return sealed
    }

    /// Opens `ciphertext || tag(16)`. Any failure (a short input, a truncated tag, a bad tag) is
    /// `chunk_auth`; the whole 16-byte tag is always checked.
    static func open(sealed: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        guard sealed.count > FileV2.tagSize else { throw FileV2Error.chunkAuth }
        do {
            let gcmNonce = try AES.GCM.Nonce(data: nonce)
            let split = sealed.count - FileV2.tagSize
            let box = try AES.GCM.SealedBox(
                nonce: gcmNonce,
                ciphertext: sealed.prefix(split),
                tag: sealed.suffix(FileV2.tagSize))
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw FileV2Error.chunkAuth
        }
    }

    /// Constant-time equality, for the commitment (section 12.6 step 1).
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * $0)) }
    }
}
