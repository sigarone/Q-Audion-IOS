import Foundation

/// W-CALLERBUSY (2026-10-03, review of #169) — the re-entrancy guard of `AppState.endCall` (H-6, formerly the plain
/// `isEndingCall` flag), scoped to the CALL it guards.
///
/// ## What H-6 protects
///
/// A second `endCall()` for the SAME call while its teardown is still running (CallKit's `onEndCall` racing a
/// remote `call_hangup`) must be a no-op, or the controller is hung up twice and the peer connection leaks. The
/// teardown is synchronous; the flag stays up for 0.3 s afterwards so the racing second caller (which arrives a
/// moment later, on the next main-queue turn) still finds it.
///
/// ## The defect of a plain flag
///
/// The flag belonged to nobody. A redial inside those 0.3 s inherited it: the new call's own teardown (a
/// `call_busy` is the realistic one, it comes back within a second) found the flag up, did nothing, and left a
/// zombie `.connecting` call with `isInCall == true` that only the ring-back timeout ended. And the old call's
/// 0.3 s timer, firing during the new call's own teardown window, cleared the new call's guard early.
///
/// ## The latch
///
/// - ``begin()`` enters a teardown and returns the token of THIS teardown, or `nil` while one is in flight (H-6,
///   unchanged for the same call).
/// - ``release(token:)`` is what the 0.3 s timer calls; it clears the guard only if that teardown is still the
///   current one, so an earlier call's timer never opens a later call's guard.
/// - ``newCallAdmitted()`` is called when a new call is admitted (`startCall`'s commit point): the previous call's
///   teardown no longer guards anything, and its pending timer is invalidated.
///
/// `inFlight` is therefore "a teardown of the CURRENT call is in flight", which is what the busy handler needs to
/// know (a local hangup already ending this call owns the ending: announce nothing, show no outcome).
public struct CallTeardownLatch: Equatable, Sendable {
    private var serial: Int = 0
    private var active: Bool = false

    public init() {}

    /// A teardown of the current call is in flight.
    public var inFlight: Bool { active }

    /// Enter a teardown. `nil` when one is already in flight for this call (the caller must do nothing).
    public mutating func begin() -> Int? {
        guard !active else { return nil }
        active = true
        serial &+= 1
        return serial
    }

    /// The 0.3 s timer of the teardown `token`. A token of an earlier teardown (its call was replaced) is ignored.
    public mutating func release(token: Int) {
        guard active, serial == token else { return }
        active = false
    }

    /// A new call is admitted: whatever teardown was in flight belonged to the previous call.
    public mutating func newCallAdmitted() {
        active = false
        serial &+= 1
    }
}
