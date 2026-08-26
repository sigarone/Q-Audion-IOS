import Foundation
import QAudionEngine

/// W-GRPDEL (2026-08-02) — the persistent record of "this device deleted this
/// group chat".
///
/// ## Why this has to exist
///
/// Deleting the local rows is not enough. `AppState.reconcileAllGroupsFromServer`
/// runs on every chat-list appear and every WS reconnect, and the server's
/// catch-up burst replays the full roster on top of that. If the leave call
/// did not land — offline, 403, a timeout — the server still lists this user
/// as a member, and the deleted chat is re-bootstrapped within seconds, often
/// under the raw-hex bootstrap placeholder name. That is observed behaviour,
/// not a hypothetical.
///
/// So a delete writes a tombstone here, and every path that can re-create
/// local group state asks this store first (see `GroupResurrectionSource` /
/// `shouldSkipGroupResurrection` in the engine, which own the actual rules —
/// this file only holds the state).
///
/// ## Why it must be clearable
///
/// A tombstone that can never be lifted means the user can never be re-added
/// to that group on this device. It is cleared on an EXPLICIT re-add only —
/// an admin adding this user back (over the server fan-out or the P2P
/// envelope), an invite the user accepted, or the reconcile-time deduction
/// below. A passive listing never clears it; that is the whole point.
///
/// ## Why each record carries `serverLeaveOk`
///
/// The live `group_membership_changed` clear path only reaches a user who
/// holds a fresh WebSocket at the instant of the re-add — the server's
/// fan-out skips everybody else. So a user whose phone was off when an admin
/// re-added them would never see the event, and the tombstone would never
/// lift: locked out of that group on that device permanently.
///
/// `reconcileTombstoneDecision` (engine) closes that with no event at all,
/// but it needs one bit this store has to remember: did the server-side leave
/// actually succeed? Paired with what the server reports at reconcile time it
/// disambiguates the otherwise-ambiguous "the server still lists me":
/// confirmed leave + still listed ⇒ somebody re-added me (clear); unconfirmed
/// leave + still listed ⇒ my leave never landed (keep, and retry it).
/// `lastLeaveRetryAt` throttles that retry — the reconcile sweep runs on
/// every chat-list appear.
///
/// ## Storage
///
/// UserDefaults JSON, same trade-off `GroupRegistry` already documents: this
/// holds no secret material, only group ids the user chose to remove plus
/// when. Keyed by ``normalizedGroupTombstoneKey`` so the server's dashed-UUID
/// form and the local dash-stripped hex form can never disagree.
///
/// ## Concurrency
///
/// `@MainActor`, like `GroupRegistry` and `GroupMessageStore` — every caller
/// is on the AppState/SwiftUI main actor.
@MainActor
public final class GroupTombstoneStore: ObservableObject {

    /// One deleted group. `deletedAt` alone was the v1 shape; the two extra
    /// fields are what make the offline-proof re-add detection possible.
    public struct Record: Codable, Equatable, Sendable {
        /// When the user deleted the chat.
        public var deletedAt: Date
        /// Did `POST /groups/{gid}/leave` return 2xx? Set at delete time from
        /// the leave outcome, and flipped to `true` by a later successful
        /// retry. **False means the server still believes this user is a
        /// member** — which is precisely why "the server lists me" cannot be
        /// read as a re-add on its own.
        public var serverLeaveOk: Bool
        /// When the automatic leave retry last ran, for throttling. `nil`
        /// until it has run at all.
        public var lastLeaveRetryAt: Date?

        public init(deletedAt: Date, serverLeaveOk: Bool, lastLeaveRetryAt: Date? = nil) {
            self.deletedAt = deletedAt
            self.serverLeaveOk = serverLeaveOk
            self.lastLeaveRetryAt = lastLeaveRetryAt
        }
    }

    public static let shared = GroupTombstoneStore()

    private static let storageKey = "qaudion.groups.tombstones.v2"
    /// The v1 shape (`[String: Date]`, no leave outcome). Read once on load
    /// and migrated; never written again.
    private static let legacyStorageKeyV1 = "qaudion.groups.tombstones.v1"

    /// Bound so a user who churns through many groups cannot grow this
    /// without limit. Oldest entries are evicted first; an evicted tombstone
    /// only means that (very old) group could be resurrected by a reconcile
    /// again, which is a far better failure than an unbounded blob.
    private static let maxEntries = 500

    /// normalized group id → what we know about that delete.
    @Published public private(set) var entries: [String: Record] = [:]

    private init() { load() }

    private func load() {
        if let sealed = UserDefaults.standard.string(forKey: Self.storageKey) {
            guard let json = LocalStoreCipher.open(sealed),
                  let decoded = try? JSONDecoder().decode([String: Record].self, from: Data(json.utf8)) else {
                // Never silent: a sealed blob that fails to open (e.g. a
                // device restore, since the Keychain key does not migrate
                // across devices) falling through to legacy/empty state has
                // to be greppable — a quiet fall-through here is exactly the
                // "group resurrection" bug class this store exists to
                // prevent (see file header).
                RTLog.error("groupdel", "tombstone load failed to decrypt sealed blob — falling back to legacy/empty state")
                entries = Self.migrateLegacyV1()
                if !entries.isEmpty { persist() }
                return
            }
            entries = decoded
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            entries = decoded
            // Legacy plaintext v2 blob just read — convert it now rather than
            // waiting for the next mutation.
            persist()
            return
        }
        entries = Self.migrateLegacyV1()
        if !entries.isEmpty { persist() }
    }

    /// Read a v1 blob (`[String: Date]`) if one is still there.
    ///
    /// v1 recorded no leave outcome, so `serverLeaveOk` has to be assumed.
    /// **`false` is the conservative assumption**: it keeps the chat gone
    /// (what the user asked for) and makes the next reconcile RETRY the
    /// leave, which is harmless when the leave had in fact already succeeded
    /// — the server has answered already-left with 200 since commit 54c9f5d,
    /// so the retry just confirms the bit. Assuming `true` instead would read
    /// "the server still lists me" as a re-add and resurrect exactly the
    /// chats whose leave never landed, i.e. the original bug.
    private static func migrateLegacyV1() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKeyV1),
              let legacy = try? JSONDecoder().decode([String: Date].self, from: data),
              !legacy.isEmpty else {
            return [:]
        }
        var migrated: [String: Record] = [:]
        for (key, when) in legacy {
            migrated[key] = Record(deletedAt: when, serverLeaveOk: false)
        }
        UserDefaults.standard.removeObject(forKey: legacyStorageKeyV1)
        let n: String = String(describing: migrated.count)
        RTLog.info("groupdel", "tombstones migrated v1->v2 n=" + n)
        return migrated
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else {
            // Never silent: a tombstone that failed to persist means the
            // group comes back on the next launch, and that has to be
            // greppable when it happens.
            let n: String = String(describing: entries.count)
            RTLog.error("groupdel", "tombstone persist failed count=" + n)
            return
        }

        let attempt: String?? = try? LocalStoreCipher.seal(json)
        guard let unwrapped = attempt, let sealed = unwrapped else {
            let n: String = String(describing: entries.count)
            RTLog.error("groupdel", "tombstone persist deferred sealed=0 count=" + n)
            return
        }

        UserDefaults.standard.set(sealed, forKey: Self.storageKey)
    }

    /// SWIFT6_PATTERNS rules 1/3 — a single-overload, single-segment way to
    /// get the short group id every log line here uses.
    private static func short(_ key: String) -> String {
        return String(key.prefix(8))
    }

    // MARK: - Public API

    /// True when this device has deleted the group and no explicit re-add
    /// has since lifted the mark. Accepts either wire form of the id.
    public func isTombstoned(_ rawGroupId: String) -> Bool {
        let key = normalizedGroupTombstoneKey(rawGroupId)
        guard !key.isEmpty else { return false }
        return entries[key] != nil
    }

    /// Did the server confirm this user's departure?
    ///
    /// `false` for a group with no tombstone too — a caller asking this
    /// without a tombstone has no departure to confirm, and the reconcile
    /// decision ignores the bit in that case anyway.
    public func isServerLeaveConfirmed(_ rawGroupId: String) -> Bool {
        let key = normalizedGroupTombstoneKey(rawGroupId)
        guard !key.isEmpty else { return false }
        return entries[key]?.serverLeaveOk ?? false
    }

    /// When the automatic leave retry last ran for this group, for throttling.
    public func lastLeaveRetryAt(_ rawGroupId: String) -> Date? {
        let key = normalizedGroupTombstoneKey(rawGroupId)
        guard !key.isEmpty else { return nil }
        return entries[key]?.lastLeaveRetryAt
    }

    /// Record the delete. Idempotent — re-marking an already-tombstoned
    /// group refreshes its timestamp and its leave outcome.
    ///
    /// - Parameter serverLeaveOk: whether `POST /groups/{gid}/leave` returned
    ///   2xx. This is the bit `reconcileTombstoneDecision` later needs to
    ///   tell a genuine re-add apart from a leave that never landed, so it is
    ///   required rather than defaulted: guessing it wrong in either
    ///   direction produces a user-visible bug (a resurrected chat, or a
    ///   group the user can never be re-added to).
    public func mark(_ rawGroupId: String, serverLeaveOk: Bool, at when: Date = Date()) {
        let key = normalizedGroupTombstoneKey(rawGroupId)
        guard !key.isEmpty else {
            RTLog.warn("groupdel", "tombstone mark skipped: empty group id")
            return
        }
        // Preserve any retry stamp already on record so re-deleting a group
        // cannot reset the throttle into a hot loop.
        let previousRetry = entries[key]?.lastLeaveRetryAt
        entries[key] = Record(deletedAt: when, serverLeaveOk: serverLeaveOk,
                              lastLeaveRetryAt: previousRetry)
        evictOverflow()
        persist()
        let okFlag: String = serverLeaveOk ? "1" : "0"
        let line: String = "tombstone marked g=" + Self.short(key)
            + " serverLeaveOk=" + okFlag
            + " total=" + String(describing: entries.count)
        RTLog.info("groupdel", line)
    }

    /// Record that the automatic leave retry just ran, and what it achieved.
    ///
    /// No-op for a group with no tombstone: the retry only ever runs for one,
    /// and writing a record here would invent a tombstone out of a network
    /// call. Once `serverLeaveOk` is true it is never flipped back — the
    /// server has recorded the departure, and a later transport failure does
    /// not undo that fact.
    public func noteLeaveRetry(_ rawGroupId: String, serverLeaveOk: Bool, at when: Date = Date()) {
        let key = normalizedGroupTombstoneKey(rawGroupId)
        guard !key.isEmpty, var record = entries[key] else {
            RTLog.debug("groupdel", "retry note skipped g=" + Self.short(key))
            return
        }
        record.lastLeaveRetryAt = when
        if serverLeaveOk { record.serverLeaveOk = true }
        entries[key] = record
        persist()
        let okFlag: String = record.serverLeaveOk ? "1" : "0"
        let line: String = "retry noted g=" + Self.short(key) + " serverLeaveOk=" + okFlag
        RTLog.info("groupdel", line)
    }

    /// Lift the mark. Callers MUST have an explicit re-add signal — see
    /// ``clearsGroupTombstone``. No-op (and logged as such) when the group
    /// was not tombstoned, so an unnecessary clear is visible rather than
    /// invisible.
    public func clear(_ rawGroupId: String, reason: String) {
        let key = normalizedGroupTombstoneKey(rawGroupId)
        guard !key.isEmpty else {
            RTLog.warn("groupdel", "tombstone clear skipped: empty group id")
            return
        }
        guard entries.removeValue(forKey: key) != nil else {
            let noop: String = "tombstone clear no-op g=" + Self.short(key) + " why=" + reason
            RTLog.debug("groupdel", noop)
            return
        }
        persist()
        let line: String = "tombstone cleared g=" + Self.short(key) + " why=" + reason
        RTLog.info("groupdel", line)
    }

    /// Drop every tombstone. Only for a full local wipe / account switch —
    /// there is no user-facing "undelete all".
    public func clearAll() {
        guard !entries.isEmpty else { return }
        let n: String = String(describing: entries.count)
        entries = [:]
        persist()
        RTLog.info("groupdel", "tombstones cleared all n=" + n)
    }

    private func evictOverflow() {
        guard entries.count > Self.maxEntries else { return }
        let sorted = entries.sorted { $0.value.deletedAt < $1.value.deletedAt }
        let dropCount = entries.count - Self.maxEntries
        for (key, _) in sorted.prefix(dropCount) {
            entries.removeValue(forKey: key)
        }
        let n: String = String(describing: dropCount)
        RTLog.warn("groupdel", "tombstone overflow evicted=" + n)
    }
}
