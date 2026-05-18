import Foundation
import CryptoKit

/// E.164 phone-number normaliser + SHA-256 hash helper.
///
/// 1:1 port of the Android source of truth:
///   `qaudion-android-new/feature/feature-auth/PhoneHashHelper.kt`
///
/// Cross-platform discipline: every platform must derive the SAME
/// `phone_hash` from the SAME raw phone number, otherwise contact discovery
/// + fast-setup login break across iOS / Android / Desktop.
///
/// Normalisation rules (verbatim Android):
///   - Strip whitespace, NBSP, dots, parens, dashes, slashes (typical
///     separators pasted from contacts / OCR).
///   - Leading `00` → `+` (international trunk prefix convention).
///   - If no `+` after stripping, prepend `defaultCountry` (SECURITY/UX
///     L-9: default now derived from `Locale.current` region, falling
///     back to `+39` only for unknown regions; inputs already carrying
///     `+`/`00` are unaffected).
///   - Result MUST match `^\+[1-9]\d{7,14}$` or we throw.
///
/// Output format: lowercase hex SHA-256 of the UTF-8 E.164 string.
public enum PhoneHashHelper {

    // MARK: - SECURITY/UX L-9 — configurable default country

    /// SECURITY/UX L-9: the previous code hardcoded `+39` (Italy) as the
    /// default calling code for inputs without a leading `+`. A non-IT
    /// user typing a local number would get a wrong, IT-prefixed
    /// `phone_hash` that never matches their real contacts. Derive a
    /// sensible default from the device region instead; fall back to
    /// `+39` only when the region is unknown / unmapped (preserves the
    /// historical behavior for that case). Inputs that already carry a
    /// `+` (or `00` trunk) are unaffected — the default is only applied
    /// when no country is present.
    public static func defaultCallingCode() -> String {
        let region: String?
        if #available(iOS 16, *) {
            region = Locale.current.region?.identifier
        } else {
            region = Locale.current.regionCode
        }
        guard let region = region,
              let code = callingCodeByRegion[region.uppercased()] else {
            return "+39"
        }
        return code
    }

    /// Minimal ISO-3166 alpha-2 → E.164 calling-code map covering the
    /// regions Q-Audion ships to. Unmapped regions fall back to `+39`.
    private static let callingCodeByRegion: [String: String] = [
        "IT": "+39", "FR": "+33", "DE": "+49", "GB": "+44", "ES": "+34",
        "US": "+1",  "CA": "+1",  "CH": "+41", "AT": "+43", "BE": "+32",
        "NL": "+31", "PT": "+351","CZ": "+420","PL": "+48", "SE": "+46",
        "NO": "+47", "DK": "+45", "FI": "+358","IE": "+353","GR": "+30",
        "RU": "+7",  "UA": "+380","RO": "+40", "HU": "+36", "SK": "+421"
    ]

    /// E.164 grammar pinned by Android. + then country digit 1-9, then
    /// 7-14 more digits (total 8-15 digits after +).
    private static let e164Regex: NSRegularExpression = {
        // Force-try is safe — pattern is a literal we wrote.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: #"^\+[1-9]\d{7,14}$"#)
    }()

    /// Same character class Kotlin uses to pre-strip user input:
    /// `[\s ().\-/]`. We compile this as an `NSRegularExpression`
    /// instead of a `Set<Character>` so Swift's `\s` covers the SAME
    /// Unicode whitespace family Kotlin's `\s` covers — including form
    /// feed (U+000C), vertical tab (U+000B), line separator (U+2028),
    /// paragraph separator (U+2029), and NEL (U+0085) — any of which a
    /// user might paste from Excel / Word / iOS Mail. NVIDIA review on
    /// the W17 port caught the original `Set<Character>` implementation
    /// missing those, which would have caused cross-platform
    /// `phone_hash` mismatch for otherwise-identical inputs.
    private static let separatorRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: #"[\s ().\-/]"#)
    }()

    public enum Error: Swift.Error, LocalizedError {
        case empty
        case notValidE164(String)
        case defaultCountryMustStartWithPlus(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Phone number is empty"
            case .notValidE164(let s):
                return "Not a valid E.164 phone: '\(s)'"
            case .defaultCountryMustStartWithPlus(let s):
                return "defaultCountry must start with '+', got '\(s)'"
            }
        }
    }

    /// Normalise a user-typed phone number to canonical E.164 form.
    /// Throws if the result does not match E.164.
    public static func normalizeE164(_ raw: String,
                                     defaultCountry: String = PhoneHashHelper.defaultCallingCode()) throws -> String {
        guard defaultCountry.hasPrefix("+") else {
            throw Error.defaultCountryMustStartWithPlus(defaultCountry)
        }

        // Step 1: strip the separator class via regex (matches Kotlin's
        // `\s` semantics, see `separatorRegex` doc comment for why we
        // can't use a Swift `Set<Character>` here).
        let stripped = separatorRegex.stringByReplacingMatches(
            in: raw,
            options: [],
            range: NSRange(raw.startIndex..<raw.endIndex, in: raw),
            withTemplate: ""
        )

        guard !stripped.isEmpty else {
            throw Error.empty
        }

        // Step 2: leading "00" → "+".
        let trunkExpanded: String = {
            if stripped.hasPrefix("00") {
                return "+" + stripped.dropFirst(2)
            }
            return stripped
        }()

        // Step 3: prepend defaultCountry if no leading "+".
        let withPrefix: String
        if trunkExpanded.hasPrefix("+") {
            withPrefix = trunkExpanded
        } else {
            // Trim a single leading "0" the same way Kotlin does
            // (`.trimStart('0')` in Kotlin actually drops ALL leading 0s,
            // so we mirror that semantics here).
            let trimmed = trunkExpanded.drop(while: { $0 == "0" })
            withPrefix = defaultCountry + trimmed
        }

        // Step 4: validate.
        let nsRange = NSRange(withPrefix.startIndex..<withPrefix.endIndex, in: withPrefix)
        if e164Regex.firstMatch(in: withPrefix, options: [], range: nsRange) == nil {
            throw Error.notValidE164(withPrefix)
        }
        return withPrefix
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes of `input`.
    /// Used wherever the Bcrypto wire expects `phone_hash`.
    public static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience: normalise + hash in one call.
    public static func hashPhone(_ raw: String,
                                 defaultCountry: String = PhoneHashHelper.defaultCallingCode()) throws -> String {
        let e164 = try normalizeE164(raw, defaultCountry: defaultCountry)
        return sha256Hex(e164)
    }

    /// Lightweight, non-throwing validation for UI enablement.
    public static func isValid(_ raw: String,
                               defaultCountry: String = PhoneHashHelper.defaultCallingCode()) -> Bool {
        return (try? normalizeE164(raw, defaultCountry: defaultCountry)) != nil
    }
}
