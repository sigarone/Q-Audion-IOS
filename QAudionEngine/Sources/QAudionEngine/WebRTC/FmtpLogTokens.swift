import Foundation

/// W-NATIVESRTPFMTP (2026-09-26) — the fmtp part of the native-SRTP heartbeat
/// (`CallService`, `audiosrtp hb=1 ...`), built from the audio codec stats
/// row's `sdpFmtpLine`.
///
/// That string is the negotiated codec's fmtp line, i.e. text the PEER's SDP
/// controls. It used to be appended verbatim (`fmtp=minptime=10;useinbandfec=1`):
/// a nested `key=value;key=value` value that the log shipper's structured-shape
/// gate does not protect (the line gets masked or reduced), and arbitrary peer
/// text in the log. Now only flat `fmtp_<key>=<digits>` tokens are produced,
/// where the KEY is one of this file's own constants (every piece already in
/// the shipper's vocabulary) and the VALUE is 1-7 ASCII digits; unknown keys,
/// non-numeric or oversized values are dropped. No peer-chosen text can reach
/// the log. Same numeric-only discipline as ``AudioSdpSummary``, plus a key
/// allowlist (that type is internal and emits the peer's key names).
///
/// Pure string parsing, no WebRTC types.
public enum FmtpLogTokens {

    /// Opus fmtp parameters worth a heartbeat field, in output order.
    static let allowedKeys: [String] = [
        "minptime", "ptime", "maxptime", "useinbandfec", "cbr", "maxaveragebitrate",
    ]

    /// Longest value kept (Opus `maxaveragebitrate` tops out at 510000).
    static let maxValueDigits = 7

    /// Flat `fmtp_<key>=<digits>` tokens, in ``allowedKeys`` order, each key
    /// at most once (its first valid occurrence). Empty for `nil`, an empty
    /// line, or a line with nothing valid.
    public static func tokens(_ fmtpLine: String?) -> [String] {
        guard let fmtpLine, !fmtpLine.isEmpty else { return [] }
        var values: [String: String] = [:]
        for rawParam in fmtpLine.split(separator: ";") {
            let kv = rawParam.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key: String = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value: String = kv[1].trimmingCharacters(in: .whitespaces)
            guard allowedKeys.contains(key), values[key] == nil, isShortAsciiNumber(value) else { continue }
            values[key] = value
        }
        var out: [String] = []
        for key in allowedKeys {
            guard let value = values[key] else { continue }
            out.append("fmtp_\(key)=\(value)")
        }
        return out
    }

    /// 1...``maxValueDigits`` characters, each an ASCII digit `0`-`9`
    /// (`Character.isNumber` would also accept non-ASCII numerals).
    private static func isShortAsciiNumber(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maxValueDigits else { return false }
        return scalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }
}
