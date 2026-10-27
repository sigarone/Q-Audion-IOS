import Foundation

/// Bounded retry of the app's own capture start while a call runs on the relay
/// path (the call-fallback handover).
///
/// The handover has two halves that cannot overlap on one audio session: the
/// native sender's audio unit has to be off before the app's own capture unit
/// can start. What this type adds is everything around that gap: the start is
/// retried every `intervalMs` for up to `maxAttempts` tries, the native sender
/// stays un-muted until a start is confirmed, and when every try fails the
/// owner is told once (`onGaveUp`) so it can hand the call back.
///
/// An audio route change (`observeRouteChanges`) only brings the next scheduled
/// try forward: never during the initial settle, never closer than
/// `minTrySpacingMs` to the previous try, and never as an extra try.
///
/// Main-thread only, like the rest of the call state. Pure apart from the
/// injected scheduler, clock and observer, so the sequencing is testable
/// without AVAudioSession.
public final class FallbackRelayStartRetry {

    /// Gap between two scheduled tries.
    public static let intervalMs: Int = 150
    /// Total tries (the first one plus the retries): about 2 s of retrying.
    public static let maxAttempts: Int = 14
    /// A route-change nudge never pulls a try closer than this to the previous one.
    public static let minTrySpacingMs: Int64 = 125

    /// Runs `work` after `delayMs`; the returned closure cancels it.
    public typealias Scheduler = (_ delayMs: Int, _ work: @escaping () -> Void) -> () -> Void
    /// Registers `handler` for audio route changes; the returned closure unregisters it.
    public typealias RouteObserver = (_ handler: @escaping () -> Void) -> () -> Void

    /// Production scheduler: the main queue.
    public static let mainQueueScheduler: Scheduler = { delayMs, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
        return { item.cancel() }
    }

    /// Production clock: monotonic milliseconds.
    public static let monotonicNowMs: () -> Int64 = {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }

    /// No route observation.
    public static let noRouteObserver: RouteObserver = { _ in { } }

    private let scheduler: Scheduler
    private let observeRouteChanges: RouteObserver
    private let nowMs: () -> Int64
    /// Tries once; `true` when the capture is running afterwards.
    private let attempt: () -> Bool
    /// `false` once the call is over or the fallback no longer applies.
    private let isStillWanted: () -> Bool
    private let onAttemptFailed: (_ attempt: Int) -> Void
    private let onStarted: (_ attempt: Int) -> Void
    private let onGaveUp: (_ attempts: Int) -> Void

    private var epoch = 0
    private var cancelPending: (() -> Void)?
    private var removeRouteObserver: (() -> Void)?
    private var pendingDueAtMs: Int64?
    private var settleEndsAtMs: Int64 = 0
    private var lastAttemptAtMs: Int64?
    public private(set) var isRunning = false
    public private(set) var attempts = 0

    public init(
        scheduler: @escaping Scheduler = FallbackRelayStartRetry.mainQueueScheduler,
        observeRouteChanges: @escaping RouteObserver = FallbackRelayStartRetry.noRouteObserver,
        nowMs: @escaping () -> Int64 = FallbackRelayStartRetry.monotonicNowMs,
        attempt: @escaping () -> Bool,
        isStillWanted: @escaping () -> Bool,
        onAttemptFailed: @escaping (_ attempt: Int) -> Void,
        onStarted: @escaping (_ attempt: Int) -> Void,
        onGaveUp: @escaping (_ attempts: Int) -> Void
    ) {
        self.scheduler = scheduler
        self.observeRouteChanges = observeRouteChanges
        self.nowMs = nowMs
        self.attempt = attempt
        self.isStillWanted = isStillWanted
        self.onAttemptFailed = onAttemptFailed
        self.onStarted = onStarted
        self.onGaveUp = onGaveUp
    }

    /// Starts the sequence. A second call while a sequence runs is ignored (no double start).
    /// `firstDelayMs == 0` runs the first try inline.
    @discardableResult
    public func begin(firstDelayMs: Int) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        attempts = 0
        lastAttemptAtMs = nil
        epoch += 1
        settleEndsAtMs = nowMs() + Int64(max(0, firstDelayMs))
        removeRouteObserver = observeRouteChanges { [weak self] in self?.nudge() }
        if firstDelayMs <= 0 {
            runAttempt(forEpoch: epoch)
        } else {
            scheduleNext(afterMs: firstDelayMs)
        }
        return true
    }

    /// An audio route change happened: bring the next scheduled try forward.
    /// Ignored during the settle; keeps `minTrySpacingMs` from the previous try;
    /// never adds a try (the pending one is moved, not duplicated).
    public func nudge() {
        guard isRunning else { return }
        let now = nowMs()
        guard now >= settleEndsAtMs else { return }
        var delay: Int64 = 0
        if let last = lastAttemptAtMs {
            delay = max(0, last + Self.minTrySpacingMs - now)
        }
        if let due = pendingDueAtMs, due - now <= delay { return }  // already due sooner
        cancelPending?()
        scheduleNext(afterMs: Int(delay))
    }

    /// Stops the sequence (call over, fallback left). No further try runs after this.
    public func cancel() {
        guard isRunning else { return }
        stop()
    }

    private func stop() {
        isRunning = false
        epoch += 1
        cancelPending?()
        cancelPending = nil
        pendingDueAtMs = nil
        removeRouteObserver?()
        removeRouteObserver = nil
    }

    private func scheduleNext(afterMs delayMs: Int) {
        let scheduledEpoch = epoch
        pendingDueAtMs = nowMs() + Int64(delayMs)
        cancelPending = scheduler(delayMs) { [weak self] in
            self?.runAttempt(forEpoch: scheduledEpoch)
        }
    }

    private func runAttempt(forEpoch scheduledEpoch: Int) {
        guard isRunning, scheduledEpoch == epoch else { return }
        cancelPending = nil
        pendingDueAtMs = nil
        guard isStillWanted() else {
            stop()
            return
        }
        attempts += 1
        lastAttemptAtMs = nowMs()
        let number = attempts
        if attempt() {
            stop()
            onStarted(number)
            return
        }
        // The attempt itself may have ended the sequence (cancel from a callback).
        guard isRunning, scheduledEpoch == epoch else { return }
        onAttemptFailed(number)
        guard isRunning, scheduledEpoch == epoch else { return }
        if number >= Self.maxAttempts {
            stop()
            onGaveUp(number)
            return
        }
        scheduleNext(afterMs: Self.intervalMs)
    }
}

/// What the owner does, in this order, when every relay-capture try failed: the latch
/// goes first (so the sender is no longer forced muted), the half-started capture is
/// stopped, the native sender is un-muted, the native audio unit is switched back on,
/// and only then is the controller-side engaged state reset so a later outage or
/// dead sender can engage again (after the cool-down).
public enum FallbackHandBack {
    public enum Step: Equatable {
        case clearLatch
        case stopCapture
        case unmuteNativeSender
        case restoreNativeUnit
        case resetControllerState
    }

    public static let steps: [Step] = [
        .clearLatch, .stopCapture, .unmuteNativeSender, .restoreNativeUnit, .resetControllerState,
    ]
}
