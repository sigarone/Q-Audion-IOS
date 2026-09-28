import Foundation

/// W-CRASHTELEMETRY (this task) — pure formatting for the `app.crash`
/// telemetry event built from an in-process `CrashReporter` report (a POSIX
/// signal or an uncaught `NSException`).
///
/// Kept OUT of `CrashReporter` (QAudionApp) so it is unit-testable without a
/// device or a signal-handler context: every input here is a plain Swift
/// value the caller already extracted (via `CrashReportTextParser`, plus its
/// own `Bundle`/`Date`/`Thread` reads) — this type never touches a file, a
/// signal or a thread.
///
/// Size discipline matches the server audit for `POST
/// /api/v1/telemetry/batch` this task's spec is built on: the server's
/// per-record cap is 32 KiB and this client's own per-BATCH cap
/// (`TelemetryService.maxBatchBytes`) is 16 KiB shared with every other
/// buffered event (including the `app.launch` marker emitted moments
/// before this one) — `maxTotalAttrsBytes` keeps one `app.crash` record
/// far under both, with a wide margin, matching the bcrypto-server audit's
/// own "~8 KB used, ~4x margin" estimate.
public enum CrashTelemetryFormatter {

    public static let kind: String = "app.crash"

    /// Distinguishes this in-process report from the MetricKit-sourced one
    /// (`MetricKitCrashTelemetry.sourceMetricKit`) in the shared `app.crash`
    /// event stream.
    public static let sourceInProcess: String = "in_process"

    public static let maxFrames: Int = 15
    static let maxFrameLineBytes: Int = 200
    public static let maxBreadcrumbs: Int = 20
    static let maxBreadcrumbLineBytes: Int = 180
    static let maxNameBytes: Int = 120
    static let maxReasonBytes: Int = 300

    /// Hard ceiling on the whole attrs payload once JSON-encoded. See the
    /// type doc for why this stays far under both server-side caps.
    public static let maxTotalAttrsBytes: Int = 8 * 1024

    /// One in-process crash report's fields, already parsed out of
    /// `CrashReporter`'s persisted text (`CrashReportTextParser`) plus the
    /// three scalars `CrashReporter` captures separately at crash time
    /// (`appVer`, `crashTsMs`, `thread` — kept out of the text file so its
    /// format stays byte-for-byte unchanged for the stdout-tee flush and the
    /// log shipper's locked-in fixtures).
    public struct Report {
        /// `"nsexception"` or `"signal"`.
        public let crashKind: String
        /// Exception name, or the signal's symbolic name (`"SIGSEGV"`).
        public let name: String
        /// Exception reason, or the Swift-runtime `fatal:` message. May be empty.
        public let reason: String
        /// `"main"` or `"background"` — the thread `CrashReporter`'s
        /// handler ran on, which is the crashing thread (the handler runs
        /// synchronously, in-process, on it).
        public let thread: String
        /// Full (uncapped) stack, oldest-format-unchanged from
        /// `Thread.callStackSymbols`/`NSException.callStackSymbols`.
        public let stackLines: [String]
        /// `CrashBreadcrumbs.lastCallContext()` at crash time, if any.
        public let callContext: String?
        /// `CrashBreadcrumbs.snapshotForCrash()` at crash time, oldest first.
        public let breadcrumbLines: [String]
        /// The CRASHED build's version — may differ from the CURRENT build
        /// if the app was updated between the crash and this launch, which
        /// is exactly why this rides in `attrs` instead of relying on the
        /// telemetry envelope's own (current-build) `app_ver` field.
        public let appVer: String
        public let crashTsMs: Int64

        public init(crashKind: String, name: String, reason: String, thread: String,
                    stackLines: [String], callContext: String?, breadcrumbLines: [String],
                    appVer: String, crashTsMs: Int64) {
            self.crashKind = crashKind
            self.name = name
            self.reason = reason
            self.thread = thread
            self.stackLines = stackLines
            self.callContext = callContext
            self.breadcrumbLines = breadcrumbLines
            self.appVer = appVer
            self.crashTsMs = crashTsMs
        }
    }

    /// Builds the size-capped `attrs` dict for
    /// `TelemetryService.shared.emit(kind: "app.crash", attrs:)`. Never
    /// throws, never nil — a partial/degenerate report (empty stack, no
    /// context, no breadcrumbs) still yields a record rather than none.
    /// Sanitization of the OUTGOING values (redaction, JSON-safety) is
    /// `TelemetryService.emit`'s own job for every event kind, unconditional
    /// — this only bounds SIZE and shape.
    public static func attributes(for report: Report) -> [String: Any] {
        let frames = CrashTelemetryBudget.cap(report.stackLines, maxCount: maxFrames, maxLineBytes: maxFrameLineBytes)
        let crumbs = CrashTelemetryBudget.cap(report.breadcrumbLines, maxCount: maxBreadcrumbs,
                                              maxLineBytes: maxBreadcrumbLineBytes, keepTail: true)
        var attrs: [String: Any] = [
            "source": sourceInProcess,
            "crash_kind": report.crashKind,
            "name": CrashTelemetryBudget.clip(report.name, maxBytes: maxNameBytes),
            "reason": CrashTelemetryBudget.clip(report.reason, maxBytes: maxReasonBytes),
            "thread": report.thread,
            "frame_count": report.stackLines.count,
            "frames": frames,
            "crash_app_ver": report.appVer,
            "crash_ts_ms": report.crashTsMs
        ]
        if let ctx = report.callContext, !ctx.isEmpty {
            attrs["call_context"] = ctx
        }
        if !crumbs.isEmpty {
            attrs["breadcrumbs"] = crumbs
        }
        return CrashTelemetryBudget.enforceTotalBudget(attrs, maxTotalBytes: maxTotalAttrsBytes)
    }
}
