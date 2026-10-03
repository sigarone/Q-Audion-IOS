import Foundation

/// The elapsed-time clock of the group call screen ("0:00" -> "0:01" ...).
///
/// Why this is not a plain `Timer.scheduledTimer` in the view model (iPhone 1.0.1205, group call
/// 190cb052: the timer sat at 0:00 for 30 s of a live call): the manager reports `.active` from
/// its WebSocket thread, and again with EVERY roster update. `Timer.scheduledTimer` attaches the
/// timer to the run loop of the CALLING thread; a background thread has no running run loop, so
/// the timer never fired, and every further `.active` replaced the previous one and restarted
/// the clock. This type is safe to start from any thread, starts once, always installs its timer
/// on the main run loop (common modes, so scrolling the tiles does not freeze it) and delivers
/// its text on the main queue.
public final class GroupCallElapsedTimer: @unchecked Sendable {

    /// `m:ss`, never negative.
    public static func format(seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The new text, on the main queue: every second while running, "0:00" on `stop()`.
    public var onChange: ((String) -> Void)?

    // Both touched on the main queue only.
    private var timer: Timer?
    private var startedAt = Date()

    public init() {}

    /// Starts the clock unless it already runs (a repeated `.active` of the same call must not
    /// restart it). Callable from any thread.
    public func start() {
        DispatchQueue.main.async { [weak self] in self?.startOnMain() }
    }

    /// Stops the clock and shows "0:00". Callable from any thread.
    public func stop() {
        DispatchQueue.main.async { [weak self] in self?.stopOnMain() }
    }

    /// Whether the clock runs. Main queue only (tests).
    public var isRunning: Bool { timer != nil }

    private func startOnMain() {
        guard timer == nil else { return }
        startedAt = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopOnMain() {
        timer?.invalidate()
        timer = nil
        onChange?(Self.format(seconds: 0))
    }

    private func tick() {
        onChange?(Self.format(seconds: Int(Date().timeIntervalSince(startedAt))))
    }
}
