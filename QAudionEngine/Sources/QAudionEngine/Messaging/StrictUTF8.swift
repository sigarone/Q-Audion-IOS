import Foundation

/// Decoding of bytes that were decrypted into the text of a message, without the byte order mark being lost on the way.
///
/// `String(data:encoding: .utf8)` may drop a leading U+FEFF depending on the version of Foundation, and a body that begins with a byte order
/// mark is not a file message or a reply (WIRE_SPEC 12.7.1, 13.3: recognition is on the bytes as decrypted). If the mark were dropped when a
/// stored row is read back (or when a group frame is decrypted), a body that was shown as the text it is could become a reply or a file
/// message after a round trip through the disk. So the bytes are validated as UTF-8 and the string is then built by `String(decoding:)`,
/// which keeps U+FEFF as an ordinary scalar value.
public enum StrictUTF8 {

    /// The text of `data`, or `nil` when `data` is not valid UTF-8. A leading U+FEFF is kept.
    public static func string(from data: Data) -> String? {
        guard String(data: data, encoding: .utf8) != nil else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
