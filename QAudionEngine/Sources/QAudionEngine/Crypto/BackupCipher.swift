import Foundation
import CryptoKit

/// Backup file cipher primitives per spec §5.10.
///
/// Two halves:
/// 1. **Key derivation:** scrypt(password, salt, N=2^17, r=8, p=1) → 32B
///    — implemented via Scrypt.swift (RFC 7914 clean-room, unblocked 2026-04-28
///    per §10 .qabk container format alignment with Android QAUD format).
/// 2. **AEAD:** AES-256-GCM (12B nonce, 16B tag) — fully implemented.
///
/// For the complete .qabk container (QAUD magic + salt + nonce + ciphertext +
/// tag), see BackupContainer.swift.
public enum BackupCipher {

    public struct SealedBox: Equatable {
        public let nonce: Data        // 12 bytes
        public let ciphertext: Data   // same length as plaintext
        public let tag: Data          // 16 bytes

        public init(nonce: Data, ciphertext: Data, tag: Data) {
            self.nonce = nonce
            self.ciphertext = ciphertext
            self.tag = tag
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case wrongNonceSize(Int)
        case scryptNotImplemented   // retained for back-compat; no longer thrown
        case scryptFailed(String)
        case aeadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .wrongNonceSize(let n):
                return "AES-GCM nonce must be 12B, got \(n)"
            case .scryptNotImplemented:
                return "scrypt not yet implemented (legacy case — should not be reached)"
            case .scryptFailed(let m):
                return "scrypt key derivation failed: \(m)"
            case .aeadFailed(let m):
                return "AEAD operation failed: \(m)"
            }
        }
    }

    // MARK: - AEAD (AES-256-GCM, 12B nonce, 16B tag)

    public static func aeadEncrypt(
        plaintext: Data,
        key: SymmetricKey,
        nonce: Data,
        aad: Data?
    ) throws -> SealedBox {
        guard nonce.count == 12 else { throw Error.wrongNonceSize(nonce.count) }
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed: AES.GCM.SealedBox
        do {
            if let aad = aad {
                sealed = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce, authenticating: aad)
            } else {
                sealed = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce)
            }
        } catch {
            throw Error.aeadFailed(String(describing: error))
        }
        return SealedBox(
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    public static func aeadDecrypt(
        _ box: SealedBox,
        key: SymmetricKey,
        aad: Data?
    ) throws -> Data {
        guard box.nonce.count == 12 else { throw Error.wrongNonceSize(box.nonce.count) }
        guard box.tag.count == 16 else {
            throw Error.aeadFailed("tag must be 16B, got \(box.tag.count)")
        }
        let aesNonce = try AES.GCM.Nonce(data: box.nonce)
        let sealed = try AES.GCM.SealedBox(nonce: aesNonce, ciphertext: box.ciphertext, tag: box.tag)
        do {
            if let aad = aad {
                return try AES.GCM.open(sealed, using: key, authenticating: aad)
            } else {
                return try AES.GCM.open(sealed, using: key)
            }
        } catch {
            throw Error.aeadFailed(String(describing: error))
        }
    }

    // MARK: - Key derivation (RFC 7914 scrypt — UNBLOCKED §10)

    /// Derives a 32-byte symmetric key from password+salt via scrypt.
    ///
    /// Uses RFC 7914 scrypt (N=131072, r=8, p=1, dkLen=32) — Android QAUD
    /// parameters adopted by iOS per user directive 2026-04-28 (§10 unblock).
    public static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        do {
            let bytes = try Scrypt.deriveKey(
                password: Data(password.utf8), salt: salt,
                n: 131_072, r: 8, p: 1, dkLen: 32
            )
            return SymmetricKey(data: bytes)
        } catch {
            throw Error.scryptFailed(String(describing: error))
        }
    }
}
