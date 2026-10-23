import Foundation

/// IN-CALL NARROWBAND BLUETOOTH NOTICE (2026-10-22) -- the live side of the banner: while a call is up it looks at the
/// audio route, hands what it sees to the rules (`NarrowbandBluetoothBannerState`), writes the two log lines and tells its
/// owner when the banner goes up or down. It knows nothing of `AVAudioSession`, `Timer` or `NotificationCenter`: those
/// come in through `NarrowbandRouteEnvironment`, so everything here is unit-tested off-device with a fake route, a fake
/// clock and fake timers (`NarrowbandBluetoothWatcherTests`). The app supplies the real environment and draws.
///
/// What it does, and what it deliberately does not do:
///  * For the whole call it listens to route changes (one cheap observer) and looks at the route when one arrives.
///  * It runs a one-second periodic look ONLY while the call input is Bluetooth hands-free and the banner can still
///    matter (not dismissed): the sample rate of a hands-free link can settle without a notification of its own. On any
///    other route, and after a dismissal, there is no periodic work at all (a call is long and the phone is in a pocket).
///  * While a narrowband count is running it also schedules ONE look at the moment the settle time is over
///    (`NarrowbandBluetoothBannerState.showDeadline`), so the banner appears one second after the link turned narrowband
///    and not at whichever periodic look comes next.
///  * It keeps one call's memories (dismissal, settle count, log-line count) under the call key it is given
///    (`NarrowbandBluetoothCallScope`): the same key again changes nothing, whichever screen asks; another key, or nil, is
///    another call and starts clean.
///
/// Main thread only: every method, every environment callback. The class has no lock of its own.
public final class NarrowbandBluetoothWatcher {

    /// How often the route is looked at while the call input is Bluetooth hands-free.
    public static let pollSeconds: Double = 1.0

    /// A one-shot look is never armed for less than this: a clock that reads a hair early at the deadline would otherwise
    /// re-arm it for zero seconds.
    private static let minimumLookDelay: Double = 0.01

    /// "Use the phone": the owner moves the call audio to the built-in microphone and the phone's own output for this kind
    /// of call. Set once by the owner; nil does nothing.
    public var usePhone: (() -> Void)?

    private let environment: NarrowbandRouteEnvironment
    private let writeLine: (String) -> Void

    /// Told every time the banner goes up or down, never the same value twice in a row. Set by the owner (it may be set
    /// after `init`, which lets the owner capture itself).
    public var onVisibilityChange: (Bool) -> Void

    private var state = NarrowbandBluetoothBannerState()
    private var callKey: String?
    private var cancelRouteObserver: NarrowbandCancel?
    private var cancelPoll: NarrowbandCancel?
    private var cancelSettleLook: NarrowbandCancel?
    private var settleLookDeadline: Double?

    /// - Parameters:
    ///   - environment: the route, the clock and the timers.
    ///   - writeLine: where the two numeric log lines go (`NarrowbandBluetoothLines`).
    ///   - onVisibilityChange: see the property of the same name.
    public init(
        environment: NarrowbandRouteEnvironment,
        writeLine: @escaping (String) -> Void,
        onVisibilityChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.environment = environment
        self.writeLine = writeLine
        self.onVisibilityChange = onVisibilityChange
    }

    /// Whether the banner is up right now.
    public var isVisible: Bool { state.isVisible }

    // MARK: - Call lifecycle

    /// The key of the call that is up (`NarrowbandBluetoothCallScope.key`), nil when none is. Idempotent for the same key.
    /// A different key is a different call: whatever the banner remembered is dropped and it starts clean; nil takes the
    /// banner down and stops watching.
    public func setCall(key: String?) {
        guard key != callKey else { return }
        stopWatching()
        callKey = key
        if key != nil {
            startWatching()
        }
    }

    private func startWatching() {
        cancelRouteObserver = environment.observeRouteChanges { [weak self] in
            self?.evaluate()
        }
        evaluate()
    }

    private func stopWatching() {
        cancelRouteObserver?()
        cancelRouteObserver = nil
        stopPoll()
        stopSettleLook()
        let wasVisible: Bool = state.isVisible
        state.reset()
        if wasVisible { onVisibilityChange(false) }
    }

    // MARK: - Route

    /// Reads the route once and lets the rules decide; then makes the periodic look and the settle look follow what it
    /// saw. Called by the route observer, the periodic look, the settle look and the owner. Does nothing when no call is up.
    public func evaluate() {
        guard callKey != nil else { return }
        let reading: NarrowbandRouteReading = environment.readRoute()
        let now: Double = environment.now
        let change = state.observe(inputPort: reading.inputPort, sampleRateHz: reading.sampleRateHz, now: now)
        apply(change)
        let onHandsFree: Bool = reading.inputPort == NarrowbandBluetoothPolicy.handsFreeInputPort
        followPoll(onHandsFree: onHandsFree)
        followSettleDeadline(now: now)
    }

    private func apply(_ change: NarrowbandBluetoothBannerState.Change) {
        switch change {
        case .unchanged:
            return
        case .shown(let sampleRateHz, let log):
            onVisibilityChange(true)
            if log {
                writeLine(NarrowbandBluetoothLines.shown(sampleRateHz: sampleRateHz))
            }
        case .hidden:
            onVisibilityChange(false)
        }
    }

    // MARK: - The two kinds of scheduled look

    /// The periodic look runs while the input is Bluetooth hands-free and the banner has not been dismissed.
    private func followPoll(onHandsFree: Bool) {
        let wanted: Bool = onHandsFree && !state.isDismissed
        if wanted {
            if cancelPoll == nil {
                cancelPoll = environment.repeating(every: Self.pollSeconds) { [weak self] in
                    self?.evaluate()
                }
            }
        } else {
            stopPoll()
        }
    }

    private func stopPoll() {
        cancelPoll?()
        cancelPoll = nil
    }

    /// One look at the end of the settle time, for as long as a narrowband count is running.
    private func followSettleDeadline(now: Double) {
        guard let deadline = state.showDeadline else {
            stopSettleLook()
            return
        }
        if cancelSettleLook != nil, settleLookDeadline == deadline { return }
        cancelSettleLook?()
        settleLookDeadline = deadline
        let delay: Double = max(deadline - now, Self.minimumLookDelay)
        cancelSettleLook = environment.once(after: delay) { [weak self] in
            self?.settleLookFired()
        }
    }

    private func settleLookFired() {
        cancelSettleLook = nil
        settleLookDeadline = nil
        evaluate()
    }

    private func stopSettleLook() {
        cancelSettleLook?()
        cancelSettleLook = nil
        settleLookDeadline = nil
    }

    // MARK: - Taps

    /// The close button: the banner stays away for the rest of the call, and nothing is scheduled for it any more.
    public func dismiss() {
        apply(state.dismiss())
        stopPoll()
        stopSettleLook()
    }

    /// "Use the phone": the call audio moves to the built-in microphone and the phone's own output. It is not a dismissal:
    /// the banner goes away when the route follows, and comes back if the user returns to a headset that is still
    /// narrowband; if the session refuses it stays, and the user can try again or close it.
    public func switchToPhone() {
        writeLine(NarrowbandBluetoothLines.switchTap)
        usePhone?()
        evaluate()
    }
}

/// One look at the call audio route: the raw value of the first input port (`AVAudioSession.Port.rawValue`, nil when the
/// route has no input) and the session's sample rate.
public struct NarrowbandRouteReading: Equatable, Sendable {
    public let inputPort: String?
    public let sampleRateHz: Double

    public init(inputPort: String?, sampleRateHz: Double) {
        self.inputPort = inputPort
        self.sampleRateHz = sampleRateHz
    }
}

/// Cancels what a `NarrowbandRouteEnvironment` method scheduled. Safe to call more than once.
public typealias NarrowbandCancel = () -> Void

/// What the watcher needs from the outside world: the route, a monotonic clock, route-change notifications and timers.
/// The app implements it on `AVAudioSession`, `NotificationCenter` and the main run loop; the tests with fakes.
/// Every callback must be delivered on the main thread.
public protocol NarrowbandRouteEnvironment: AnyObject {

    /// A monotonic clock in seconds (only differences matter).
    var now: Double { get }

    /// Reads the current route.
    func readRoute() -> NarrowbandRouteReading

    /// Calls `handler` at every audio route change until the returned closure is called.
    func observeRouteChanges(_ handler: @escaping () -> Void) -> NarrowbandCancel

    /// Calls `action` every `seconds` until the returned closure is called.
    func repeating(every seconds: Double, _ action: @escaping () -> Void) -> NarrowbandCancel

    /// Calls `action` once after `seconds`, unless the returned closure is called first.
    func once(after seconds: Double, _ action: @escaping () -> Void) -> NarrowbandCancel
}
