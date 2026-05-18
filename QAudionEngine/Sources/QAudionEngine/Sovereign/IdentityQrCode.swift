import Foundation
import CryptoKit

/// Textual QR codec for "show my identity" / "scan contact" flows.
///
/// Format: `QAUDION:<v>:<userId>:<pubkey-b64>:<checksum-b64>`.
///
/// - userId: arbitrary string, must NOT contain ':' (URL-unsafe characters
///   are URL-encoded inside the userId field).
/// - pubkey: 32 bytes X25519 public key, base64 (no URL-safe variant).
/// - checksum: first N bytes of SHA-256(v_byte || userId-utf8 || pubkey),
///   base64. Integrity check only — does NOT authenticate.
///
/// SECURITY M-29 — checksum widened 4B → 8B (64-bit).
/// A 32-bit checksum is offline-forgeable: an attacker who wants a
/// QR string that decodes to an attacker-chosen (userId, pubkey) only
/// needs ~2^32 SHA-256 evaluations to brute a colliding 4-byte tag —
/// seconds on commodity hardware. Widening to 8 bytes raises that to
/// ~2^64, infeasible offline. The version byte is bumped 1 → 2 so the
/// checksum width is unambiguous; `decode` still accepts v1 (4-byte,
/// legacy) QR codes for backward compatibility while `encode` only
/// emits v2.
///
/// Distinct from `DeviceLinkBinaryQR` (binary §5.6 device-pairing QR).
/// Use this codec for printable / copy-paste-friendly identity sharing.
public enum IdentityQrCode {

    public static let prefix = "QAUDION"
    /// Current emitted version (SECURITY M-29: was 1, now 2 = 8-byte checksum).
    public static let version = 2
    /// Legacy version still accepted on decode (4-byte checksum).
    public static let legacyVersion = 1
    public static let pubkeyLength = 32
    /// Checksum width for the current version (SECURITY M-29: 4 → 8).
    public static let checksumLength = 8
    /// Checksum width for legacy v1 QR codes.
    public static let legacyChecksumLength = 4

    public struct Identity: Equatable {
        public let userId: String
        public let pubkey: Data       // 32 bytes

        public init(userId: String, pubkey: Data) {
            self.userId = userId
            self.pubkey = pubkey
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case wrongPubkeyLength(Int)
        case userIdContainsColon
        case malformedString(String)
        case unsupportedVersion(Int)
        case base64Failed
        case checksumMismatch

        public var errorDescription: String? {
            switch self {
            case .wrongPubkeyLength(let n): return "pubkey must be \(IdentityQrCode.pubkeyLength)B, got \(n)"
            case .userIdContainsColon: return "userId must not contain ':' character"
            case .malformedString(let s): return "Malformed QR string: '\(s)'"
            case .unsupportedVersion(let v): return "Unsupported version \(v) (supported: v=\(IdentityQrCode.legacyVersion) or v=\(IdentityQrCode.version))"
            case .base64Failed: return "base64 decode failed"
            case .checksumMismatch: return "Integrity checksum failed"
            }
        }
    }

    /// Encode identity to printable string.
    public static func encode(identity: Identity) throws -> String {
        guard identity.pubkey.count == pubkeyLength else {
            throw Error.wrongPubkeyLength(identity.pubkey.count)
        }
        guard !identity.userId.contains(":") else {
            throw Error.userIdContainsColon
        }
        let pkB64 = identity.pubkey.base64EncodedString()
        // SECURITY M-29: always emit current version (v2, 8-byte checksum).
        let cksum = computeChecksum(version: version,
                                    userId: identity.userId,
                                    pubkey: identity.pubkey,
                                    length: checksumLength)
        let cksumB64 = cksum.base64EncodedString()
        return "\(prefix):\(version):\(identity.userId):\(pkB64):\(cksumB64)"
    }

    /// Decode + integrity-verify identity from printable string.
    public static func decode(string: String) throws -> Identity {
        let parts = string.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5 else {
            throw Error.malformedString(string)
        }
        guard parts[0] == prefix else {
            throw Error.malformedString(string)
        }
        guard let v = Int(parts[1]) else {
            throw Error.malformedString(string)
        }
        // SECURITY M-29: accept v2 (8-byte checksum, current) and v1
        // (4-byte checksum, legacy) for backward compatibility.
        let expectedChecksumLength: Int
        if v == version {
            expectedChecksumLength = checksumLength
        } else if v == legacyVersion {
            // legacy path: 4-byte checksum, weaker but still verified.
            expectedChecksumLength = legacyChecksumLength
        } else {
            throw Error.unsupportedVersion(v)
        }
        let userId = String(parts[2])
        guard let pubkey = Data(base64Encoded: String(parts[3])) else {
            throw Error.base64Failed
        }
        guard pubkey.count == pubkeyLength else {
            throw Error.wrongPubkeyLength(pubkey.count)
        }
        guard let cksum = Data(base64Encoded: String(parts[4])) else {
            throw Error.base64Failed
        }
        guard cksum.count == expectedChecksumLength else {
            throw Error.checksumMismatch
        }
        let expected = computeChecksum(version: v,
                                       userId: userId,
                                       pubkey: pubkey,
                                       length: expectedChecksumLength)
        guard cksum == expected else {
            throw Error.checksumMismatch
        }
        return Identity(userId: userId, pubkey: pubkey)
    }

    /// SECURITY M-29: compute first `length` bytes of
    /// SHA-256(v_byte || userId-utf8 || pubkey). `length` is 8 for the
    /// current version (v2) and 4 for legacy v1 QR codes — the version
    /// byte is part of the hashed preimage so a v1 and v2 tag for the
    /// same identity differ even before truncation.
    private static func computeChecksum(version: Int,
                                        userId: String,
                                        pubkey: Data,
                                        length: Int) -> Data {
        var bytes = Data()
        bytes.append(UInt8(version & 0xFF))
        bytes.append(contentsOf: Data(userId.utf8))
        bytes.append(contentsOf: pubkey)
        let digest = SHA256.hash(data: bytes)
        return Data(digest.prefix(length))
    }
}
