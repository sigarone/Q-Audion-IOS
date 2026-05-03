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
        lock.lock()
        let seq = nextSeq
        nextSeq &+= 1
        let entry = Entry(seq: seq, timestamp: Date(), level: level, tag: tag, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            // Drop the oldest 10% in one shot so we don't pay the
            // O(n) array shift on every single append past the cap.
            entries.removeFirst(maxEntries / 10)
        }
        lock.unlock()
        // Mirror to OSLog for Console.app + retain the formatted
        // form so a future os_log_store snapshot picks it up too.
        switch level {
        case .debug: osLogger.debug("[\(tag, privacy: .public)] \(message, privacy: .public)")
        case .info:  osLogger.info("[\(tag, privacy: .public)] \(message, privacy: .public)")
        case .warn:  osLogger.warning("[\(tag, privacy: .public)] \(message, privacy: .public)")
        case .error: osLogger.error("[\(tag, privacy: .public)] \(message, privacy: .public)")
        }
        // Bump observable count on main (we're already @MainActor).
        entryCount &+= 1
    }

    /// Snapshot of the current buffer formatted for log export.
    /// One line per entry, ISO8601-ish timestamp, level, tag, body.
    public func snapshot() -> String {
        lock.lock()
        let copy = entries
        lock.unlock()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = String()
        out.reserveCapacity(copy.count * 200)
        for e in copy {
            out.append(f.string(from: e.timestamp))
            out.append(" ")
            out.append(e.level.rawValue.uppercased())
            out.append(" [")
            out.append(e.tag)
            out.append("] ")
            out.append(e.message)
            out.append("\n")
        }
        return out
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
                //    Console.app + Xcode still see the line.
                _ = write(self.origStdoutFd, buf, n)
                // 2) Parse + record into the ring buffer.
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
                    for line in lines {
                        let s = String(line)
                        Task { @MainActor [weak self] in
                            self?.record(level: .info, tag: "stdout", s)
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
