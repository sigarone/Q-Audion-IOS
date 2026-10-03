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
    ///
    /// W-REPORTFREEZE (2026-10-03): only the LAST 200 characters of the redacted log are
    /// used, yet this used to redact the WHOLE log (1.36 MB in a group-call report, ~2,350
    /// stashed values) on the main actor -- the ~32 s hang of the call of 2026-10-03. It now
    /// redacts only the raw tail window (`diagTailWindow`), which gives the same 200
    /// characters, and it is no longer `@MainActor`: `LogRedactor` is not isolated, and the
    /// report is assembled off the main actor (`BugReportAssembler`).
    static func buildDiagSummary(logs: String, note: String, trigger: String) -> String {
        // FIX-11 (2026-09-12): this 200-char tail is stored PLAINTEXT
        // server-side (report_routes.go keeps diag_summary verbatim), so
        // it gets the same structured redaction (bearer/JWT/psk/base64
        // runs) as every other log egress before the PII patterns below.
        // W-KEYSCRUB: `logs` is the multi-line tail, every line already scrubbed at ring
        // entry; the key-material scrub inside `redactStructured` is line oriented
        // (`scrubLines`), so a `derived_key <marker>` line does not swallow the newer lines
        // below it and the 200-character tail below stays the LAST lines.
        let window = String(diagTailWindow(of: logs))
        return diagSummary(redactedLogs: LogRedactor.redactStructured(window), note: note, trigger: trigger)
    }

    /// Size, in UTF-8 bytes, of the raw tail that `buildDiagSummary` redacts. Redaction never
    /// shrinks text to less than about half of its length (a 24-character run becomes the
    /// 14-character placeholder, `1.2.3.4` becomes `<ip>`), so 16 KiB of raw text always
    /// leaves far more than the 200 characters that are kept.
    static let diagTailWindowBytes: Int = 16 * 1024

    /// The part of `logs` whose redaction yields the same last 200 characters as redacting all
    /// of `logs`: the last `windowBytes` bytes, moved BACK to the start of the line they cut,
    /// so every line in it is whole.
    ///
    /// Why that is enough: the redactor is line-local (the key-material scrub is per line;
    /// every pattern's character class excludes the line feed) except for one rule, a keyword
    /// such as `token=` followed by whitespace and then its value, whose whitespace can span a
    /// line feed. A keyword at the end of the line BEFORE the window can therefore still
    /// redact the first token of the window in the whole text but not in the window: that
    /// token is thousands of characters before the 200 kept at the end, so it cannot change
    /// them. A text that is shorter than the window, or has no line feed before the cut, is
    /// returned whole.
    static func diagTailWindow(of logs: String, windowBytes: Int = diagTailWindowBytes) -> Substring {
        let utf8 = logs.utf8
        guard utf8.count > windowBytes else { return logs[...] }
        let cut = utf8.index(utf8.endIndex, offsetBy: -windowBytes)
        if let lineFeed = utf8[..<cut].lastIndex(of: 0x0A) {
            return logs[utf8.index(after: lineFeed)...]
        }
        return logs[...]
    }

    /// The summary from an already redacted log: its last 200 characters, the PII patterns
    /// below, and the 500-character cap.
    static func diagSummary(redactedLogs scrubbed: String, note: String, trigger: String) -> String {
        let recentLogs = scrubbed.count > 200 ? String(scrubbed.suffix(200)) : scrubbed
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
