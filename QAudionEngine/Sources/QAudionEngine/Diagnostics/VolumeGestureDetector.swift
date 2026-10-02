import Foundation

/// The bug-report volume gesture (two hardware volume presses in quick succession, see
/// `BugReporter`), told apart from the output-volume changes the SYSTEM makes.
///
/// W-BUGREPPHANTOM (2026-10-02). `AVAudioSession.outputVolume` is per audio route: the
/// earpiece and the loudspeaker each keep their own level, so every route change (speaker
/// override on / off, a category change, a call ending) reports a new `outputVolume`
/// through the same KVO a button press does. The old detector counted every KVO as a
/// press, read equal old/new values as a "down" press and timestamped each one when its
/// main-actor hop finally ran. A 1:1 -> group hand-over flips the route twice within about
/// a second (the 1:1 teardown resets the override to the earpiece, the group call puts the
/// loudspeaker back), so the "Segnala un problema" sheet opened on its own at the
/// hand-over: the three iPhone reports of 2026-09-29 / 2026-10-02 (93005f73, 2e309206,
/// 313539e3) were all opened 0.5-4.5 s after the hand-over, each right after an audio
/// route change in the log tail, and sent with an empty note.
///
/// A change only counts as a press when
///  * it actually changes the volume, by at most two button steps (one step is 1/16),
///  * it is not inside the quiet period that follows a route change or a call transition
///    the app itself makes (`noteSystemVolumeChange`),
/// and the time of each change is the time it was DELIVERED (the caller passes it in),
/// never the time a queued hop happened to run.
///
/// Pure value type, no clock of its own: unit-tested in `VolumeGestureDetectorTests`.
public struct VolumeGestureDetector: Sendable {

    public enum Verdict: Equatable, Sendable {
        /// A plausible press, recorded; no gesture yet.
        case pressed
        /// The gesture: two presses `deltaMs` apart.
        case gesture(deltaMs: Int)
        /// Not a press (logged by the caller as a numeric code).
        case ignored(IgnoreReason)
    }

    /// Numeric codes, logged as `why=<n>`.
    public enum IgnoreReason: Int, Sendable {
        /// Inside the cool-down after a gesture.
        case cooldown = 1
        /// The value did not change (a route change re-reporting the same level).
        case noChange = 2
        /// A jump larger than two button steps: a route switch, not a press.
        case notAStep = 3
        /// Inside the quiet period after an audio route change.
        case routeChange = 4
        /// Inside the quiet period after a call transition the app made.
        case transition = 5
    }

    /// Up-then-down (or down-then-up) within this window.
    public static let oppositeWindow: TimeInterval = 0.4
    /// Two presses in the same direction within this window (both buttons at once
    /// register as one direction, pressed twice).
    public static let sameDirectionWindow: TimeInterval = 0.6
    /// Smaller than this is "no change".
    public static let minStep: Float = 0.001
    /// One hardware press moves the volume by 1/16 (0.0625); allow two coalesced ones.
    public static let maxStep: Float = 0.13
    /// Volume changes this long after a route change are the system's.
    public static let routeQuietPeriod: TimeInterval = 1.5
    /// Volume changes this long after a call transition are the system's.
    public static let transitionQuietPeriod: TimeInterval = 3
    public static let cooldown: TimeInterval = 5

    private struct Press: Sendable {
        let at: TimeInterval
        let up: Bool
    }

    private var lastPress: Press?
    private var cooldownUntil: TimeInterval = -.greatestFiniteMagnitude
    private var quietUntil: TimeInterval = -.greatestFiniteMagnitude
    private var quietReason: IgnoreReason = .routeChange

    public init() {}

    /// The system is about to change (or just changed) the output volume at `now`: a route
    /// change, or a call transition the app makes. Changes until `now + period` are not
    /// presses, and a press recorded just before is dropped (the KVO of a route change can
    /// be delivered before its notification).
    public mutating func noteSystemVolumeChange(at now: TimeInterval, reason: IgnoreReason,
                                                period: TimeInterval = VolumeGestureDetector.routeQuietPeriod) {
        lastPress = nil
        let until = now + period
        if until > quietUntil {
            quietUntil = until
            quietReason = reason
        }
    }

    /// One output-volume change, `old` -> `new`, delivered at `now` (seconds, any monotonic clock).
    public mutating func observe(old: Float, new: Float, at now: TimeInterval) -> Verdict {
        if now < cooldownUntil { return .ignored(.cooldown) }
        if now < quietUntil { return .ignored(quietReason) }
        let delta = new - old
        let magnitude = abs(delta)
        if magnitude < Self.minStep {
            lastPress = nil
            return .ignored(.noChange)
        }
        if magnitude > Self.maxStep {
            lastPress = nil
            return .ignored(.notAStep)
        }
        let press = Press(at: now, up: delta > 0)
        guard let first = lastPress else {
            lastPress = press
            return .pressed
        }
        let gap = now - first.at
        let inOrder = gap >= 0
        let opposite = first.up != press.up && inOrder && gap <= Self.oppositeWindow
        let same = first.up == press.up && inOrder && gap <= Self.sameDirectionWindow
        guard opposite || same else {
            lastPress = press
            return .pressed
        }
        lastPress = nil
        cooldownUntil = now + Self.cooldown
        return .gesture(deltaMs: Int((gap * 1000).rounded()))
    }
}
