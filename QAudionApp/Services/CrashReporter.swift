import Foundation
import MachO
import QAudionEngine

/// W472 — lightweight in-app native-crash catcher.
///
/// Why this exists: the iOS test devices are NOT USB-connected to a
/// debugger, and the W417 live telemetry only captures `stdout`. A
/// native crash — a POSIX signal (EXC_BAD_ACCESS → SIGSEGV/SIGBUS), a
/// Swift trap (force-unwrap nil, out-of-bounds, `precondition` →
/// SIGTRAP/SIGILL), or an uncaught `NSException` (→ SIGABRT) — kills
/// the process WITHOUT writing a single stdout line, so the telemetry
/// shows only a session-UUID change with no cause. The iPhone-side
/// "crashes immediately on a call" bug is exactly this: invisible.
///
/// This installs an uncaught-exception handler plus POSIX signal
/// handlers that persist a backtrace to a file in Caches. On the NEXT
/// launch `flushPendingReport()` prints that file line-by-line — which
/// the W417 stdout tee then ships to the server. One reproduction of
/// the crash therefore makes the stack trace appear in the telemetry.
///
/// This is deliberately NOT a full crash-reporting SDK. The signal
/// handlers are best-effort: `Thread.callStackSymbols` is not strictly
/// async-signal-safe (it mallocs), but for a logic crash — which is
/// not inside the allocator — it completes fine, and that is enough to
/// identify the crashing function. After persisting, the handler
/// restores the default disposition and re-raises so the OS still
/// produces its normal crash report (for App Store Connect too).
enum CrashReporter {

    /// Absolute path of the persisted-crash file. Computed ONCE here so
    /// the signal handler never has to call `NSSearchPathForDirectories`
    /// (a syscall) from an async-signal context.
    private static let reportPath: String = {
        let base = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("qaudion-last-crash.txt")
    }()

    /// W574j — set by the uncaught-NSException handler. An NSException aborts
    /// via SIGABRT, so the signal handler fires too; without this flag it
    /// overwrote the exception report (name + REASON — e.g. AVFAudio
    /// "required condition is false: …") with the bare signal stack, losing
    /// the one line that pinpoints the crash. The signal handler now skips
    /// persisting when an exception report is already in flight.
    private static var exceptionInFlight = false

    /// W-CRASHTELEMETRY (this task) — the CRASHED build's version, computed
    /// ONCE up front (same "force the lazy path computation up-front" style
    /// as `reportPath` above) so the signal handler never has to touch
    /// `Bundle.main.infoDictionary` from an async-signal context.
    private static let capturedAppVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }()

    /// W-CRASHTELEMETRY (this task) — three small scalars captured at crash
    /// time for the `app.crash` telemetry event this task adds, kept in
    /// UserDefaults (like `crashCount` below) rather than in the persisted
    /// TEXT report: the text file's exact shape is locked in by
    /// `flushPendingReport()`'s stdout-tee consumers (symbolicate.py, the
    /// log shipper's fixtures) and this task adds no new required line to
    /// it. `pendingCrashTsKey`/`pendingAppVerKey` capture the CRASHED
    /// build's version and wall-clock time (may differ from the CURRENT
    /// build/time once the app relaunches, possibly after an update);
    /// `pendingThreadKey` records whether the crash happened on the main
    /// thread (`Thread.isMainThread` is a cheap, async-signal-safe read —
    /// no different in risk from the UserDefaults writes this function
    /// already does for `crashCount`).
    private static let pendingAppVerKey = "qaudion.crash.pending_app_ver"
    private static let pendingCrashTsKey = "qaudion.crash.pending_ts_ms"
    private static let pendingThreadKey = "qaudion.crash.pending_thread"

    /// W-CRASHTELEMETRY (this task) — the size-capped `app.crash` attrs
    /// built (by `buildTelemetryAttrs(fromReportText:)`) from the PREVIOUS
    /// launch's crash report, held here from `flushPendingReport()` (which
    /// parses the report text BEFORE deleting the file — its only copy)
    /// until `AppState.initialize()` consumes it via
    /// `consumePendingCrashTelemetry()`. That consumer call sits right after
    /// `TelemetryService.shared.start(...)` deliberately: `TelemetryService
    /// .emit()` silently drops an event until `started` flips true, and
    /// `.onAppear` calls `flushPendingReport()` BEFORE `appState.initialize()`
    /// runs — emitting straight from here would race that ordering and lose
    /// the event on every launch that actually has one.
    private static var pendingCrashTelemetryAttrs: [String: Any]?

    /// Install the handlers. Call as early as possible (App.init) —
    /// before any code that might crash. Does NOT flush; the flush has
    /// to wait until the stdout tee is attached (see `flushPendingReport`).
    static func installHandlers() {
        _ = reportPath  // force the lazy path computation up-front

        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.exceptionInFlight = true
            var report = "=== QAUDION CRASH — NSException ===\n"
            report += "name: " + exception.name.rawValue + "\n"
            report += "reason: " + (exception.reason ?? "(nil)") + "\n"
            report += "stack:\n"
            report += exception.callStackSymbols.joined(separator: "\n")
            CrashReporter.persist(report)
        }

        let signalHandler: @convention(c) (Int32) -> Void = { sig in
            // An uncaught NSException aborts via SIGABRT, firing this handler
            // too. If the exception handler already persisted a report (with
            // name + reason), do NOT overwrite it with the bare signal stack —
            // the reason is what identifies the failure.
            if !CrashReporter.exceptionInFlight {
                CrashReporter.persistSignalReport(sig)
            }
            // Restore the default disposition and re-raise so the OS
            // still records its own crash report and the process dies.
            signal(sig, SIG_DFL)
            raise(sig)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, signalHandler)
        }
    }

    /// W-NATIVESRTPCRASHGUARD (this task) — peek only: does a crash report
    /// from the PREVIOUS launch exist? Unlike `flushPendingReport()`, this
    /// does NOT print or delete it — it must be callable from
    /// `QAudionApp.init()`, BEFORE the stdout tee is attached (whose
    /// absence is exactly why `flushPendingReport()` has to wait until
    /// `.onAppear`), so the crash-streak check that reads this can run
    /// ahead of any call path per spec section B's ordering requirement.
    static func hasPendingCrashReport() -> Bool {
        guard let data = FileManager.default.contents(atPath: reportPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return !text.isEmpty
    }

    /// Print any crash report left by the previous launch so the W417
    /// stdout tee uploads it, then delete the file. MUST be called
    /// AFTER `RuntimeLogSink.attachStdoutTee()` — otherwise the prints
    /// happen before the tee and are never captured.
    static func flushPendingReport() {
        guard let data = FileManager.default.contents(atPath: reportPath),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }
        // W-CRASHTELEMETRY (this task) — parse+format BEFORE printing/deleting:
        // the text file below is the only copy of this report, and this is
        // the last point that has it. Best-effort: a report this parser
        // doesn't recognize (a future format change) still gets fully
        // flushed to the stdout tee below unaffected; it just yields no
        // `app.crash` telemetry event (`pendingCrashTelemetryAttrs` stays nil).
        pendingCrashTelemetryAttrs = buildTelemetryAttrs(fromReportText: text)
        print("[CrashReporter] ==== CRASH REPORT FROM PREVIOUS LAUNCH ====")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // CLAUDE.md §13 — build the String before the print call.
            let out: String = "[CrashReporter] " + String(line)
            print(out)
        }
        print("[CrashReporter] ==== END CRASH REPORT ====")
        try? FileManager.default.removeItem(atPath: reportPath)
    }

    /// W-CRASHTELEMETRY (this task) — one-shot consume of the `app.crash`
    /// attrs `flushPendingReport()` built (nil when there was no pending
    /// report, or it could not be parsed). Clears the stash so a second call
    /// in the same process — there is only ever one caller, `AppState
    /// .initialize()`, but SwiftUI's `.onAppear` can in principle re-fire —
    /// never double-emits the same crash.
    static func consumePendingCrashTelemetry() -> [String: Any]? {
        defer { pendingCrashTelemetryAttrs = nil }
        return pendingCrashTelemetryAttrs
    }

    // MARK: - Internals

    /// W-CRASHTELEMETRY (this task) — parses `text` (the just-read, not-yet-
    /// deleted report file) via `CrashReportTextParser`, combines it with the
    /// three scalars `persist()` captured in UserDefaults, and formats the
    /// result through `CrashTelemetryFormatter`. nil when `text` doesn't
    /// match the expected report shape (see that parser's own doc) — the
    /// stdout-tee flush around this call is unaffected either way.
    private static func buildTelemetryAttrs(fromReportText text: String) -> [String: Any]? {
        guard let parsed = CrashReportTextParser.parse(text) else { return nil }
        let appVer = UserDefaults.standard.string(forKey: pendingAppVerKey) ?? capturedAppVersion
        let crashTsMs = Int64(UserDefaults.standard.integer(forKey: pendingCrashTsKey))
        let thread = UserDefaults.standard.string(forKey: pendingThreadKey) ?? "unknown"
        // Consumed — a stale value must not leak into a LATER, unrelated
        // report (mirrors `CrashBreadcrumbs.clearCallContext()`'s own
        // "consumed whether or not it triggered anything" rationale).
        UserDefaults.standard.removeObject(forKey: pendingAppVerKey)
        UserDefaults.standard.removeObject(forKey: pendingCrashTsKey)
        UserDefaults.standard.removeObject(forKey: pendingThreadKey)
        let report = CrashTelemetryFormatter.Report(
            crashKind: parsed.crashKind,
            name: parsed.name,
            reason: parsed.reason,
            thread: thread,
            stackLines: parsed.stackLines,
            callContext: parsed.callContext,
            breadcrumbLines: parsed.breadcrumbLines,
            appVer: appVer,
            crashTsMs: crashTsMs
        )
        return CrashTelemetryFormatter.attributes(for: report)
    }

    private static func persistSignalReport(_ sig: Int32) {
        // CLAUDE.md §13 — incremental `+=` instead of one long `+` chain.
        var report = "=== QAUDION CRASH — signal "
        report += sig.description
        report += " (" + signalName(sig) + ") ===\n"
        // W574k — a Swift logic trap (force-unwrap nil, index out of range,
        // precondition, fatalError) raises SIGTRAP. The runtime writes its
        // pinpoint message ("Fatal error: … file X, line Y") to stderr AND to
        // the __DATA,__crash_info section BEFORE trapping. stderr is lost (the
        // async stdout/stderr tee can't drain the pipe before the process dies),
        // but the section is still in memory: read it here so the persisted
        // report names the exact crashing line — no dSYM needed.
        let fatal = swiftCrashInfoMessage()
        if !fatal.isEmpty {
            report += "fatal: "
            report += fatal
            report += "\n"
        }
        report += "stack:\n"
        report += Thread.callStackSymbols.joined(separator: "\n")
        persist(report)
    }

    /// Read the Swift runtime fatal-error message from every loaded image's
    /// `__DATA,__crash_info` (`crashreporter_annotations_t`: version, then the
    /// `message` and `message2` `char*` fields). This is the same annotation
    /// Apple's crash reporter surfaces as "Application Specific Information".
    /// Best-effort: only pointer reads + `getsectiondata`, adequate for a logic
    /// crash (which is not inside the allocator).
    private static func swiftCrashInfoMessage() -> String {
        var msgs: [String] = []
        let imageCount = _dyld_image_count()
        var i: UInt32 = 0
        while i < imageCount {
            defer { i += 1 }
            guard let hdr = _dyld_get_image_header(i) else { continue }
            let mh = UnsafeRawPointer(hdr).assumingMemoryBound(to: mach_header_64.self)
            var size: UInt = 0
            var data = getsectiondata(mh, "__DATA", "__crash_info", &size)
            if data == nil {
                data = getsectiondata(mh, "__DATA_DIRTY", "__crash_info", &size)
            }
            guard let sect = data, size >= 40 else { continue }
            let words = UnsafeRawPointer(sect).assumingMemoryBound(to: UInt64.self)
            // crashreporter_annotations_t: [0]=version [1]=message [4]=message2
            for idx in [1, 4] {
                let ptrVal = words[idx]
                guard ptrVal != 0,
                      let cstr = UnsafePointer<CChar>(bitPattern: UInt(ptrVal)) else { continue }
                let s = String(cString: cstr)
                if !s.isEmpty { msgs.append(s) }
            }
        }
        return msgs.joined(separator: " | ")
    }

    private static func persist(_ text: String) {
        // W-CRASHCRUMBS (this task) — append the call-context line and the
        // recent-log trail so a crash report answers "was this a
        // native-SRTP call, and what led up to it" without a second
        // reproduction. Same best-effort risk level this function already
        // accepted for `Thread.callStackSymbols` (not strictly
        // async-signal-safe, fine for a logic crash that is not itself
        // inside the allocator) — `lastCallContext()` is a plain
        // `UserDefaults` read (this function already does exactly that,
        // below, for `qaudion.crash_count`) and `snapshotForCrash()` uses
        // `NSLock.try()` so it can never block this handler.
        var full = text
        if let ctx = CrashBreadcrumbs.lastCallContext() {
            full += "\ncontext: " + ctx
        }
        let crumbs = CrashBreadcrumbs.snapshotForCrash()
        if !crumbs.isEmpty {
            full += "\nbreadcrumbs:\n" + crumbs.joined(separator: "\n")
        }
        guard let data = full.data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: reportPath))
        let crashKey = "qaudion.crash_count"
        let count = UserDefaults.standard.integer(forKey: crashKey) + 1
        UserDefaults.standard.set(count, forKey: crashKey)
        // W-CRASHTELEMETRY (this task) — three scalars the `app.crash`
        // telemetry event needs that the text file above deliberately does
        // NOT carry (see `pendingAppVerKey`'s own doc). Same risk level as
        // the `UserDefaults.set` two lines above; `Thread.isMainThread` and
        // `Date()` are both cheap, allocation-free reads.
        UserDefaults.standard.set(capturedAppVersion, forKey: pendingAppVerKey)
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000), forKey: pendingCrashTsKey)
        UserDefaults.standard.set(Thread.isMainThread ? "main" : "background", forKey: pendingThreadKey)
    }

    static var crashCount: Int { UserDefaults.standard.integer(forKey: "qaudion.crash_count") }
    static func resetCrashCount() { UserDefaults.standard.set(0, forKey: "qaudion.crash_count") }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default:      return "SIG?"
        }
    }
}
