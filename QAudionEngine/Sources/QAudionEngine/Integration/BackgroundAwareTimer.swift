import Foundation

/// A repeating timer whose period follows `AppBackgroundFlag`: `foregroundSeconds` while the app is in the
/// foreground, `backgroundSeconds` while it is not.
///
/// The period is re-armed the moment the flag changes, from the flag's observer, not at the next fire. So going
/// to the background does not leave a few foreground-rate fires behind, and coming back does not wait out a long
/// background period: the first fire after the change is one new period away (3 s on return to the foreground).
/// The flag is re-read at every re-arm and never trusted from the notification, so two changes delivered out of
/// order from different threads still end on the real state.
///
/// Used by checks that must keep running in the background but can run less often there. Nothing is ever turned
/// off: the period gets longer, the handler still fires.
///
/// Thread-safety: `start` / `stop` and the flag's notifications may come from any thread. The handler runs on
/// `queue`.
final class BackgroundAwareTimer: @unchecked Sendable {
    /// Arms a repeating timer on `queue`: first fire after `firstDelay` seconds, then every `interval`. Returns
    /// the action that cancels it. Injected so a test can drive the fires by hand.
    typealias Arm = (
        _ queue: DispatchQueue, _ firstDelay: Double, _ interval: Double,
        _ handler: @escaping @Sendable () -> Void
    ) -> () -> Void

    /// The production arm: a `DispatchSourceTimer`.
    static let dispatchArm: Arm = { queue, firstDelay, interval, handler in
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + firstDelay, repeating: interval)
        timer.setEventHandler { handler() }
        timer.resume()
        return { timer.cancel() }
    }

    private let queue: DispatchQueue
    private let flag: AppBackgroundFlag
    private let foregroundSeconds: Double
    private let backgroundSeconds: Double
    private let arm: Arm
    private let handler: @Sendable () -> Void
    private let onCadence: (@Sendable (_ background: Bool, _ everySeconds: Double) -> Void)?

    private let lock = NSLock()
    private var running = false
    private var cancelTimer: (() -> Void)?
    private var observerId: UUID?

    /// - Parameter onCadence: called (outside the lock) each time a period is armed, with the flag value it was
    ///   armed for and the period in seconds: at `start` and at every change of the flag.
    init(
        queue: DispatchQueue,
        flag: AppBackgroundFlag,
        foregroundSeconds: Double,
        backgroundSeconds: Double,
        arm: @escaping Arm = BackgroundAwareTimer.dispatchArm,
        onCadence: (@Sendable (_ background: Bool, _ everySeconds: Double) -> Void)? = nil,
        handler: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.flag = flag
        self.foregroundSeconds = foregroundSeconds
        self.backgroundSeconds = backgroundSeconds
        self.arm = arm
        self.onCadence = onCadence
        self.handler = handler
    }

    /// Starts firing at the period of the current state. A no-op when already started.
    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()

        // Registered before the flag is read below, so a change in between is not lost: it re-arms too, and the
        // last re-arm reads the flag again.
        let id = flag.addChangeObserver { [weak self] _ in self?.flagChanged() }

        lock.lock()
        guard running else {
            // stop() ran in between.
            lock.unlock()
            flag.removeChangeObserver(id)
            return
        }
        observerId = id
        let armed = rearmLocked()
        lock.unlock()
        onCadence?(armed.background, armed.everySeconds)
    }

    /// Cancels the timer and stops following the flag. A no-op when not started.
    func stop() {
        lock.lock()
        running = false
        let cancel = cancelTimer
        cancelTimer = nil
        let id = observerId
        observerId = nil
        lock.unlock()
        cancel?()
        if let id { flag.removeChangeObserver(id) }
    }

    private func flagChanged() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let armed = rearmLocked()
        lock.unlock()
        onCadence?(armed.background, armed.everySeconds)
    }

    /// Cancels the armed timer and arms one for the flag's current value. Must be called with `lock` held.
    private func rearmLocked() -> (background: Bool, everySeconds: Double) {
        let background = flag.isInBackground
        let every = background ? backgroundSeconds : foregroundSeconds
        cancelTimer?()
        cancelTimer = arm(queue, every, every, handler)
        return (background, every)
    }
}
