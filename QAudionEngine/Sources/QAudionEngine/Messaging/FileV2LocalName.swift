import Foundation
import CryptoKit

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

// MARK: - Where a received file lives on the device

/// The names and places of the local copies of v2 files: pure path arithmetic, so each rule has a test; the app creates the
/// directories and reads the files.
///
/// ```
/// <base>/files_v2/<row key>/<file name>        the decrypted file of a received row
/// <base>/files_v2/<row key>/thumb/thumb.jpg    its thumbnail (received, or made by the sender)
/// ```
///
/// A row key is the id of the message row (a UUID in a 1:1 chat) or of the group row (any string the group store keeps): it is
/// used as ONE path component, so it is cut to a safe form.
public enum FileV2LocalFiles {

    public static let rootDirectoryName = "files_v2"
    public static let thumbnailDirectoryName = "thumb"
    public static let thumbnailFileName = "thumb.jpg"

    /// The directory name of a row: the key itself when it is made of letters, digits and hyphens (a UUID is), else the first
    /// 32 hex characters of the SHA-256 of the key, prefixed `h-`; never empty, never longer than 64 characters.
    public static func directoryName(rowKey: String) -> String {
        let allowed = !rowKey.isEmpty && rowKey.utf8.count <= 64 && rowKey.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
        }
        if allowed { return rowKey }
        return "h-" + FileV2LocalFiles.sha256Prefix(rowKey)
    }

    /// `<base>/files_v2/<row key>`.
    public static func directory(base: URL, rowKey: String) -> URL {
        base.appendingPathComponent(rootDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName(rowKey: rowKey), isDirectory: true)
    }

    /// `<base>/files_v2/<row key>/thumb/thumb.jpg`.
    public static func thumbnailURL(base: URL, rowKey: String) -> URL {
        directory(base: base, rowKey: rowKey)
            .appendingPathComponent(thumbnailDirectoryName, isDirectory: true)
            .appendingPathComponent(thumbnailFileName, isDirectory: false)
    }

    /// The decrypted file of a row: `<base>/files_v2/<row key>/<file name>`.
    public static func fileURL(base: URL, rowKey: String, fileName: String) -> URL {
        directory(base: base, rowKey: rowKey).appendingPathComponent(fileName, isDirectory: false)
    }

    /// The name a received file is saved under: the peer's name made safe (`FileV2LocalName.sanitised`) and, when it has no
    /// extension, one taken from the mime type, so that the share sheet and the player know what the file is. A descriptor with
    /// no name gets one from its kind (`foto`, `video`, `nota-vocale`, `allegato`).
    public static func fileName(name: String?, mimeType: String?, kind: String) -> String {
        let base = FileV2LocalName.sanitised(name)
        let hasExtension = (base as NSString).pathExtension.isEmpty == false
        let missing = base == FileV2LocalName.fallback
        let ext = hasExtension && !missing ? "" : fileExtension(forMime: mimeType)
        if missing {
            let stem: String
            switch kind {
            case "image": stem = "foto"
            case "video": stem = "video"
            case "voice": stem = "nota-vocale"
            case "avatar": stem = "avatar"
            default: stem = base
            }
            return ext.isEmpty ? stem : stem + "." + ext
        }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// The extension of a mime type this app writes or plays; empty for any other.
    public static func fileExtension(forMime mimeType: String?) -> String {
        switch (mimeType ?? "").lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/webp": return "webp"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/mpeg": return "mp3"
        case "audio/ogg", "audio/opus": return "ogg"
        case "application/pdf": return "pdf"
        default: return ""
        }
    }

    /// The first 16 bytes of the SHA-256 of `text`, as 32 lowercase hex characters.
    private static func sha256Prefix(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
