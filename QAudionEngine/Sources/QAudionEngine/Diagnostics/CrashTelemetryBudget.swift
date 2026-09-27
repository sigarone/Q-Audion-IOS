import Foundation

/// W-CRASHTELEMETRY (this task) — small, shared size-budget helpers for the
/// `app.crash` telemetry event, used by both `CrashTelemetryFormatter` (the
/// in-process `CrashReporter` crash) and `MetricKitCrashTelemetry` (MetricKit
/// crash/hang diagnostics). Pure: no I/O, no framework beyond `Foundation`'s
/// `JSONSerialization` (used only to MEASURE a candidate attrs dict's encoded
/// size — never to build the event actually sent, which stays
/// `TelemetryEvent.toJSONLLine()`'s job in QAudionApp).
///
/// Why a shared budget at all: `TelemetryService.maxBatchBytes` (16 KiB) caps
/// the WHOLE batch, not one event, and `flushOnce()` simply `break`s the
/// JSONL-accumulation loop the moment the NEXT line would not fit — it does
/// not skip an oversized line and try the next one. A single `app.crash`
/// event anywhere near that cap would therefore starve every other buffered
/// event (including the very next `app.crash`) forever. The server's own
/// per-record cap (`telemetryEventCap`, 32 KiB) is even less forgiving: an
/// over-cap JSONL line is silently dropped. Both formatters stay far under
/// both ceilings by construction.
enum CrashTelemetryBudget {

    /// `lines`, trimmed to at most `maxCount` entries (the FIRST `maxCount`
    /// by default, or the LAST `maxCount` when `keepTail` — for a ring
    /// buffer stored oldest-first, `keepTail` keeps the MOST RECENT ones,
    /// which is what a crash report's breadcrumb trail wants), each
    /// individually capped to `maxLineBytes`.
    static func cap(_ lines: [String], maxCount: Int, maxLineBytes: Int, keepTail: Bool = false) -> [String] {
        guard maxCount > 0 else { return [] }
        let source = keepTail ? Array(lines.suffix(maxCount)) : Array(lines.prefix(maxCount))
        return source.map { clip($0, maxBytes: maxLineBytes) }
    }

    /// `s`, truncated so its UTF-8 byte count does not exceed `maxBytes`.
    /// Matches `CrashBreadcrumbs.add`'s own approximation (checks the UTF-8
    /// count, truncates by CHARACTER count) — adequate for the ASCII-
    /// dominant diagnostic text this feeds on, and never split mid-scalar
    /// the way a raw byte-offset truncation could.
    static func clip(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        return String(s.prefix(maxBytes))
    }

    /// `attrs`, shrunk (breadcrumbs dropped oldest-first, then frames
    /// trimmed from the end) until its JSON encoding is at or under
    /// `maxTotalBytes`, or until there is nothing left to shrink. Never
    /// fails: a dict this can't JSON-encode (never happens for the
    /// String/Int/Int64/[String] values the two formatters build) is
    /// treated as already within budget rather than thrown away.
    static func enforceTotalBudget(_ attrs: [String: Any], maxTotalBytes: Int) -> [String: Any] {
        var out = attrs
        guard let size = jsonByteCount(out), size > maxTotalBytes else { return out }

        if var crumbs = out["breadcrumbs"] as? [String], !crumbs.isEmpty {
            while !crumbs.isEmpty {
                crumbs.removeFirst()
                if crumbs.isEmpty {
                    out.removeValue(forKey: "breadcrumbs")
                } else {
                    out["breadcrumbs"] = crumbs
                }
                if let s = jsonByteCount(out), s <= maxTotalBytes { return out }
            }
        }

        if var frames = out["frames"] as? [String], !frames.isEmpty {
            while frames.count > 1 {
                frames.removeLast()
                out["frames"] = frames
                if let s = jsonByteCount(out), s <= maxTotalBytes { return out }
            }
        }

        return out
    }

    private static func jsonByteCount(_ obj: [String: Any]) -> Int? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: obj))?.count
    }
}
