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
    private var observers: [UUID: @Sendable (Bool) -> Void] = [:]

    public init() {}

    public var isInBackground: Bool {
        lock.lock(); defer { lock.unlock() }
        return background
    }

    /// Returns true when the value actually changed (a repeated notification returns false).
    /// Observers are told after the lock is released, on the caller's thread, and only on a real change.
    @discardableResult
    public func set(isInBackground value: Bool) -> Bool {
        lock.lock()
        let changed = background != value
        background = value
        let toNotify = changed ? Array(observers.values) : []
        lock.unlock()
        for observer in toNotify { observer(value) }
        return changed
    }

    /// Registers a handler called on every real change of the flag, on the thread that sets it (the main
    /// thread in the app): keep it cheap and never block in it. Returns the id for `removeChangeObserver`.
    /// The flag is process-wide, so whoever registers must remove the handler when it stops needing it.
    public func addChangeObserver(_ handler: @escaping @Sendable (Bool) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        lock.unlock()
        return id
    }

    public func removeChangeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }
}

/// The log line that tells "display-only call work paused because the app went to the background" (bg=1) from
/// "ran and measured zero" (the voice-analysis counters, `va_sample`, `va_results`, `conf_poll` stop or read 0
/// while paused). One line when the work pauses, one when it resumes. The shape was checked against the phone-log
/// shipper's vocabulary gate (`scripts/test_ship_ios_display_vocab.py`): keep both in sync.
public enum DisplayWorkMarker {
    public static func line(background: Bool) -> String {
        "display bg=\(background ? 1 : 0)"
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
