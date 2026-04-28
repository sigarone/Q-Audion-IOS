import Foundation
import CryptoKit

/// Peppered SHA-256 hash for contact-discovery v2 per spec §5.1.
///
/// Algorithm: `hex(sha256(pepper_utf8 ‖ e164_utf8))` lowercase.
/// The pepper is a server-issued global secret fetched once via
/// `GET /api/v1/contacts/pepper`. It prevents the server from
/// reverse-hashing dictionary attacks on the contact graph.
///
/// Cross-platform parity:
/// - Android: `DiscoverContactsUseCase.kt:284–289` (peppered)
/// - Server:  `bcrypto-server/internal/store/bbolt.go:88–90` + main.go:2007–2031
/// - Desktop: not implemented yet
/// - iOS:     this file
///
/// Reuses E.164 normalization from `PhoneHash.normalizeE164(_:defaultCountry:)`
/// to ensure identical byte input across platforms.
public enum PepperedPhoneHash {

    public enum Error: Swift.Error, LocalizedError {
        case emptyPepper
        case invalidPhone(String)

        public var errorDescription: String? {
            switch self {
            case .emptyPepper: return "Pepper cannot be empty"
            case .invalidPhone(let p): return "Phone is not valid E.164: '\(p)'"
            }
        }
    }

    /// Compute the peppered hash for a single phone number.
    public static func hash(phone: String,
                            pepper: String,
                            defaultCountry: String = "+39") throws -> String {
        guard !pepper.isEmpty else { throw Error.emptyPepper }
        let e164: String
        do {
            e164 = try PhoneHash.normalizeE164(phone, defaultCountry: defaultCountry)
        } catch {
            throw Error.invalidPhone(phone)
        }
        var bytes = Data()
        bytes.append(Data(pepper.utf8))
        bytes.append(Data(e164.utf8))
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Batch-hash a list of phones. Invalid phones are skipped silently
    /// (returned tuple has `nil` hash for those entries — caller can filter).
    public static func batchHash(phones: [String],
                                 pepper: String,
                                 defaultCountry: String = "+39") -> [(input: String, hash: String?)] {
        return phones.map { phone in
            (input: phone, hash: try? hash(phone: phone, pepper: pepper, defaultCountry: defaultCountry))
        }
    }
}
