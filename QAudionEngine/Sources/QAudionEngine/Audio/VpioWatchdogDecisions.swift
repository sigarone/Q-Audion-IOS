import Foundation

/// W-VPIOWD (2026-09-25) -- pure decisions for the W-AEC-FIX VP-IO starve watchdog and for the
/// route-change echo of an engine start. `AudioCapture` owns the timers, the notifications and the
/// engine; this file only decides, so every branch is pinned by `VpioWatchdogDecisionsTests` without
/// a live audio session (same split as `AudioInterruptionRecoveryPolicy`).
///
/// TWO DEFECTS, both proven from call logs (evidence: the 2026-09-25 sweep, call 7727f262):
///
///  1. The watchdog is a one-shot `asyncAfter(1.2 s)` that judges "the engine that exists when it
///     fires". Nothing tied it to the engine it was armed for. Any `start()` inside its window (a
///     restart, an interruption resume) left the OLD timer running against the NEW engine, which had
///     been alive for less than the window -- a false "starved" that forced the rest of the call into
///     bypass (no AEC). The generation counter (`AudioCapture.vpioWatchdogGen`) names the engine; a
///     timer of an older generation must do nothing.
///
///  2. 0.69 s after the first `start()` a route-change notification with reason `.override` arrived
///     ("output override (speaker toggle)") although the effective route had not changed -- only the
///     microphone data source had ("Bottom" -> none), a side effect of enabling voice processing --
///     and `handleRouteChange` answered it with a full engine rebuild, which is what made defect 1
///     bite. An `.override` that leaves the effective route as the engine was built for is a no-op.
public enum VpioWatchdogDecisions {

    // MARK: - Watchdog expiry

    /// What the watchdog should do when its window elapses.
    public enum StarveVerdict: Equatable {
        /// The timer was armed for an engine generation that is no longer the current one: do nothing.
        case stale
        /// No engine is running (torn down, interrupted): nothing to judge.
        case notRunning
        /// The tap delivered a buffer: keep VP-IO.
        case delivering
        /// The current engine's tap never delivered inside the window: restart without VP-IO.
        case starved
    }

    /// Order matters: a stale timer must not judge the current engine EVEN IF that engine has not
    /// delivered yet -- it has simply not had its own window (call 7727f262).
    public static func starveVerdict(armedGen: Int,
                                     currentGen: Int,
                                     isRunning: Bool,
                                     firstFrameReceived: Bool) -> StarveVerdict {
        if armedGen != currentGen { return .stale }
        if !isRunning { return .notRunning }
        if firstFrameReceived { return .delivering }
        return .starved
    }

    // MARK: - Route signature and the `.override` no-op

    /// One port of the session route. `uid` never leaves the process (a Bluetooth uid is an address):
    /// it is only compared, never logged or shipped.
    public struct RoutePort: Equatable {
        public let type: String
        public let uid: String

        public init(type: String, uid: String) {
            self.type = type
            self.uid = uid
        }
    }

    /// The effective route: input and output ports (type + uid, in route order) and whether the
    /// built-in loudspeaker is among the outputs. Deliberately WITHOUT the mic data source: that is
    /// exactly what changed in the no-op case.
    public struct RouteSignature: Equatable {
        public let inputs: [RoutePort]
        public let outputs: [RoutePort]
        public let speaker: Bool

        public init(inputs: [RoutePort], outputs: [RoutePort], speaker: Bool) {
            self.inputs = inputs
            self.outputs = outputs
            self.speaker = speaker
        }
    }

    /// How long after the end of a `start()` an `.override` notification is still treated as a
    /// possible echo of that start.
    public static let overrideSettleWindowMs: Int = 1_500

    /// True when an `.override` route-change notification needs no engine rebuild: it arrived within
    /// `windowMs` of the end of the latest `start()` AND the effective route is exactly the one the
    /// engine was built for. A real speaker toggle changes the outputs or the speaker flag, so it is
    /// never a no-op and keeps restarting the engine. Fails OPEN: an unknown start time or a missing
    /// signature returns false, i.e. the pre-existing behaviour (restart).
    public static func isOverrideNoOp(msSinceStartEnded: Int,
                                      built: RouteSignature?,
                                      current: RouteSignature?,
                                      windowMs: Int = overrideSettleWindowMs) -> Bool {
        guard msSinceStartEnded >= 0, msSinceStartEnded <= windowMs else { return false }
        guard let built = built, let current = current else { return false }
        return built == current
    }

    // MARK: - Numeric log lines (see `VpioObservability` for the format rules)

    /// A watchdog timer of an older generation expired and was ignored. `cur` is the current
    /// generation, `ff` whether the current engine has delivered a buffer, `sinceStartMs` the age of
    /// the latest start.
    public static func staleLine(gen: Int, cur: Int, firstFrame: Bool, sinceStartMs: Int) -> String {
        let ff: Int = firstFrame ? 1 : 0
        return "audioVp ev=stale gen=\(gen) cur=\(cur) ff=\(ff) since_start_ms=\(sinceStartMs)"
    }

    /// An `.override` route change was ignored because the effective route had not changed.
    public static func overrideNoOpLine(gen: Int, sinceStartMs: Int) -> String {
        return "audioVp ev=noop gen=\(gen) since_start_ms=\(sinceStartMs)"
    }
}
