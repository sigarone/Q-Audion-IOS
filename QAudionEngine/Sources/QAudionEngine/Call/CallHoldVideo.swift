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

/// The hold causes of one call as ONE set: the causes recorded before the call is connected (`pending`) and the causes
/// handed to the sender (`inSender`). The call is held while either is non-empty, so no gate (audio, video, native mute) is
/// released while any cause is active, whichever of the two holds it. Flushing moves pending causes to the sender and never
/// changes the effective state.
public struct HoldCauseLedger: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case none
        /// The effective state went from released to held.
        case held
        /// The effective state went from held to released: the last cause of both sets is gone.
        case released
    }

    public private(set) var pending: [UInt8] = []
    public private(set) var inSender: [UInt8] = []

    public init() {}

    public var isHeld: Bool { !pending.isEmpty || !inSender.isEmpty }

    /// Adds a cause. With the call connected it goes to the sender (`toSender`), otherwise it waits in `pending`.
    public mutating func add(_ cause: UInt8, callActive: Bool) -> (change: Change, toSender: Bool) {
        let wasHeld = isHeld
        if callActive {
            if !inSender.contains(cause) { inSender.append(cause) }
        } else if !pending.contains(cause) && !inSender.contains(cause) {
            pending.append(cause)
        }
        return (!wasHeld && isHeld ? .held : .none, callActive)
    }

    /// Removes a cause from whichever set holds it. `fromSender` says the sender must drop it too.
    public mutating func remove(_ cause: UInt8) -> (change: Change, fromSender: Bool) {
        let wasHeld = isHeld
        var fromSender = false
        if let i = pending.firstIndex(of: cause) {
            pending.remove(at: i)
        } else if let i = inSender.firstIndex(of: cause) {
            inSender.remove(at: i)
            fromSender = true
        }
        return (wasHeld && !isHeld ? .released : .none, fromSender)
    }

    /// The call became active: pending causes move to the sender. Returns them. The effective state is unchanged.
    public mutating func flush() -> [UInt8] {
        let moved = pending
        for c in moved where !inSender.contains(c) { inSender.append(c) }
        pending.removeAll()
        return moved
    }

    public mutating func reset() { self = HoldCauseLedger() }
}
