import Foundation

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

    /// Print any crash report left by the previous launch so the W417
    /// stdout tee uploads it, then delete the file. MUST be called
    /// AFTER `RuntimeLogSink.attachStdoutTee()` — otherwise the prints
    /// happen before the tee and are never captured.
    static func flushPendingReport() {
        guard let data = FileManager.default.contents(atPath: reportPath),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }
        print("[CrashReporter] ==== CRASH REPORT FROM PREVIOUS LAUNCH ====")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // CLAUDE.md §13 — build the String before the print call.
            let out: String = "[CrashReporter] " + String(line)
            print(out)
        }
        print("[CrashReporter] ==== END CRASH REPORT ====")
        try? FileManager.default.removeItem(atPath: reportPath)
    }

    // MARK: - Internals

    private static func persistSignalReport(_ sig: Int32) {
        // CLAUDE.md §13 — incremental `+=` instead of one long `+` chain.
        var report = "=== QAUDION CRASH — signal "
        report += sig.description
        report += " (" + signalName(sig) + ") ===\n"
        report += "stack:\n"
        report += Thread.callStackSymbols.joined(separator: "\n")
        persist(report)
    }

    private static func persist(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: reportPath))
    }

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
