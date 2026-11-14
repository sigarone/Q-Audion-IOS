import Foundation

/// When the mesh suspends discovery during a call on a Bluetooth audio route
/// (docs/mesh/MESH_LINK_SPEC.md section 2.1), as a pure decision.
///
/// While a call is active AND the call audio uses a Bluetooth device for input or output (a hands-free link, LE
/// Audio, a hearing aid, any Bluetooth audio port), the device stops scanning, stops advertising and opens no new
/// outgoing link. A call is any connected voice or video call on the device, of any app and a cellular call
/// included; a ringing call is not one (``MeshCallDefinition``). Links that already exist stay up and keep carrying
/// ANNOUNCE and packets. The pause ends when the call ends or the call audio no longer uses a Bluetooth device;
/// discovery then resumes at once (the specification allows up to 2 s), except that a route that flips back and
/// forth never restarts discovery more than once per 5 s.
///
/// The owner (the transport) feeds in the two facts and the current time whenever one of them may have changed,
/// and applies the returned action. Whether the antenna may be on at all (consent, kill switch, the user's choice)
/// is decided elsewhere and is not an input here: the owner only evaluates while its antenna is on and calls
/// ``reset()`` when it turns the antenna off, so this type can never bring discovery back on its own.
///
/// Time is plain milliseconds from any monotonic clock.
public struct MeshBtCallPause: Equatable {

    /// A restart of discovery after a pause happens at most once in this interval (section 2.1).
    public static let restartMinIntervalMs: Int64 = 5_000
    /// Discovery resumes within this time of the call ending or the route leaving Bluetooth (section 2.1). The
    /// decision itself adds no delay; only the rate limit above can postpone a resume, and only when the route
    /// has just flipped back and forth.
    public static let resumeWithinMs: Int64 = 2_000

    /// The `reason` of the `radio.pause` event.
    public static let pauseReason = "bt_call_route"

    /// The `reason` of the `radio.resume` event.
    public enum ResumeReason: String, Equatable, Sendable {
        /// No call is active any more.
        case callEnded = "call_ended"
        /// The call goes on, but its audio no longer uses a Bluetooth device.
        case routeChanged = "route_changed"
    }

    public enum Action: Equatable {
        /// Nothing changes: discovery stays as it is.
        case keep
        /// Stop scanning and advertising, open no new link (log `radio.pause`).
        case pause
        /// Start discovery again (log `radio.resume`); `pausedMs` is the time since the pause began.
        case resume(reason: ResumeReason, pausedMs: Int64)
    }

    public struct Decision: Equatable {
        public let action: Action
        /// When the pause should end but the rate limit holds it back: evaluate again after this many
        /// milliseconds (with the then current facts). Nil when nothing is waiting.
        public let recheckInMs: Int64?

        public init(action: Action, recheckInMs: Int64? = nil) {
            self.action = action
            self.recheckInMs = recheckInMs
        }
    }

    /// True while discovery is suspended.
    public private(set) var isPaused = false

    private var pausedSinceMs: Int64 = 0
    private var lastResumeMs: Int64?

    public init() {}

    /// Feeds in the current facts. Call it whenever the call state or the audio route may have changed, and again
    /// after `recheckInMs` when the previous decision asked for it.
    ///
    /// - Parameters:
    ///   - callActive: a connected call exists on the device (``MeshCallDefinition``).
    ///   - btRoute: the audio route has a Bluetooth input or a Bluetooth output port.
    public mutating func evaluate(callActive: Bool, btRoute: Bool, nowMs: Int64) -> Decision {
        if callActive && btRoute {
            guard !isPaused else { return Decision(action: .keep) }
            isPaused = true
            pausedSinceMs = nowMs
            return Decision(action: .pause)
        }
        guard isPaused else { return Decision(action: .keep) }
        if let last = lastResumeMs {
            let elapsed = nowMs - last
            if elapsed < Self.restartMinIntervalMs {
                // A flip back and forth: discovery was restarted a moment ago, wait out the rest of the interval.
                let wait = min(Self.restartMinIntervalMs, Self.restartMinIntervalMs - elapsed)
                return Decision(action: .keep, recheckInMs: max(1, wait))
            }
        }
        isPaused = false
        lastResumeMs = nowMs
        let reason: ResumeReason = callActive ? .routeChanged : .callEnded
        return Decision(action: .resume(reason: reason, pausedMs: max(0, nowMs - pausedSinceMs)))
    }

    /// The antenna was turned off: the pause and the restart history are forgotten, so a later start decides afresh.
    public mutating func reset() {
        self = MeshBtCallPause()
    }
}
