import Foundation
import CryptoKit

/// Backup file cipher primitives per spec §5.10.
///
/// Two halves:
/// 1. **Key derivation:** scrypt(password, salt, N=2^15, r=8, p=1) → 32B
///    — currently STUBBED pending cross-platform §10 .qabk container
///    format alignment. CryptoKit does not include scrypt; we'll either
///    implement RFC 7914 minimally or pull in a vetted dependency once
///    Desktop QABK and Android QAUD converge.
/// 2. **AEAD:** AES-256-GCM (12B nonce, 16B tag) — fully implemented.
///
/// The container layout (`QABK` magic, version byte, metadata, payload)
/// is BLOCKED at §10 in INVARIANTS_VERIFIED.md. This module ships the
/// cipher so the container layer can plug into it once unblocked.
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
        case scryptNotImplemented   // see file docstring
        case aeadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .wrongNonceSize(let n):
                return "AES-GCM nonce must be 12B, got \(n)"
            case .scryptNotImplemented:
                return "scrypt not yet implemented — blocked by Open Discrepancy §10 (.qabk container format alignment)"
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

    // MARK: - Key derivation (STUBBED)

    /// Derives a 32-byte symmetric key from password+salt via scrypt.
    ///
    /// **NOT YET IMPLEMENTED.** CryptoKit doesn't ship scrypt. Implementation
    /// is gated on Open Discrepancy §10 — once Desktop and Android agree on
    /// the .qabk container layout, this method will be filled in (RFC 7914
    /// scrypt with N=32768, r=8, p=1, len=32).
    public static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        throw Error.scryptNotImplemented
    }

    /// Once scrypt is implemented, the high-level convenience API will be
    /// `seal(plaintext:password:salt:nonce:aad:)` returning a complete
    /// `(salt, nonce, ciphertext, tag)` tuple ready for the container layer.
    /// Documented here as a roadmap marker.
}
