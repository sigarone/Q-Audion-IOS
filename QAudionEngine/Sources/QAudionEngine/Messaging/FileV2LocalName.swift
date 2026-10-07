import Foundation

/// The name of a received file on this device. The name comes from a peer (`nm` of the descriptor) and is untrusted: it is
/// used as ONE path component and shown to the user, so it is cut to a safe, readable form.
///
/// Same rules as the sanitiser of the old attachment receiver (path separators become `_`, control characters go, an empty
/// result or a name made of dots becomes a fixed name, the length is bounded), plus the characters that can make a name lie
/// when it is displayed: the bidirectional controls (an `exe` that reads as `fdp`), the byte order mark and the line and
/// paragraph separators.
public enum FileV2LocalName {

    /// Longest name this returns, in UTF-8 bytes (the file system allows 255; the receiver adds a prefix of its own).
    public static let maxBytes = 120
    public static let fallback = "allegato"

    public static func sanitised(_ name: String?) -> String {
        guard let name else { return fallback }
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x2F, 0x5C, 0x3A:                       // "/" "\" ":"
                scalars.append("_")
            case 0x00...0x1F, 0x7F, 0x80...0x9F:         // C0, DEL, C1 controls
                continue
            case 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
                continue                                  // zero-width and bidirectional controls, separators, BOM
            default:
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." }) { return fallback }
        return clamp(trimmed)
    }

    /// At most `maxBytes` UTF-8 bytes at a scalar boundary, the extension (if short) kept.
    private static func clamp(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        let stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        var out = String.UnicodeScalarView()
        var bytes = 0
        for scalar in stem.unicodeScalars {
            let width = String(scalar).utf8.count
            if bytes + width > maxBytes - suffix.utf8.count { break }
            out.append(scalar)
            bytes += width
        }
        let result = String(out) + suffix
        return result.isEmpty ? fallback : result
    }
}
