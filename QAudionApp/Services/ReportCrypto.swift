import Foundation
import CryptoKit

/// W561 — E2EE encryption for bug reports, matching Android's
/// `core-data/.../data/debug/ReportCrypto.kt` and the server's
/// `internal/adminkey/adminkey.go` `Decrypt()` byte-for-byte.
///
/// Protocol: X25519 ECDH + HKDF-SHA256 + AES-256-GCM
/// Wire format: nonce(12) || ciphertext+tag  (raw bytes — the server peels a
/// base64 layer if the client instead uploads this as base64 TEXT; either
/// form round-trips, but this port sends the raw wire like Android's
/// `EncryptedPayload.ciphertext` field, not the base64 string).
///
/// CryptoKit's `SharedSecret.hkdfDerivedSymmetricKey` and
/// `AES.GCM.SealedBox.combined` happen to already produce exactly this wire
/// shape — no manual nonce concatenation needed, unlike the BouncyCastle port
/// on Android which builds the wire by hand.
enum ReportCrypto {

    private static let hkdfSaltInfo = Data("bcrypto-reports-v1".utf8)

    enum CryptoError: Error {
        case invalidPubKeyHex
        case sealFailed
    }

    struct EncryptedPayload {
        /// hex-encoded 32-byte ephemeral public key.
        let ephemeralPubHex: String
        /// RAW wire: nonce(12) || ciphertext+tag.
        let ciphertext: Data
    }

    /// Encrypt `plaintext` for the admin using their X25519 public key.
    /// Generates a fresh ephemeral keypair per call for forward secrecy —
    /// callers encrypt body/logs/screenshot independently, each getting its
    /// own ephemeral key (mirrors Android; the server persists a matching
    /// `*_ephemeral_pub` per field since one field's key does NOT decrypt
    /// another's).
    static func encrypt(adminPubKeyHex: String, plaintext: Data) throws -> EncryptedPayload {
        guard let adminPubBytes = Data(hexEncoded: adminPubKeyHex), adminPubBytes.count == 32 else {
            throw CryptoError.invalidPubKeyHex
        }
        let adminPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: adminPubBytes)

        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralPriv.sharedSecretFromKeyAgreement(with: adminPub)

        let encKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSaltInfo,
            sharedInfo: hkdfSaltInfo,
            outputByteCount: 32
        )

        let sealedBox = try AES.GCM.seal(plaintext, using: encKey)
        guard let combined = sealedBox.combined else { throw CryptoError.sealFailed }

        return EncryptedPayload(
            ephemeralPubHex: ephemeralPriv.publicKey.rawRepresentation.hexEncodedString(),
            ciphertext: combined
        )
    }

    /// Derive a short plaintext diagnostic summary for server-side triage
    /// (the admin report LIST view — never the encrypted body). Max 500
    /// chars. Strips PII patterns (UUIDs, IPs, phone-like numbers) — mirrors
    /// Android's `buildDiagSummary` exactly, same patterns, same caps.
    static func buildDiagSummary(logs: String, note: String, trigger: String) -> String {
        let recentLogs = logs.count > 200 ? String(logs.suffix(200)) : logs
        let safeNote = String(note.prefix(100))

        var stripped = recentLogs
        stripped = stripped.replacingOccurrences(of: uuidPattern, with: "<uuid>", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: ipPattern, with: "<ip>", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: phonePattern, with: "<phone>", options: .regularExpression)

        let raw = "trigger=\(trigger) note=\(safeNote) logs=\(stripped)"
        return raw.count > 500 ? String(raw.prefix(500)) : raw
    }

    // MARK: - PII patterns (identical to Android's ReportCrypto.kt)

    private static let uuidPattern =
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private static let ipPattern =
        "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"
    private static let phonePattern =
        "\\+?\\d[\\d\\s\\-]{7,14}\\d"
}

// MARK: - Hex helpers

private extension Data {
    init?(hexEncoded hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self = Data(bytes)
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
