import Foundation

/// W-LIVELOGOFFMAIN (2026-09-21) — the wire shape of one W417 log chunk, moved out of
/// `LiveLogStreamer` UNCHANGED so it can be pinned by tests.
///
/// A server-side shipper (`ship-ios-logs.py`, `fetch-ios-live.py`) parses these blobs, so
/// the bytes matter and nothing here may drift:
///
///   line 1      a header JSON object (`type`, `session`, `model`, `brand`, `os`, `net`,
///               `metered`, `app_ver`)
///   line 2...   one JSON object per log line: `ts` (ISO-8601 with fractional seconds),
///               `lvl` (one letter), `tag`, `msg`
///   every line ends with "\n"
///
/// The file name is `qaudion-live-<userTag>-<bootSession>-<seq, zero padded to 6>.log`;
/// the server tags uploads with that `qaudion-live-` prefix as short-lived telemetry.
///
/// Redaction is NOT done here: callers pass `msg` already redacted.
public enum LiveLogBlob {

    /// Appended after a chunk that had to be cut to fit the cap.
    public static let truncationMarker: String = "\n[livelog-truncated]\n"

    /// Room kept for the marker when cutting: a truncated chunk is `maxBytes - 64` bytes
    /// of content plus the marker.
    public static let truncationReserveBytes: Int = 64

    /// JSON string escaping, exactly as the shipper always did it: backslash first, then
    /// quote, newline, carriage return, tab. Every other character passes through.
    public static func escapeJson(_ text: String) -> String {
        return text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// One log line. `timestamp` and `levelInitial` are used verbatim; `tag` and
    /// `message` are escaped.
    public static func jsonLine(timestamp: String,
                                levelInitial: String,
                                tag: String,
                                message: String) -> String {
        let escapedTag: String = escapeJson(tag)
        let escapedMessage: String = escapeJson(message)
        return "{\"ts\":\"\(timestamp)\",\"lvl\":\"\(levelInitial)\",\"tag\":\"\(escapedTag)\",\"msg\":\"\(escapedMessage)\"}"
    }

    /// The first line of every chunk. Values are used verbatim (they are device model,
    /// OS and app version strings and a UUID: no quoting hazards).
    public static func header(session: String,
                              model: String,
                              os: String,
                              net: String,
                              metered: Bool,
                              appVer: String) -> String {
        return "{\"type\":\"header\",\"session\":\"\(session)\",\"model\":\"\(model)\",\"brand\":\"Apple\",\"os\":\"\(os)\",\"net\":\"\(net)\",\"metered\":\(metered),\"app_ver\":\"\(appVer)\"}"
    }

    /// Chunk bytes: header line, then the lines, each newline-terminated. If the result
    /// still exceeds `maxBytes` it is cut at `maxBytes - 64` and the truncation marker is
    /// appended. Callers pick `lines` with `linesByteBudget` so this only happens for a
    /// single line that is bigger than the whole cap.
    public static func chunkData(header: String, lines: [String], maxBytes: Int) -> Data {
        var body = String()
        body.reserveCapacity(lines.count * 220 + 256)
        body.append(header)
        body.append("\n")
        for line in lines {
            body.append(line)
            body.append("\n")
        }
        var data = Data()
        if let encoded = body.data(using: String.Encoding.utf8) {
            data = encoded
        }
        if data.count > maxBytes {
            let cap: Int = max(maxBytes - truncationReserveBytes, 0)
            let upper: Int = min(cap, data.count)
            let head: Data = data.subdata(in: 0..<upper)
            var combined: Data = head
            if let markerData = truncationMarker.data(using: String.Encoding.utf8) {
                combined.append(markerData)
            }
            data = combined
        }
        return data
    }

    /// How many bytes of log lines (each counted with its newline) fit in a chunk of at
    /// most `maxBytes` once `header` and its newline are in.
    public static func linesByteBudget(header: String, maxBytes: Int) -> Int {
        return max(maxBytes - header.utf8.count - 1, 0)
    }

    /// `qaudion-live-<userTag>-<session>-<seq padded to 6>.log`
    public static func filename(userTag: String, session: String, seq: Int) -> String {
        let padded: String = zeroPad(seq, width: 6)
        return "qaudion-live-\(userTag)-\(session)-\(padded).log"
    }

    public static func zeroPad(_ value: Int, width: Int) -> String {
        let digits: String = String(describing: value)
        if digits.count >= width { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}
