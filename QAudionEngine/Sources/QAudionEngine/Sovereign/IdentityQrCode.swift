import Foundation
import CryptoKit

/// Textual QR codec for "show my identity" / "scan contact" flows.
///
/// Format: `QAUDION:1:<userId>:<pubkey-b64>:<checksum-b64>`.
///
/// - userId: arbitrary string, must NOT contain ':' (URL-unsafe characters
///   are URL-encoded inside the userId field).
/// - pubkey: 32 bytes X25519 public key, base64 (no URL-safe variant).
/// - checksum: first 4 bytes of SHA-256(v_byte || userId-utf8 || pubkey),
///   base64. Integrity check only — does NOT authenticate.
///
/// Distinct from `DeviceLinkBinaryQR` (binary §5.6 device-pairing QR).
/// Use this codec for printable / copy-paste-friendly identity sharing.
public enum IdentityQrCode {

    public static let prefix = "QAUDION"
    public static let version = 1
    public static let pubkeyLength = 32
    public static let checksumLength = 4

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
            case .unsupportedVersion(let v): return "Unsupported version \(v) (only v=\(IdentityQrCode.version) supported)"
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
        let cksum = computeChecksum(version: version, userId: identity.userId, pubkey: identity.pubkey)
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
        guard v == version else {
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
        let expected = computeChecksum(version: v, userId: userId, pubkey: pubkey)
        guard cksum == expected else {
            throw Error.checksumMismatch
        }
        return Identity(userId: userId, pubkey: pubkey)
    }

    /// Compute first 4 bytes of SHA-256(v_byte || userId-utf8 || pubkey).
    private static func computeChecksum(version: Int, userId: String, pubkey: Data) -> Data {
        var bytes = Data()
        bytes.append(UInt8(version & 0xFF))
        bytes.append(contentsOf: Data(userId.utf8))
        bytes.append(contentsOf: pubkey)
        let digest = SHA256.hash(data: bytes)
        return Data(digest.prefix(checksumLength))
    }
}
