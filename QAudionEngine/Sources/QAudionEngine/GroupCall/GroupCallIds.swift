import Foundation

/// Call ids and user ids of group calls, compared and encoded the one way every platform does
/// (GROUP_CALLS_V2 2.7, Parity rules). Every platform mints call ids in lower case, this one included
/// (`BCryptoGroupCallManager.createCall`); an id that arrives in another spelling (the 1:1 call table
/// returns `promoted_from_call_id` in its own) still names the same call, so no two ids are ever
/// compared with `==`: they are compared ASCII case-insensitively.
public enum GroupCallIds {

    /// The bytes of `text` with A-Z mapped to a-z. Nothing else changes: this is ASCII folding,
    /// not Unicode case mapping.
    public static func lowerBytes(_ text: String) -> [UInt8] {
        return text.utf8.map { byte -> UInt8 in
            (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
        }
    }

    /// `text` with A-Z mapped to a-z.
    public static func lower(_ text: String) -> String {
        return String(decoding: lowerBytes(text), as: UTF8.self)
    }

    /// ASCII case-insensitive equality (`ieq` of the spec).
    public static func ieq(_ first: String, _ second: String) -> Bool {
        return lowerBytes(first) == lowerBytes(second)
    }

    /// `ieq` of ids that may be absent (false when either is).
    public static func ieq(_ first: String?, _ second: String?) -> Bool {
        guard let first = first, let second = second else { return false }
        return ieq(first, second)
    }

    /// Whether `ids` holds `id` under `ieq`.
    public static func contains(_ ids: [String], _ id: String) -> Bool {
        let wanted = lowerBytes(id)
        return ids.contains { lowerBytes($0) == wanted }
    }

    /// A UUID in canonical form: 36 ASCII characters, lower-case hex groups of 8-4-4-4-12. Any
    /// version nibble is accepted.
    public static func isCanonical(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                if byte != 0x2D { return false }
            } else if !((byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)) {
                return false
            }
        }
        return true
    }

    /// The canonical form of `text` (A-Z mapped to a-z), or nil when it is not a UUID after that.
    public static func canonical(_ text: String) -> String? {
        let mapped = lower(text)
        return isCanonical(mapped) ? mapped : nil
    }

    /// The first 8 characters, the form ids take in a log line.
    public static func short(_ text: String) -> String {
        return String(text.prefix(8))
    }
}
