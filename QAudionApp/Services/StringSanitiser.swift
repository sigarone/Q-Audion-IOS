import Foundation

/// SECURITY H-16 / H-15 — central sanitiser for server- / peer-supplied
/// display strings rendered in trusted UI chrome (call screen, contact
/// rows, fast-setup name field).
///
/// Threats neutralised:
///   - Unicode bidirectional spoofing: explicit LRE/RLE/PDF/LRO/RLO
///     (U+202A…U+202E) and the isolate family LRI/RLI/FSI/PDI
///     (U+2066…U+2069) can reverse rendered text direction so a
///     malicious display name reads as a different user / command.
///   - Zero-width / direction-mark injection: U+200B…U+200F
///     (ZWSP, ZWNJ, ZWJ, LRM, RLM) and the BOM U+FEFF are invisible
///     and can hide content or split a name across what looks like
///     two identities.
///   - Length abuse: an unbounded name overflows the UI and can be
///     used for layout spoofing — capped at 100 scalars.
///
/// CONSTRAINT (CLAUDE.md §16): this is a NEW file and MUST reference
/// only Foundation primitives — never `AppState` or app view-model
/// types. The single public entry point takes `String?` + `String`.
enum StringSanitiser {

    /// Filtered scalar ranges (inclusive) plus the standalone BOM.
    private static let blockedRanges: [ClosedRange<UInt32>] = [
        0x202A...0x202E,   // LRE RLE PDF LRO RLO  (explicit bidi)
        0x2066...0x2069,   // LRI RLI FSI PDI      (bidi isolates)
        0x200B...0x200F    // ZWSP ZWNJ ZWJ LRM RLM (zero-width / marks)
    ]
    private static let blockedScalar: UInt32 = 0xFEFF   // BOM / ZWNBSP

    private static let maxLength = 100

    /// Return a UI-safe display name.
    ///
    /// - Parameters:
    ///   - raw: the untrusted candidate (server/peer supplied). nil or
    ///     empty yields `fallback`.
    ///   - fallback: a trusted, locally-derived string used when `raw`
    ///     is unusable (nil, empty, or empty after sanitisation).
    /// - Returns: trimmed, bidi/zero-width-stripped, length-capped
    ///   string, or `fallback`.
    static func displayName(_ raw: String?, fallback: String) -> String {
        guard let raw = raw, !raw.isEmpty else { return fallback }
        let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            if v == blockedScalar { continue }
            var blocked = false
            for range in blockedRanges where range.contains(v) {
                blocked = true
                break
            }
            if blocked { continue }
            out.append(scalar)
        }
        let cleaned = String(out)
        let capped: String = String(cleaned.prefix(maxLength))
        return capped.isEmpty ? fallback : capped
    }
}
