import Foundation

/// P0-1c follow-up (2026-08-05, coordinated fix plan cluster 2) —
/// monotonicity replay-guard for `group_membership_changed` events,
/// mirroring Android's `MembershipReplayGuard` (Phase 11.5). In-memory
/// only (process lifetime), deliberately never persisted to disk — a
/// persisted replay cache would itself leak membership-change timing
/// across app restarts, which is not a trade this guard needs to make
/// (a fresh process re-admits the first event it sees for any group,
/// same as Android).
///
/// Two gates, both keyed off the SIGNED envelope's own `e_proposed`/`ts`
/// (never the outer WS-event fields — `GroupMembershipVerifier` extracts
/// these from the parsed, signature-verified envelope bytes, so a
/// malicious server cannot bypass this guard by mutating only the outer
/// frame):
///
///  - Gate 1 (cross-epoch floor): the highest `e_proposed` ever accepted
///    for a group. An incoming envelope whose `e_proposed` is LOWER is
///    rejected outright, regardless of its own `ts` — this is what
///    catches a replayed OLDER epoch's envelope after a newer epoch was
///    already applied (a fresh, never-before-seen `ts` at that older
///    epoch would otherwise sail through a same-epoch-only check).
///  - Gate 2 (same-epoch monotonic ts): repeats of the SAME
///    `(groupId, e_proposed)` must carry a strictly increasing `ts`.
///
/// Bounded (LRU, 256 entries per map) so a hostile server cannot grow
/// this unbounded by spamming novel keys.
///
/// `@MainActor`-isolated: every call site (`GroupMembershipVerifier`,
/// itself only ever invoked from `AppState.handleGroupMembershipChanged`'s
/// `Task { @MainActor in ... }`) is already on the main actor, so this
/// avoids any actor-hop or extra locking.
@MainActor
final class GroupMembershipReplayGuard {
    static let shared = GroupMembershipReplayGuard()
    private init() {}

    private static let maxEntries = 256

    private var maxEpochSeen: [String: Int64] = [:]
    private var maxEpochOrder: [String] = []

    private var sameEpochSeen: [String: Int64] = [:]
    private var sameEpochOrder: [String] = []

    /// Returns `true` if this `(groupId, eProposed, ts)` is admissible
    /// (not a replay) and records it. Returns `false` — recording nothing
    /// — if it is a replay under either gate.
    func check(groupId: String, eProposed: Int64, ts: Int64) -> Bool {
        if let seenMax = maxEpochSeen[groupId], eProposed < seenMax {
            let gShort: String = String(groupId.prefix(8))
            RTLog.warn("group", "replay: eProposed below floor g=" + gShort)
            return false
        }
        let sameKey: String = groupId + ":" + String(eProposed)
        if let seenTs = sameEpochSeen[sameKey], ts <= seenTs {
            let gShort: String = String(groupId.prefix(8))
            RTLog.warn("group", "replay: ts not increasing g=" + gShort)
            return false
        }
        let currentMax = maxEpochSeen[groupId]
        if currentMax == nil || eProposed > currentMax! {
            insert(key: groupId, value: eProposed, map: &maxEpochSeen, order: &maxEpochOrder)
        }
        insert(key: sameKey, value: ts, map: &sameEpochSeen, order: &sameEpochOrder)
        return true
    }

    private func insert(key: String, value: Int64, map: inout [String: Int64], order: inout [String]) {
        if map[key] == nil {
            order.append(key)
        }
        map[key] = value
        while order.count > Self.maxEntries {
            let evict = order.removeFirst()
            map.removeValue(forKey: evict)
        }
    }

    /// Test-only reset — production code never needs this (state is
    /// meant to persist for the whole process lifetime).
    func resetForTesting() {
        maxEpochSeen.removeAll()
        maxEpochOrder.removeAll()
        sameEpochSeen.removeAll()
        sameEpochOrder.removeAll()
    }
}
