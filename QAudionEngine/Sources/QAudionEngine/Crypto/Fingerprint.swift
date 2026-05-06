import Foundation
import CryptoKit

/// Canonical public-key fingerprint formatter per spec §5.1.
///
/// Format: 4 lowercase 4-hex-char groups separated by dots:
/// `xxxx.xxxx.xxxx.xxxx` (16 hex chars + 3 dots = 19 chars).
///
/// Derived from the first 8 bytes of `SHA-256(public_key_bytes)`.
///
/// Cross-platform parity:
/// - iOS:     this file (formatter + adopt site = KeyMgmt/ContactDetail VMs)
/// - Android: `SovereignKeyVault.kt:656–658` (canonical reference)
/// - Desktop: needs adoption too — currently uses raw 64-hex (Open
///   Discrepancy §3 in INVARIANTS_VERIFIED.md). Desktop side should
///   call its equivalent of this formatter.
public enum Fingerprint {

    public enum Error: Swift.Error, LocalizedError {
        case emptyPubkey

        public var errorDescription: String? {
            switch self {
            case .emptyPubkey: return "Public key bytes are empty"
            }
        }
    }

    /// Compute canonical 4-group hex fingerprint from public key bytes.
    public static func format(pubkey: Data) throws -> String {
        guard !pubkey.isEmpty else { throw Error.emptyPubkey }
        let digest = SHA256.hash(data: pubkey)
        let firstEight = Data(digest.prefix(8))  // 8 bytes → 16 hex chars
        let hex = firstEight.map { String(format: "%02x", $0) }.joined()
        // Split into 4 groups of 4.
        var parts = [String]()
        parts.reserveCapacity(4)
        for i in stride(from: 0, to: 16, by: 4) {
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            parts.append(String(hex[start..<end]))
        }
        return parts.joined(separator: ".")
    }

    /// Validate that a string is in the canonical 4-group hex format.
    public static func isValid(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        for p in parts {
            guard p.count == 4 else { return false }
            guard p.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        }
        return true
    }
}
