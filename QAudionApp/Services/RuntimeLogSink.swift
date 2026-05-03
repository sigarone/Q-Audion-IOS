import Foundation
import os

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

    /// Bumped every time `record` adds a new line so SwiftUI views
    /// observing this sink re-render. Cheap monotonic counter.
    @Published public private(set) var entryCount: Int = 0

    /// Mirror to OSLog so Console.app on a connected Mac (when
    /// available) sees the same lines. Subsystem matches the bundle
    /// id so a developer can filter on `process == QAudionApp`.
    private let osLogger = Logger(subsystem: "com.qaudion.app", category: "runtime")

    private init() {}

    public func record(level: Level, tag: String, _ message: String) {
        let entry = Entry(timestamp: Date(), level: level, tag: tag, message: message)
        lock.lock()
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
