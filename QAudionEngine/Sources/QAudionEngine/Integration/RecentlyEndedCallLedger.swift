import Foundation

/// W-GHOSTCALL (2026-09-25) — short-lived memory of the call UUIDs this app has
/// already told CallKit are over, so a late signal about the same call cannot
/// bring it back to life.
///
/// Live incident (call e3acecd7, 2026-09-23 15:04): the caller hung up over the
/// WebSocket (`opaquehang rx`, `reportCallEnded` + `endCall` in the same
/// millisecond) and the server still sent its `call_cancelled` VoIP push. The
/// push handler reported the SAME uuid to CallKit again (`callkit report ok=1
/// dup=0`: CallKit had already dropped it, so this was a brand-new ring), the
/// user tapped Answer 1.9 s after the real hangup, and the app entered an
/// in-call state with no call id for 6.6 s. Nothing on the device remembered
/// that the uuid was dead: `activeCallKitId` had already been cleared by
/// `endCall`, and CallKit is a poor witness because a ring UI can outlive
/// `reportCall(with:endedAt:)` (the Answer in e3acecd7 arrived 1.3 s after the
/// uuid was reported again).
///
/// This type is that memory. It is deliberately dumb: a bounded uuid -> end time
/// map with a TTL. `AppState` fills it at the two places a call ends (`endCall`,
/// `handleRemoteCallHangup`) and asks it in the two places a dead call could be
/// revived (the cancel-push handler and the answer path). A second instance holds
/// the placeholder uuids the cancel-push handler invents (see
/// `GhostCallPolicy.cancelReportPlan`), which are "ended by construction".
///
/// Pure value type on purpose, and Foundation-only, like `CallKitCallLedger`
/// (same reason: the live CallKit types cannot be built in a unit test). No lock:
/// `AppState` is `@MainActor` and owns the only instances. The clock is injected
/// as a `now:` argument on every call (defaulting to `Date()`), so tests never
/// sleep.
///
/// TTL 120 s: the gap measured in e3acecd7 between the real hangup and the
/// re-report was 0.6 s, so this is deliberately generous, yet short enough that
/// the memory does not outlive any plausible reuse of a uuid. The wall clock is
/// used, not uptime: an app suspended for an hour must find its old entries
/// expired. If the clock is stepped backwards an entry simply stays "recent" for
/// longer, which is the safe direction (the consequence is a placeholder report
/// instead of a real one, never a refused genuine call — a genuine call has a
/// fresh uuid).
public struct RecentlyEndedCallLedger: Sendable {

    /// How long an ended uuid is remembered.
    public static let defaultTtl: TimeInterval = 120

    /// Upper bound on entries. A phone ends far fewer than 16 calls inside the
    /// TTL; the bound only exists so a hostile or buggy source of uuids can never
    /// grow this without limit.
    public static let defaultCapacity: Int = 16

    public let ttl: TimeInterval
    public let capacity: Int
    private var endedAt: [UUID: Date] = [:]

    public init(ttl: TimeInterval = RecentlyEndedCallLedger.defaultTtl,
                capacity: Int = RecentlyEndedCallLedger.defaultCapacity) {
        self.ttl = ttl
        self.capacity = max(1, capacity)
    }

    /// Remember that `uuid` has just ended. Recording an uuid that is already
    /// present refreshes its timestamp (a second end for the same call must not
    /// shorten the memory). Expired entries are dropped first; if the map is
    /// still over capacity the oldest entries go.
    public mutating func recordEnded(_ uuid: UUID, now: Date = Date()) {
        prune(now: now)
        endedAt[uuid] = now
        while endedAt.count > capacity, let oldest = endedAt.min(by: { $0.value < $1.value }) {
            endedAt.removeValue(forKey: oldest.key)
        }
    }

    /// Whether `uuid` ended less than `ttl` seconds ago. An entry whose age is
    /// exactly `ttl` is already expired (the window is half-open).
    public func wasRecentlyEnded(_ uuid: UUID, now: Date = Date()) -> Bool {
        guard let at = endedAt[uuid] else { return false }
        return now.timeIntervalSince(at) < ttl
    }

    /// Drop every expired entry. `recordEnded` already does this; exposed so a
    /// caller that only reads can keep the map small.
    public mutating func prune(now: Date = Date()) {
        endedAt = endedAt.filter { now.timeIntervalSince($0.value) < ttl }
    }

    /// Entries currently held, expired ones included until the next prune.
    public var count: Int { endedAt.count }
}
