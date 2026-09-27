import Foundation

/// W-MKCRASHTELEMETRY (this task) — pure formatting + local dedup for the ONE
/// `app.crash` telemetry event this app emits per MetricKit `MXCrashDiagnostic`
/// / `MXHangDiagnostic`, mirroring `CrashTelemetryFormatter`'s in-process
/// counterpart (`source` distinguishes the two: `"metrickit"` here,
/// `"in_process"` there — both share the SAME event `kind`, `"app.crash"`, so
/// a maintainer's dashboard can query one stream for either origin).
///
/// Kept OUT of `MetricKitDiagnostics` (QAudionApp, which imports the real
/// `MetricKit` framework and cannot be unit-tested without a device) so the
/// formatting/dedup RULES are testable on any platform: every input here is
/// a plain Swift value the caller already pulled out of the diagnostic
/// (`c.signal`, `c.exceptionType`, the parsed `callStackTree` frames, the
/// enclosing payload's window...) — this type never touches MetricKit.
public enum MetricKitCrashTelemetry {

    public static let kind: String = "app.crash"

    /// Distinguishes this MetricKit-sourced report from the in-process one
    /// (`CrashTelemetryFormatter.sourceInProcess`).
    public static let sourceMetricKit: String = "metrickit"

    public static let maxFrames: Int = 15

    /// Persisted-identifier cap — same order of magnitude as
    /// `CrashBreadcrumbs.capacity` purely so a maintainer reading both
    /// diagnostics stores sees comparably sized retention. MetricKit
    /// delivers at most once per 24h, so 30 slots is weeks of history —
    /// plenty to absorb a redelivered payload without growing unbounded.
    public static let maxReportedIdentifiers: Int = 30

    // MARK: - Crash

    public struct CrashInput {
        public let windowBeginMs: Int64
        public let windowEndMs: Int64
        public let appBuild: String
        public let osVersion: String
        public let signal: String
        public let exceptionType: String
        public let exceptionCode: String
        public let terminationReason: String
        /// Already formatted `"<binaryName> + <offset>"` lines, crashing-
        /// thread-first, in the SAME order `MetricKitDiagnostics`' own
        /// stdout summary walks `callStackTree` (root → leaf, depth-first).
        public let frames: [String]

        public init(windowBeginMs: Int64, windowEndMs: Int64, appBuild: String, osVersion: String,
                    signal: String, exceptionType: String, exceptionCode: String,
                    terminationReason: String, frames: [String]) {
            self.windowBeginMs = windowBeginMs
            self.windowEndMs = windowEndMs
            self.appBuild = appBuild
            self.osVersion = osVersion
            self.signal = signal
            self.exceptionType = exceptionType
            self.exceptionCode = exceptionCode
            self.terminationReason = terminationReason
            self.frames = frames
        }
    }

    /// A stable, LOCAL-ONLY identifier — never shipped to the server (see
    /// `attributes(for:)`, which does not include it) — used purely to dedup
    /// against the persisted `qaudion.metrickit.reportedCrashIds` list.
    /// MetricKit gives no id of its own, so this is built from the
    /// diagnostic's own fields plus the enclosing payload's delivery window
    /// (the closest thing to a timestamp a diagnostic carries).
    public static func identifier(for input: CrashInput) -> String {
        return ["crash", String(input.windowBeginMs), String(input.windowEndMs),
                input.appBuild, input.signal, input.exceptionType,
                input.exceptionCode, input.terminationReason].joined(separator: "|")
    }

    public static func attributes(for input: CrashInput) -> [String: Any] {
        let frames = CrashTelemetryBudget.cap(input.frames, maxCount: maxFrames, maxLineBytes: 200)
        let attrs: [String: Any] = [
            "source": sourceMetricKit,
            "crash_kind": "metrickit_crash",
            "signal": CrashTelemetryBudget.clip(input.signal, maxBytes: 40),
            "exception_type": CrashTelemetryBudget.clip(input.exceptionType, maxBytes: 40),
            "exception_code": CrashTelemetryBudget.clip(input.exceptionCode, maxBytes: 40),
            "termination_reason": CrashTelemetryBudget.clip(input.terminationReason, maxBytes: 300),
            "frame_count": input.frames.count,
            "frames": frames,
            "crash_app_ver": input.appBuild,
            "os_version": CrashTelemetryBudget.clip(input.osVersion, maxBytes: 40),
            "crash_ts_ms": input.windowEndMs
        ]
        return CrashTelemetryBudget.enforceTotalBudget(attrs, maxTotalBytes: CrashTelemetryFormatter.maxTotalAttrsBytes)
    }

    // MARK: - Hang

    public struct HangInput {
        public let windowBeginMs: Int64
        public let windowEndMs: Int64
        public let appBuild: String
        public let osVersion: String
        public let hangDurationMs: Int64
        /// Same `"<binaryName> + <offset>"` shape as `CrashInput.frames`,
        /// for the main thread at the moment of the hang
        /// (`MXHangDiagnostic.callStackTree` is the same shape as a crash's).
        public let frames: [String]

        public init(windowBeginMs: Int64, windowEndMs: Int64, appBuild: String, osVersion: String,
                    hangDurationMs: Int64, frames: [String]) {
            self.windowBeginMs = windowBeginMs
            self.windowEndMs = windowEndMs
            self.appBuild = appBuild
            self.osVersion = osVersion
            self.hangDurationMs = hangDurationMs
            self.frames = frames
        }
    }

    public static func identifier(for input: HangInput) -> String {
        let firstFrame = input.frames.first ?? ""
        return ["hang", String(input.windowBeginMs), String(input.windowEndMs),
                input.appBuild, String(input.hangDurationMs), firstFrame].joined(separator: "|")
    }

    public static func attributes(for input: HangInput) -> [String: Any] {
        let frames = CrashTelemetryBudget.cap(input.frames, maxCount: maxFrames, maxLineBytes: 200)
        let attrs: [String: Any] = [
            "source": sourceMetricKit,
            "crash_kind": "metrickit_hang",
            "hang_duration_ms": input.hangDurationMs,
            "frame_count": input.frames.count,
            "frames": frames,
            "crash_app_ver": input.appBuild,
            "os_version": CrashTelemetryBudget.clip(input.osVersion, maxBytes: 40),
            "crash_ts_ms": input.windowEndMs
        ]
        return CrashTelemetryBudget.enforceTotalBudget(attrs, maxTotalBytes: CrashTelemetryFormatter.maxTotalAttrsBytes)
    }

    // MARK: - Dedup

    /// Pure decision core: is `id` new against `existing` (oldest-first)?
    /// Returns whether to report it, and the list to persist afterward
    /// (`existing` unchanged when `id` was already present — nothing to
    /// report, nothing to write again; otherwise `existing + [id]`,
    /// FIFO-trimmed to `maxReportedIdentifiers`).
    public static func shouldReport(_ id: String, existing: [String]) -> (report: Bool, updated: [String]) {
        if existing.contains(id) {
            return (false, existing)
        }
        var updated = existing
        updated.append(id)
        if updated.count > maxReportedIdentifiers {
            updated.removeFirst(updated.count - maxReportedIdentifiers)
        }
        return (true, updated)
    }

    // MARK: - Persisted wrapper (UserDefaults-backed, same pattern as
    // CrashBreadcrumbs' `setCallContext`/`lastCallContext`)

    private static let reportedKey = "qaudion.metrickit.reportedCrashIds"

    /// Consults + records in one call: `true` when `id` had not been
    /// reported before (and is now persisted), `false` when it is a
    /// duplicate (nothing written — the caller must not emit again).
    ///
    /// Thread-safety: MetricKit's `didReceive` callbacks are documented by
    /// Apple to run serialized on ONE internal queue, never concurrently
    /// with each other, so a plain UserDefaults read-modify-write here
    /// (unlike `CrashBreadcrumbs`'s in-memory ring, which a SIGNAL HANDLER
    /// can reach at any instant) needs no additional lock.
    public static func markReportedIfNew(_ id: String) -> Bool {
        let existing = UserDefaults.standard.stringArray(forKey: reportedKey) ?? []
        let (report, updated) = shouldReport(id, existing: existing)
        if report {
            UserDefaults.standard.set(updated, forKey: reportedKey)
        }
        return report
    }

    /// Test-only: clears the persisted dedup set so one test's identifiers
    /// never leak into another's.
    static func resetReportedForTesting() {
        UserDefaults.standard.removeObject(forKey: reportedKey)
    }
}
