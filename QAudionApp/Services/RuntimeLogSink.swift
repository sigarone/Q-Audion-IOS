import Foundation
import os
import Darwin

/// W415 — in-memory ring buffer + helper API for app-side runtime
/// logging. Two goals:
///   1. Capture diagnostic context that the user can export from
///      Settings → Diagnostica when no Mac is connected to the iPhone
///      (the standard Console.app workflow assumes USB pairing).
///   2. Provide a single bottleneck (`RTLog.info/warn/error`) that
///      writes to BOTH the standard `os_log` system (for Console.app
///      when available) AND a process-local ring buffer that
///      DiagnosticsExportScreen can dump + upload to the server for
///      out-of-band analysis.
///
/// **Sizing:** 5000 lines × ~256 bytes ≈ 1.25 MB resident. Old
/// entries are evicted FIFO. The user's "Carica al server" action
/// snapshots the buffer into a UTF-8 .log file and POSTs via the
/// existing `/api/v1/files/upload`, returning a fileId the user can
/// share verbally so the maintainer pulls it via REST admin token.
@MainActor
public final class RuntimeLogSink: ObservableObject {

    public static let shared = RuntimeLogSink()

    public struct Entry: Identifiable {
        public let id = UUID()
        /// W417 — monotonic sequence number assigned at insert time.
        public let seq: Int64
        public let timestamp: Date
        public let level: Level
        public let tag: String
        public let message: String
    }

    public enum Level: String, Codable {
        case debug, info, warn, error

        var symbol: String {
            switch self {
            case .debug: return "🔵"
            case .info:  return "ℹ️"
            case .warn:  return "⚠️"
            case .error: return "❌"
            }
        }
    }

    private let maxEntries = 5000
    private let lock = NSLock()
    private var entries: [Entry] = []

    /// W417 — global monotonic counter incremented for every recorded
    /// entry. Independent from `entries.count` (FIFO eviction).
    private var nextSeq: Int64 = 1

    /// Bumped every time `record` adds a new line so SwiftUI views
    /// observing this sink re-render. Cheap monotonic counter.
    @Published public private(set) var entryCount: Int = 0

    /// Mirror to OSLog so Console.app on a connected Mac (when
    /// available) sees the same lines. Subsystem matches the bundle
    /// id so a developer can filter on `process == QAudionApp`.
    private let osLogger = Logger(subsystem: "com.qaudion.app", category: "runtime")

    private init() {}

    public func record(level: Level, tag: String, _ message: String) {
        // W-KEYSCRUB (2026-09-21) -- THE choke point for key material. Every line that enters the
        // app's log (RTLog from app code AND the stdout/stderr tee, i.e. whatever the native
        // library prints) passes here, so the ring, the on-screen viewer, the text export, the
        // bug-report tail, the live-log shipper, the OSLog mirror and `BugReporter.onError` only
        // ever see `safeMessage`. `LogRedactor` applies the same function again at every egress
        // (defence in depth). Cost on this (main) thread: one linear pass over the bytes of the
        // line, no allocation for a clean line (see `KeyMaterialScrubber`).
        let safeMessage: String = LogRedactor.scrubKeyMaterial(message)
        lock.lock()
        let seq = nextSeq
        nextSeq &+= 1
        let entry = Entry(seq: seq, timestamp: Date(), level: level, tag: tag, message: safeMessage)
        entries.append(entry)
        if entries.count > maxEntries {
            // Drop the oldest 10% in one shot so we don't pay the
            // O(n) array shift on every single append past the cap.
            entries.removeFirst(maxEntries / 10)
        }
        lock.unlock()
        // Mirror to OSLog for Console.app + retain the formatted
        // form so a future os_log_store snapshot picks it up too.
        // SECURITY M-20 — `.private` so Apple sysdiagnose / device
        // log captures redact tag+message as <private>, while a
        // developer attached via Console.app (or the in-app dump)
        // still sees the full text. Prevents inadvertent leak of
        // app-authored diagnostics through OS-level log collection.
        switch level {
        case .debug: osLogger.debug("[\(tag, privacy: .private)] \(safeMessage, privacy: .private)")
        case .info:  osLogger.info("[\(tag, privacy: .private)] \(safeMessage, privacy: .private)")
        case .warn:  osLogger.warning("[\(tag, privacy: .private)] \(safeMessage, privacy: .private)")
        case .error: osLogger.error("[\(tag, privacy: .private)] \(safeMessage, privacy: .private)")
        }
        // Bump observable count on main (we're already @MainActor).
        entryCount &+= 1
        // W559 — feed errors into the auto-detection window.
        if level == .error {
            BugReporter.shared.onError(tag: tag, message: safeMessage)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Snapshot of the current buffer formatted for log export.
    /// One line per entry, ISO8601-ish timestamp, level, tag, body.
    /// Every message goes through `redactStructured` (FIX-11, 2026-09-12):
    /// the export is shared by the user with support and the bug-report
    /// tail is uploaded; the incremental shipper (`LiveLogWorker`) already
    /// scrubbed, and the three egress paths must not differ in what they
    /// strip.
    public func snapshot() -> String {
        lock.lock()
        let copy = entries
        lock.unlock()
        var out = String()
        out.reserveCapacity(copy.count * 200)
        for e in copy {
            out.append(Self.isoFormatter.string(from: e.timestamp))
            out.append(" ")
            out.append(e.level.rawValue.uppercased())
            out.append(" [")
            out.append(e.tag)
            out.append("] ")
            out.append(RuntimeLogSink.redactStructured(e.message))
            out.append("\n")
        }
        return out
    }

    /// W559 — Returns the last `minutes` minutes of log entries as a
    /// plain-text string formatted as `[timestamp] [LEVEL] [tag] message`.
    /// Thread-safe; allocates a temporary copy of the ring buffer.
    public func recentLogsAsString(minutes: Double = 2.0) -> String {
        lock.lock()
        let copy = entries
        lock.unlock()
        let cutoff = Date().addingTimeInterval(-minutes * 60.0)
        let recent = copy.filter { $0.timestamp >= cutoff }
        var out = String()
        out.reserveCapacity(recent.count * 200)
        for e in recent {
            out.append(Self.isoFormatter.string(from: e.timestamp))
            out.append(" [")
            out.append(e.level.rawValue.uppercased())
            out.append("] [")
            out.append(e.tag)
            out.append("] ")
            out.append(RuntimeLogSink.redactStructured(e.message))
            out.append("\n")
        }
        return out
    }

    /// W-LIVELOGOFFMAIN (2026-09-21) -- raw, UNREDACTED read for `LiveLogStreamer`'s off-main
    /// worker (replaces `entriesSince`). This is the ONLY part of the shipper that has to touch
    /// the main actor, because the ring is main-actor state; it does the least possible there:
    /// under the lock it walks back from the newest entry to the first one the caller has not
    /// seen, so the cost is proportional to the NEW entries (typically a few dozen every 3 s),
    /// and copies at most `maxCount` of them. Redaction and JSON building, which used to run
    /// here for the WHOLE unshipped ring on every attempt, now happen on the worker.
    ///
    /// `skippedOlder` counts entries newer than `since` that were left out because more than
    /// `maxCount` were pending (the newest `maxCount` are returned, oldest-first): the worker
    /// records them as dropped instead of preparing lines it has no room for.
    func rawEntriesSince(seq since: Int64, maxCount: Int) -> LiveLogRawBatch {
        lock.lock()
        defer { lock.unlock() }
        var firstNew = entries.count
        while firstNew > 0 && entries[firstNew - 1].seq > since {
            firstNew -= 1
        }
        let available = entries.count - firstNew
        let take = min(available, max(maxCount, 0))
        var out: [LiveLogRawEntry] = []
        out.reserveCapacity(take)
        var index = entries.count - take
        while index < entries.count {
            let e = entries[index]
            out.append(LiveLogRawEntry(seq: e.seq,
                                       timestamp: e.timestamp,
                                       level: e.level.rawValue,
                                       tag: e.tag,
                                       message: e.message))
            index += 1
        }
        return LiveLogRawBatch(entries: out, skippedOlder: available - take)
    }

    /// Drop everything. Used by Settings → "Pulisci log".
    public func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
        entryCount = 0
    }

    /// View-side accessor. SwiftUI list reads this; `entryCount`
    /// drives invalidation so we don't leak the lock.
    public var snapshotEntries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    // MARK: - W416 stdout/stderr tee

    /// Holds the duplicated original stdout fd so we can keep
    /// forwarding to Console.app after we redirect to the pipe.
    private var origStdoutFd: Int32 = -1
    private var origStderrFd: Int32 = -1
    private var stdoutPipeSource: DispatchSourceRead?
    private var teeAttached: Bool = false

    // W-LIVELOGOFFMAIN (2026-09-21) -- the redactors (SECURITY H-2 stdout-tee scrub and the
    // P2 fail-closed EGRESS scrub) now live, unchanged, in `LogRedactor`, which is not
    // main-actor isolated: the log shipper's worker runs them off the main thread. These
    // forwards keep every existing call site exactly as it was, on the one implementation.
    private static func redact(_ line: String) -> String {
        return LogRedactor.redact(line)
    }

    /// P2 EGRESS redactor, also reused by `TelemetryService.emit()` so the
    /// structured-event path gets the SAME fail-closed scrub as the text
    /// path before `sealBatch`. Exposed (public) for that second egress;
    /// the implementation and its UNCONDITIONAL nature are unchanged (see
    /// `LogRedactor.redactStructured`).
    public static func redactStructured(_ line: String) -> String {
        return LogRedactor.redactStructured(line)
    }

    /// W416 — capture every `print(...)` (stdlib, third-party, OS-level
    /// stderr noise) into the ring buffer too, so the user doesn't have
    /// to hand-convert ~100 existing print sites to RTLog. Idempotent.
    ///
    /// **How:** create an unnamed pipe, dup2 STDOUT_FILENO + STDERR_FILENO
    /// onto its write end, then in a background DispatchSourceRead
    /// loop read from the read end and:
    ///   1. write the bytes back to the SAVED original stdout/stderr fd
    ///      → Console.app + Xcode console still see everything as before;
    ///   2. parse the chunk as UTF-8 lines and `record(...)` each one
    ///      with tag "stdout" so the buffer + diagnostic dump capture
    ///      every line that any code path emits.
    ///
    /// **Cost:** ≈ 4KB transient buffer per read, one background
    /// dispatch source per process. No measurable overhead at typical
    /// log rates (< 100 lines/s).
    ///
    /// **Always-on:** `QAudionApp.onAppear` calls this once at launch.
    /// Combined with the FIFO ring buffer eviction (oldest 10% dropped
    /// when capacity exceeded), the system stays bounded — after 50
    /// telephone calls the buffer simply wraps over, never grows.
    public func attachStdoutTee() {
        guard !teeAttached else { return }
        var pipeFds = [Int32](repeating: 0, count: 2)
        guard pipe(&pipeFds) == 0 else {
            print("[RuntimeLogSink] pipe() failed errno=\(errno)")
            return
        }
        let readFd = pipeFds[0]
        let writeFd = pipeFds[1]

        // Save originals so the tee can forward to Console.app/Xcode.
        origStdoutFd = dup(STDOUT_FILENO)
        origStderrFd = dup(STDERR_FILENO)

        // Redirect both streams to the pipe write end.
        dup2(writeFd, STDOUT_FILENO)
        dup2(writeFd, STDERR_FILENO)
        close(writeFd)

        // Disable stdout buffering so prints surface promptly.
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        let queue = DispatchQueue(label: "qaudion.runtime.stdout-tee", qos: .utility)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(readFd, &buf, buf.count)
            if n > 0 {
                // 1) Forward to the saved original stdout/stderr so
                //    Console.app + Xcode still see the line. W-KEYSCRUB: this raw
                //    byte forward is the ONE consumer that is deliberately not scrubbed
                //    (chunks are cut at arbitrary bytes, and it goes to the developer
                //    console of an attached debugger, never to a file, the ring or the
                //    network); the parsed lines below are scrubbed by `redact` and `record`.
                _ = write(self.origStdoutFd, buf, n)
                // 2) Parse + record into the ring buffer.
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
                    for line in lines {
                        // SECURITY H-2 — scrub obvious secrets out of
                        // captured stdout/stderr BEFORE they enter the
                        // ring buffer (which can be uploaded by the
                        // diagnostics dump). Redaction runs off-main.
                        // W-KEYSCRUB: `redact` starts with the key-material scrub,
                        // so the key bytes are already gone before the hop to the
                        // main actor; `record` scrubs once more (idempotent).
                        let safe: String = RuntimeLogSink.redact(String(line))
                        Task { @MainActor [weak self] in
                            self?.record(level: .info, tag: "stdout", safe)
                        }
                    }
                }
            }
        }
        source.setCancelHandler {
            close(readFd)
        }
        source.resume()
        stdoutPipeSource = source
        teeAttached = true
        // Confirm via OSLog so even if stdout gets weird the wiring
        // is visible in Console.app.
        osLogger.info("[RuntimeLogSink] stdout/stderr tee attached")
    }

    /// Detach the stdout tee. Mostly for tests — production app
    /// keeps it attached for the process lifetime.
    public func detachStdoutTee() {
        guard teeAttached else { return }
        if origStdoutFd >= 0 { dup2(origStdoutFd, STDOUT_FILENO); close(origStdoutFd); origStdoutFd = -1 }
        if origStderrFd >= 0 { dup2(origStderrFd, STDERR_FILENO); close(origStderrFd); origStderrFd = -1 }
        stdoutPipeSource?.cancel()
        stdoutPipeSource = nil
        teeAttached = false
    }
}

/// Convenience global facade. Call `RTLog.info(...)` from any
/// production code path; it routes to `RuntimeLogSink.shared` on
/// MainActor (Task hop when off-main).
public enum RTLog {
    public static func debug(_ tag: String, _ message: String) { dispatch(.debug, tag, message) }
    public static func info (_ tag: String, _ message: String) { dispatch(.info,  tag, message) }
    public static func warn (_ tag: String, _ message: String) { dispatch(.warn,  tag, message) }
    public static func error(_ tag: String, _ message: String) { dispatch(.error, tag, message) }

    private static func dispatch(_ level: RuntimeLogSink.Level, _ tag: String, _ message: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                RuntimeLogSink.shared.record(level: level, tag: tag, message)
            }
        } else {
            Task { @MainActor in
                RuntimeLogSink.shared.record(level: level, tag: tag, message)
            }
        }
    }
}
