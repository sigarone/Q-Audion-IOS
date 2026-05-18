import Foundation
import CryptoKit

/// .qabk backup container per Android QAUD format (adopted by iOS per
/// user directive 2026-04-28 — UNBLOCKS Open Discrepancy §10).
///
/// Layout v1: [4B "QAUD" | 1B version=1 | 16B salt | 12B nonce | <ct> | 16B tag]
/// Layout v2: [4B "QAUD" | 1B version=2 | 32B salt | 12B nonce | <ct> | 16B tag]
///
/// Cipher: scrypt(password, salt, N=131072, r=8, p=1, dkLen=32) → AES-256-GCM
/// AAD: container metadata (magic + version + salt + nonce) for tamper detection.
///
/// SECURITY M-21 — v1's 16-byte salt is below the modern 32-byte
/// recommendation for password-based KDFs. v2 raises it to 32 bytes.
/// `open()` branches on the version byte and still accepts v1 (16B
/// salt) so existing `.qabk` backups remain restorable; `seal()`
/// always emits v2.
public enum BackupContainer {

    public static let magic: Data = Data([0x51, 0x41, 0x55, 0x44])  // "QAUD"
    /// SECURITY M-21 — version emitted by `seal()`. v1 retained for read.
    public static let version: UInt8 = 2
    public static let versionV1: UInt8 = 1
    /// SECURITY M-21 — v1 salt = 16B (read-only), v2 salt = 32B (written).
    public static let saltLengthV1 = 16
    public static let saltLength = 32
    public static let nonceLength = 12
    public static let tagLength = 16
    public static let scryptN = 131_072  // 2^17
    public static let scryptR = 8
    public static let scryptP = 1
    public static let scryptDkLen = 32

    public enum Error: Swift.Error, LocalizedError {
        case wrongMagic
        case unsupportedVersion(UInt8)
        case truncated
        case scryptFailed(String)
        case aeadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .wrongMagic: return "Container magic is not QAUD"
            case .unsupportedVersion(let v): return "Unsupported container version: \(v)"
            case .truncated: return "Container truncated (header + tag = 49 bytes minimum)"
            case .scryptFailed(let m): return "scrypt failed: \(m)"
            case .aeadFailed(let m): return "AEAD failed: \(m)"
            }
        }
    }

    /// Encrypt plaintext into the container using password-derived key.
    public static func seal(plaintext: Data, password: String) throws -> Data {
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: 0...UInt8.max) })
        let nonce = Data((0..<nonceLength).map { _ in UInt8.random(in: 0...UInt8.max) })

        let key: Data
        do {
            key = try Scrypt.deriveKey(
                password: Data(password.utf8), salt: salt,
                n: scryptN, r: scryptR, p: scryptP, dkLen: scryptDkLen
            )
        } catch { throw Error.scryptFailed(String(describing: error)) }

        // AAD = magic + version + salt + nonce.
        var aad = Data()
        aad.append(magic)
        aad.append(version)
        aad.append(salt)
        aad.append(nonce)

        let symKey = SymmetricKey(data: key)
        let aesNonce: AES.GCM.Nonce
        do {
            aesNonce = try AES.GCM.Nonce(data: nonce)
        } catch { throw Error.aeadFailed(String(describing: error)) }

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: aesNonce, authenticating: aad)
        } catch { throw Error.aeadFailed(String(describing: error)) }

        // Layout: magic + version + salt + nonce + ciphertext + tag.
        var out = Data()
        out.append(magic)
        out.append(version)
        out.append(salt)
        out.append(nonce)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Decrypt container, verifying tag. Returns plaintext.
    ///
    /// SECURITY M-21 — branches on the version byte so both v1
    /// (16-byte salt) and v2 (32-byte salt) `.qabk` files open.
    public static func open(_ container: Data, password: String) throws -> Data {
        // Need at least magic + version byte to read the version.
        guard container.count >= magic.count + 1 else { throw Error.truncated }
        guard container.prefix(magic.count) == magic else { throw Error.wrongMagic }

        var idx = magic.count
        let containerVersion = container[idx]; idx += 1

        // SECURITY M-21 — salt length is version-dependent.
        let effectiveSaltLength: Int
        switch containerVersion {
        case BackupContainer.versionV1: effectiveSaltLength = saltLengthV1
        case BackupContainer.version:   effectiveSaltLength = saltLength
        default: throw Error.unsupportedVersion(containerVersion)
        }

        let minSize = magic.count + 1 + effectiveSaltLength + nonceLength + tagLength
        guard container.count >= minSize else { throw Error.truncated }

        let salt = container.subdata(in: idx..<(idx + effectiveSaltLength)); idx += effectiveSaltLength
        let nonce = container.subdata(in: idx..<(idx + nonceLength)); idx += nonceLength

        let ctEnd = container.count - tagLength
        let ciphertext = container.subdata(in: idx..<ctEnd)
        let tag = container.subdata(in: ctEnd..<container.count)

        // Derive key.
        let key: Data
        do {
            key = try Scrypt.deriveKey(
                password: Data(password.utf8), salt: salt,
                n: scryptN, r: scryptR, p: scryptP, dkLen: scryptDkLen
            )
        } catch { throw Error.scryptFailed(String(describing: error)) }

        // AAD = magic + version + salt + nonce.
        var aad = Data()
        aad.append(magic)
        aad.append(containerVersion)
        aad.append(salt)
        aad.append(nonce)

        let symKey = SymmetricKey(data: key)
        let aesNonce: AES.GCM.Nonce
        let sealedBox: AES.GCM.SealedBox
        do {
            aesNonce = try AES.GCM.Nonce(data: nonce)
            sealedBox = try AES.GCM.SealedBox(nonce: aesNonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealedBox, using: symKey, authenticating: aad)
        } catch { throw Error.aeadFailed(String(describing: error)) }
    }
}
