import Foundation

/// Whether the app is currently in the background, readable from ANY queue.
///
/// The app layer updates it from `UIApplication.didEnterBackgroundNotification`
/// / `willEnterForegroundNotification` (and once at start-up); call-time code
/// that runs off the main thread (the RX analysis queue, timers) reads it to
/// skip work whose ONLY consumer is something drawn on screen. It is
/// deliberately a plain lock-guarded Bool: `UIApplication.applicationState`
/// is main-thread-only and must not be read from those queues.
///
/// Scope: display-only and diagnostic-only work. Anything that feeds a score,
/// a verdict or a network decision must NOT consult this flag.
public final class AppBackgroundFlag: @unchecked Sendable {
    public static let shared = AppBackgroundFlag()

    private let lock = NSLock()
    private var background = false

    public init() {}

    public var isInBackground: Bool {
        lock.lock(); defer { lock.unlock() }
        return background
    }

    public func set(isInBackground value: Bool) {
        lock.lock(); background = value; lock.unlock()
    }
}

/// Rate limiter for display-only work: runs at most once per `minIntervalNs`
/// while the app is in the foreground and never while it is in the
/// background. The caller supplies the clock, so the cadence is testable with
/// a fake one. Not thread-safe by itself: use it from one queue/thread, as the
/// work it gates already is.
public struct DisplayWorkGate: Sendable {
    public let minIntervalNs: UInt64
    private var lastRunNs: UInt64 = 0

    public init(minIntervalNs: UInt64) {
        self.minIntervalNs = minIntervalNs
    }

    /// True when the work should run now. In the background it returns false
    /// without touching the schedule, so the work resumes at the very next
    /// call after the app comes back to the foreground.
    public mutating func shouldRun(nowNs: UInt64, isInBackground: Bool) -> Bool {
        if isInBackground { return false }
        guard nowNs &- lastRunNs >= minIntervalNs else { return false }
        lastRunNs = nowNs
        return true
    }
}
