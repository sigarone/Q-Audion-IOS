import Foundation
import CryptoKit

/// Peppered SHA-256 hash for contact-discovery v2 per spec §5.1.
///
/// **Algorithm**: `hex(SHA-256(pepperBytes ‖ e164_utf8))` lowercase.
/// The pepper is server-issued global random bytes returned base64-encoded
/// from `GET /api/v1/contacts/pepper`. It prevents the server (and any
/// passive eavesdropper) from reverse-hashing dictionary attacks on the
/// contact graph.
///
/// **CRITICAL — cross-platform parity:**
///  - Android (`DiscoverContactsUseCase.kt::peppered`) feeds `pepperBytes`
///    (the base64-decoded bytes) into the digest, NOT the base64 string.
///  - Older iOS revs of this file fed `pepper.utf8` which produces a
///    completely different hash and silently breaks server-side matching.
///  - The W343 fix: the canonical entry point is now
///    `hash(phone:pepperBytes:)` accepting `Data`. The legacy
///    `hash(phone:pepper:)` String overload is retained but treats the
///    string as a base64-encoded payload to match Android — a raw-utf8
///    pepper string is no longer supported.
public enum PepperedPhoneHash {

    public enum Error: Swift.Error, LocalizedError {
        case emptyPepper
        case invalidPepperBase64
        case invalidPhone(String)

        public var errorDescription: String? {
            switch self {
            case .emptyPepper: return "Pepper cannot be empty"
            case .invalidPepperBase64: return "Pepper string is not valid base64"
            case .invalidPhone(let p): return "Phone is not valid E.164: '\(p)'"
            }
        }
    }

    /// Compute the peppered hash with a raw byte pepper (canonical form).
    ///
    /// Matches Android `DiscoverContactsUseCase.peppered(pepper: ByteArray, e164)`:
    ///   ```
    ///   md.update(pepper)
    ///   md.update(e164.toByteArray(UTF_8))
    ///   ```
    public static func hash(phone: String,
                            pepperBytes: Data,
                            defaultCountry: String = "+39") throws -> String {
        guard !pepperBytes.isEmpty else { throw Error.emptyPepper }
        let e164: String
        do {
            e164 = try PhoneHash.normalizeE164(phone, defaultCountry: defaultCountry)
        } catch {
            throw Error.invalidPhone(phone)
        }
        var bytes = Data()
        bytes.append(pepperBytes)
        bytes.append(Data(e164.utf8))
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience overload: pepper as base64 string. Decodes then calls
    /// the byte-form. Mirrors Android's `Base64.decode(pepperB64) -> peppered(...)`.
    public static func hash(phone: String,
                            pepperBase64: String,
                            defaultCountry: String = "+39") throws -> String {
        guard !pepperBase64.isEmpty else { throw Error.emptyPepper }
        guard let pepperBytes = Data(base64Encoded: pepperBase64) else {
            throw Error.invalidPepperBase64
        }
        return try hash(phone: phone, pepperBytes: pepperBytes, defaultCountry: defaultCountry)
    }

    /// Legacy overload — pre-W343 callers passed an arbitrary string. The
    /// only safe interpretation matching Android is that the string is the
    /// server's base64 payload, so we decode it that way. A raw-utf8 string
    /// no longer works; callers must update to either `pepperBytes:` or
    /// `pepperBase64:`.
    @available(*, deprecated, renamed: "hash(phone:pepperBase64:defaultCountry:)",
                message: "Use pepperBytes: (Data) for cross-platform parity, or pepperBase64: for the server response.")
    public static func hash(phone: String,
                            pepper: String,
                            defaultCountry: String = "+39") throws -> String {
        return try hash(phone: phone, pepperBase64: pepper, defaultCountry: defaultCountry)
    }

    /// Batch-hash a list of phones. Invalid phones are skipped silently
    /// (returned tuple has `nil` hash for those entries — caller can filter).
    public static func batchHash(phones: [String],
                                 pepperBytes: Data,
                                 defaultCountry: String = "+39") -> [(input: String, hash: String?)] {
        return phones.map { phone in
            (input: phone, hash: try? hash(phone: phone, pepperBytes: pepperBytes, defaultCountry: defaultCountry))
        }
    }

    /// Batch-hash with the base64-encoded pepper (matches the wire format).
    public static func batchHash(phones: [String],
                                 pepperBase64: String,
                                 defaultCountry: String = "+39") -> [(input: String, hash: String?)] {
        guard let pepperBytes = Data(base64Encoded: pepperBase64) else {
            return phones.map { ($0, nil) }
        }
        return batchHash(phones: phones, pepperBytes: pepperBytes, defaultCountry: defaultCountry)
    }
}
