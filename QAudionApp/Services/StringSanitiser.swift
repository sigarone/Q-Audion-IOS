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
    ///
    /// SECURITY F-4: `trimmingCharacters(.whitespacesAndNewlines)` only
    /// strips *edge* whitespace — embedded C0 (U+0001–U+0008, U+000B,
    /// U+000C, U+000E–U+001F) and C1 (U+0080–U+009F) control characters
    /// passed straight through into CallKit display labels / contact
    /// rows, where they can corrupt or spoof rendered text. They are
    /// now filtered with the same range check as the bidi/zero-width
    /// scalars. 0x09 (TAB), 0x0A (LF) and 0x0D (CR) are intentionally
    /// NOT blocked here — they are ordinary whitespace already handled
    /// by the edge trim and carry no spoofing capability mid-string.
    private static let blockedRanges: [ClosedRange<UInt32>] = [
        0x0001...0x0008,   // C0 controls (excl. TAB/LF/CR/null)
        0x000B...0x000C,   // VT FF        (C0 controls)
        0x000E...0x001F,   // C0 controls  (SO..US)
        0x0080...0x009F,   // C1 controls  (incl. NEL, CSI…)
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
        if capped.isEmpty { return fallback }
        // W569: the server sets display_name = userId (UUID) when a user
        // registers via QR/fast-setup without a real display name. A 36-char
        // string with 4 hyphens at canonical UUID positions is not a human
        // name — treat it the same as empty and fall back. This prevents the
        // 36-char raw UUID appearing on the call screen and SAS panel.
        if looksLikeUUID(capped) { return fallback }
        return capped
    }

    /// Returns true when `s` has the canonical UUID format:
    /// XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX (36 chars, hyphens at [8,13,18,23]).
    private static func looksLikeUUID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        let arr = Array(s)
        guard arr[8] == "-", arr[13] == "-", arr[18] == "-", arr[23] == "-" else { return false }
        // All other positions must be hex digits (0-9, a-f, A-F).
        let hexSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let nonHyphen = [0..<8, 9..<13, 14..<18, 19..<23, 24..<36].flatMap { $0 }
        for i in nonHyphen {
            guard String(arr[i]).unicodeScalars.allSatisfy({ hexSet.contains($0) }) else { return false }
        }
        return true
    }
}
