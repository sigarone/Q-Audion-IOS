import Foundation

/// WIRE_SPEC 16.3 privacy: while this side is HELD (any hold cause, pending ones included) no outbound video leaves the
/// device. The gate is fail-closed and central: the capture pipeline drops camera and screen-share frames while the call is
/// held, whatever any path did with the pause flag. The decisions are pure so every rule is pinned by a test.
public enum OutboundVideoGate {
    /// A captured or external (screen share) frame is dropped when the pipeline is paused OR the call is held. A path that
    /// calls `setVideoPaused(false)` while held changes nothing.
    public static func drops(paused: Bool, locallyHeld: Bool) -> Bool { paused || locallyHeld }

    /// The camera may be switched on (and capture restarted) only when the call is not held.
    public static func mayEnableCamera(locallyHeld: Bool) -> Bool { !locallyHeld }

    /// A screen share may start only when the call is not held.
    public static func mayStartScreenShare(locallyHeld: Bool) -> Bool { !locallyHeld }
}

/// An "unpause outbound video" request that arrived while the call was held is remembered and applied when the LAST hold
/// cause is removed (consent granted, caller's initial video, call finalised, promotion, screen share start). Nothing is
/// applied while held, and nothing is applied twice.
public struct VideoUnpauseDeferral: Equatable, Sendable {
    public private(set) var deferred = false

    public init() {}

    /// Returns true when the unpause may be applied now; false when it is deferred because the call is held.
    public mutating func request(locallyHeld: Bool) -> Bool {
        if locallyHeld {
            deferred = true
            return false
        }
        return true
    }

    /// The last hold cause was removed. Returns true when a deferred unpause must be applied now.
    public mutating func released() -> Bool {
        let wasDeferred = deferred
        deferred = false
        return wasDeferred
    }

    public mutating func reset() { deferred = false }
}
