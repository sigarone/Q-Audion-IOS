import Foundation

/// W-CRASHTELEMETRY (this task) — parses the EXACT text `CrashReporter.persist()`
/// (QAudionApp) writes to `qaudion-last-crash.txt`, so the new `app.crash`
/// telemetry event can be built from the SAME report `flushPendingReport()`
/// already prints to the W417 stdout tee, without a second persisted copy of
/// the stack/breadcrumbs text. Kept here (QAudionEngine) so the format
/// contract is unit-testable without a signal handler, `NSException`, or a
/// device — every input is a plain `String` the caller already read off disk.
///
/// Format written by `CrashReporter` (UNCHANGED by this task — every line
/// below already existed; this parser adds no new required line, so a crash
/// report from a build that predates this task still parses):
///
///   === QAUDION CRASH — NSException ===
///   name: <exception name>
///   reason: <exception reason>
///   stack:
///   <frame>
///   <frame>
///   ...
///   context: <call-context line>          (present only when a call was up)
///   breadcrumbs:                          (present only when the ring had
///   <line>                                 at least one line)
///   ...
///
/// or, for a POSIX signal:
///
///   === QAUDION CRASH — signal <N> (<NAME>) ===
///   fatal: <Swift-runtime crash-info message>   (present only when non-empty)
///   stack:
///   <frame>
///   ...
///   context: ...                          (optional, as above)
///   breadcrumbs:                          (optional, as above)
///   ...
public enum CrashReportTextParser {

    public struct ParsedReport: Equatable {
        /// `"nsexception"` or `"signal"`.
        public let crashKind: String
        /// The exception name, or the signal's symbolic name (`"SIGSEGV"`).
        public let name: String
        /// The exception reason, or the Swift-runtime `fatal:` message.
        /// Empty when the report carried neither.
        public let reason: String
        public let stackLines: [String]
        public let callContext: String?
        public let breadcrumbLines: [String]
    }

    private static let headerPrefix = "=== QAUDION CRASH"
    private static let nameLinePrefix = "name: "
    private static let reasonLinePrefix = "reason: "
    private static let fatalLinePrefix = "fatal: "
    private static let stackLine = "stack:"
    private static let contextLinePrefix = "context: "
    private static let breadcrumbsLine = "breadcrumbs:"

    /// nil when `text` does not start with the header this app writes — a
    /// foreign/corrupt/future-format file simply yields no telemetry event;
    /// the stdout-tee flush that reads the SAME file independently is
    /// unaffected either way (best-effort, matches this file family's own
    /// stated risk tolerance).
    public static func parse(_ text: String) -> ParsedReport? {
        if text.isEmpty { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.first, header.hasPrefix(headerPrefix) else { return nil }

        var crashKind = "signal"
        var name = ""
        if header.contains("NSException") {
            crashKind = "nsexception"
        } else if let sig = parseSignalName(fromHeader: header) {
            crashKind = "signal"
            name = sig
        }

        var idx = 1
        var reason = ""
        if crashKind == "nsexception" {
            if idx < lines.count, lines[idx].hasPrefix(nameLinePrefix) {
                name = String(lines[idx].dropFirst(nameLinePrefix.count))
                idx += 1
            }
            if idx < lines.count, lines[idx].hasPrefix(reasonLinePrefix) {
                reason = String(lines[idx].dropFirst(reasonLinePrefix.count))
                idx += 1
            }
        } else if idx < lines.count, lines[idx].hasPrefix(fatalLinePrefix) {
            reason = String(lines[idx].dropFirst(fatalLinePrefix.count))
            idx += 1
        }

        guard idx < lines.count, lines[idx] == stackLine else { return nil }
        idx += 1

        var stackLines: [String] = []
        while idx < lines.count, lines[idx] != breadcrumbsLine, !lines[idx].hasPrefix(contextLinePrefix) {
            stackLines.append(lines[idx])
            idx += 1
        }

        var callContext: String?
        if idx < lines.count, lines[idx].hasPrefix(contextLinePrefix) {
            callContext = String(lines[idx].dropFirst(contextLinePrefix.count))
            idx += 1
        }

        var breadcrumbLines: [String] = []
        if idx < lines.count, lines[idx] == breadcrumbsLine {
            idx += 1
            if idx < lines.count {
                breadcrumbLines = Array(lines[idx...])
            }
        }

        return ParsedReport(crashKind: crashKind, name: name, reason: reason,
                             stackLines: stackLines, callContext: callContext,
                             breadcrumbLines: breadcrumbLines)
    }

    /// Extracts `<NAME>` out of a header line
    /// `"=== QAUDION CRASH — signal <N> (<NAME>) ==="`. nil when the header
    /// has no parenthesized group (the caller only reaches this once the
    /// `NSException` header shape was already ruled out).
    private static func parseSignalName(fromHeader header: String) -> String? {
        guard let openParen = header.lastIndex(of: "("),
              let closeParen = header.lastIndex(of: ")"),
              openParen < closeParen else { return nil }
        let name = header[header.index(after: openParen)..<closeParen]
        return name.isEmpty ? nil : String(name)
    }
}
