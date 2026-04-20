import CryptoKit
import Foundation

/// Canonical phone-number normalization + SHA-256 hashing helper.
///
/// Byte-for-byte parity with Android `PhoneHashHelper` in
/// `feature-auth/.../PhoneHashHelper.kt`. The Bcrypto server's `phone_hash`
/// parameter MUST be produced by this helper on iOS; ad-hoc `sha256(rawInput)`
/// calls break iOS↔Android interop the first time either side formats a
/// number differently (spaces, parens, `00` prefix, country code elision).
public enum PhoneHash {

    public enum Error: Swift.Error, LocalizedError {
        case empty
        case invalidE164(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "Phone number is empty"
            case .invalidE164(let s): return "Not a valid E.164 phone: '\(s)'"
            }
        }
    }

    /// `^\+[1-9]\d{7,14}$` — identical to Android `PhoneHashHelper.E164_REGEX`.
    private static let e164Regex: NSRegularExpression = {
        // Pattern is a compile-time constant, force-try is safe.
        return try! NSRegularExpression(pattern: #"^\+[1-9]\d{7,14}$"#)
    }()

    /// `[\s\u00A0().\-/]` — matches the Kotlin strip regex.
    private static let strippable: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "()\u{00A0}.-/")
        return set
    }()

    /// Normalize a user-typed phone number to canonical E.164.
    /// Throws `Error.empty` or `Error.invalidE164` on bad input.
    public static func normalizeE164(_ raw: String, defaultCountry: String = "+39") throws -> String {
        precondition(defaultCountry.hasPrefix("+"),
                     "defaultCountry must start with '+', got '\(defaultCountry)'")

        var stripped = raw.components(separatedBy: strippable).joined()
        if stripped.hasPrefix("00") {
            stripped = "+" + stripped.dropFirst(2)
        }

        let withPrefix: String
        if stripped.isEmpty {
            throw Error.empty
        } else if stripped.hasPrefix("+") {
            withPrefix = stripped
        } else {
            var trimmed = stripped
            while trimmed.hasPrefix("0") { trimmed.removeFirst() }
            withPrefix = defaultCountry + trimmed
        }

        let range = NSRange(withPrefix.startIndex..., in: withPrefix)
        if Self.e164Regex.firstMatch(in: withPrefix, range: range) == nil {
            throw Error.invalidE164(withPrefix)
        }
        return withPrefix
    }

    /// Lowercase hex SHA-256 of `input`.
    public static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256(E.164).hex_lowercase — the Bcrypto `phone_hash` on the wire.
    public static func hash(_ raw: String, defaultCountry: String = "+39") throws -> String {
        return sha256Hex(try normalizeE164(raw, defaultCountry: defaultCountry))
    }

    /// Non-throwing variant that returns `nil` on invalid input. Use when
    /// iterating over an address book and invalid entries must be skipped.
    public static func hashOrNil(_ raw: String, defaultCountry: String = "+39") -> String? {
        return try? hash(raw, defaultCountry: defaultCountry)
    }

    /// Non-throwing validity check for UI enablement.
    public static func isValid(_ raw: String, defaultCountry: String = "+39") -> Bool {
        return (try? normalizeE164(raw, defaultCountry: defaultCountry)) != nil
    }
}
