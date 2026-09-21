import Foundation

/// W-HBTELEM (2026-09-21) — the `call.disturbance.marker` telemetry event: the user
/// pressed "Disturbo" on the in-call screen at the instant they heard something wrong.
///
/// It exists because the call-quality analysis could not bind any counter to what a person
/// heard (no listening timestamp existed). The marker carries the counters of the last
/// COMPLETED heartbeat window, so the maintainer can read "what did the jitter buffer,
/// loss and FEC do in the seconds before the press" straight off one record.
///
/// Privacy: numbers and fixed strings only. `source` is always "button".
public enum DisturbanceMarker {

    public static let kind: String = "call.disturbance.marker"
    public static let sourceButton: String = "button"

    /// Attributes of one marker: a copy of the last completed heartbeat window's
    /// attributes, plus `since_start_ms` (ms since the call connected), `source`, and the
    /// jitter-buffer depth as it is NOW (it overrides the window's copy when known).
    public static func attributes(sinceStartMs: Int64,
                                  lastWindowAttributes: [String: Any],
                                  jbDepthNow: Int?) -> [String: Any] {
        var out: [String: Any] = lastWindowAttributes
        out[HeartbeatAttribute.sinceStartMs] = max(sinceStartMs, 0)
        out[HeartbeatAttribute.source] = sourceButton
        if let depth = jbDepthNow {
            out[HeartbeatAttribute.jbDepthNow] = Int64(depth)
        }
        return out
    }
}

/// At most one marker per second, however fast the button is hit. Pure: the caller
/// passes a monotonic clock in seconds.
public struct DisturbanceMarkerDebouncer: Equatable, Sendable {

    public static let minIntervalSeconds: TimeInterval = 1.0

    private var lastEmittedAt: TimeInterval?

    public init() {}

    /// True (and the instant is recorded) if a marker may be emitted at `now`. A clock
    /// that runs backwards never blocks.
    public mutating func shouldEmit(now: TimeInterval) -> Bool {
        if let last = lastEmittedAt, now >= last, now - last < DisturbanceMarkerDebouncer.minIntervalSeconds {
            return false
        }
        lastEmittedAt = now
        return true
    }

    public mutating func reset() {
        lastEmittedAt = nil
    }
}
