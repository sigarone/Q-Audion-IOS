import Foundation
import QAudionEngine

/// W-GRPRECEIPTOUTBOX (2026-09-15, audit
/// reference_ios_full_audit_2026_09_15.md finding #5) — durable retry for
/// group `group_msg_delivered`/`group_msg_read` receipts that a WS gap would
/// otherwise drop forever. 1:1 already has this (`ChatOutboxStore
/// .enqueueDeliveryReceipt`, GRDB-backed); group chat had nothing, so a
/// receipt lost to a socket blip left the sender's tick stuck until the next
/// unrelated event happened to re-sync it. UserDefaults-JSON persisted, same
/// idiom as `GroupMessageStore` — receipts are small and low-volume, and
/// additive-optional-field evolution needs no migration ceremony here either.
///
/// Typing indicators are deliberately NOT covered: a typing signal delayed
/// past a WS gap is stale by the time it could be resent, so queuing it would
/// misinform the peer rather than help — 1:1 doesn't persist typing either.
public final class GroupReceiptOutbox {
    public static let shared = GroupReceiptOutbox()

    public struct Entry: Codable, Equatable, Hashable {
        public static let kindDelivered = "delivered"
        public static let kindRead = "read"

        public let kind: String
        /// Dashed-UUID wire form, matching what `group_msg_delivered`/
        /// `group_msg_read` already send.
        public let groupId: String
        public let serverMessageId: String
        public let createdAtMs: Int64
    }

    private let defaultsKey = "qaudion.group_receipt_outbox.v1"
    /// A receipt this stale is pointless to resend — same order of magnitude
    /// as `OutboxRetryPolicy`'s own give-up window.
    private let maxAgeMs: Int64 = 24 * 60 * 60 * 1000

    /// At-rest protection: the persisted form is the same `LocalStoreCipher`
    /// sealed String `GroupMessageStore` and `ComposerDraftStore` use (group
    /// ids + server message ids + timestamps are social-graph / read-timing
    /// metadata and used to sit in the UserDefaults plist in the clear). A
    /// legacy plaintext `Data` blob written by earlier builds is still read
    /// (it is re-persisted sealed by the next mutation, i.e. the next
    /// `enqueue` or the drain's `remove`). The writer fails closed: if the
    /// Keychain key is unreachable nothing is written and the previous value
    /// stays.
    ///
    /// Cost model: every get is a Keychain read + AES-GCM open + JSON decode
    /// of the WHOLE list, every set the mirror image. So public mutators do
    /// exactly ONE get and (at most) ONE set per call, and callers holding
    /// many entries (a group opened offline can queue hundreds of read
    /// receipts, the drain removes them all) use the batch entry points
    /// `enqueue(contentsOf:)` / `enqueue(kind:groupId:serverMessageIds:nowMs:)`
    /// / `remove(contentsOf:)` instead of looping the single-entry ones.
    /// There is no lock: the only callers are on `AppState` (`@MainActor`), so
    /// a read-modify-write here is never interleaved with another one.
    ///
    /// A stored value that cannot be read back (the sealed blob does not open
    /// or does not decode, or a legacy blob does not decode) is a FAILED read,
    /// not an empty outbox: `loadEntries()` returns nil, the failure is
    /// logged, and every mutator leaves the stored bytes untouched instead of
    /// overwriting them with a list built from nothing. `drainable` reports
    /// nothing to send while the value is unreadable.
    ///
    /// Safety valve (`UnreadableStoredValueValve`): a value that stays
    /// unreadable would block the outbox forever and every new receipt would be
    /// dropped instead of queued. The first failed read records its instant in
    /// a companion UserDefaults key; any successful read (including "nothing
    /// stored") clears it. A value that has been unreadable without a single
    /// success for longer than `maxAgeMs` is moved under a companion quarantine
    /// key (only the latest one is kept, never deleted) and the outbox starts
    /// empty. Nothing deliverable is lost by that: the bytes cannot change
    /// while unreadable, so by then every receipt in them is past `maxAgeMs`
    /// and `drainable` would skip it anyway. Shorter failures (a key that is
    /// briefly unavailable) never get near the window.
    private func loadEntries() -> [Entry]? {
        if let sealed = UserDefaults.standard.string(forKey: defaultsKey) {
            guard let json = LocalStoreCipher.open(sealed),
                  let decoded = try? JSONDecoder().decode([Entry].self, from: Data(json.utf8)) else {
                RTLog.error("group", "grp_receipt unseal fail retained=1")
                return recoverUnreadable()
            }
            valve.noteReadable()
            return decoded
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            guard let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
                RTLog.error("group", "grp_receipt decode fail retained=1")
                return recoverUnreadable()
            }
            valve.noteReadable()
            return decoded
        }
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            // Something is stored under this key but it is neither a sealed
            // String nor a legacy Data blob (e.g. an Int, Bool, or array —
            // any other UserDefaults plist-compatible type). That is a
            // type-mismatched/corrupt outbox, not an empty one: treating it
            // as readable here would clear the valve's failure window and
            // let the next enqueue silently overwrite it.
            RTLog.error("group", "grp_receipt type mismatch retained=1")
            return recoverUnreadable()
        }
        valve.noteReadable()
        return []
    }

    private var valve: UnreadableStoredValueValve {
        UnreadableStoredValueValve(valueKey: defaultsKey, maxAgeMs: maxAgeMs)
    }

    /// Applies the safety valve to a value that was just observed unreadable.
    /// nil = still blocked, the stored bytes were not touched; an empty list =
    /// the bytes were quarantined and the outbox starts empty.
    private func recoverUnreadable() -> [Entry]? {
        let nowSeconds: Double = Date().timeIntervalSince1970
        let nowMs: Int64 = Int64(nowSeconds * 1000)
        let outcome: UnreadableStoredValueValve.Outcome = valve.noteUnreadable(nowMs: nowMs)
        switch outcome {
        case .blocked:
            return nil
        case .quarantined:
            RTLog.warn("group", "grp_receipt reset=stale retained=1")
            return []
        case .quarantineFailed:
            RTLog.error("group", "grp_receipt reset=fail retained=1")
            return nil
        }
    }

    private func storeEntries(_ newValue: [Entry]) {
        guard let data = try? JSONEncoder().encode(newValue),
              let json = String(data: data, encoding: .utf8) else { return }
        let attempt: String?? = try? LocalStoreCipher.seal(json)
        guard let unwrapped = attempt, let sealed = unwrapped else { return }
        UserDefaults.standard.set(sealed, forKey: defaultsKey)
    }

    /// Dedup identity of a queued receipt: the same receipt (kind + group +
    /// message) is never queued twice, whatever its `createdAtMs`.
    private struct EntryKey: Hashable {
        let kind: String
        let groupId: String
        let serverMessageId: String

        init(_ entry: Entry) {
            self.kind = entry.kind
            self.groupId = entry.groupId
            self.serverMessageId = entry.serverMessageId
        }
    }

    public func enqueue(kind: String, groupId: String, serverMessageId: String, nowMs: Int64) {
        let entry = Entry(kind: kind, groupId: groupId, serverMessageId: serverMessageId, createdAtMs: nowMs)
        enqueue(contentsOf: [entry])
    }

    /// Batch form of `enqueue(kind:groupId:serverMessageId:nowMs:)` for one
    /// kind + group + timestamp and many message ids (`emitGroupReadReceipts`
    /// while the socket is down). One sealed read-modify-write for the whole
    /// list instead of one per id.
    public func enqueue(kind: String, groupId: String, serverMessageIds: [String], nowMs: Int64) {
        var batch: [Entry] = []
        batch.reserveCapacity(serverMessageIds.count)
        for serverMessageId in serverMessageIds {
            let entry = Entry(kind: kind, groupId: groupId, serverMessageId: serverMessageId, createdAtMs: nowMs)
            batch.append(entry)
        }
        enqueue(contentsOf: batch)
    }

    /// Appends every entry of `newEntries` that is not already queued, in the
    /// given order, with ONE read and ONE write of the sealed blob. Same
    /// dedup as the old per-entry loop: an entry equal (kind + groupId +
    /// serverMessageId) to one already stored, or to an earlier entry of the
    /// same batch, is skipped; nothing is written when nothing was appended,
    /// nor when the stored value is unreadable (the batch is dropped rather
    /// than replacing the unreadable bytes — see `loadEntries()`).
    public func enqueue(contentsOf newEntries: [Entry]) {
        guard !newEntries.isEmpty else { return }
        guard var current = loadEntries() else { return }
        var known = Set<EntryKey>()
        for existing in current {
            known.insert(EntryKey(existing))
        }
        var appended = false
        for candidate in newEntries {
            let outcome = known.insert(EntryKey(candidate))
            if outcome.inserted {
                current.append(candidate)
                appended = true
            }
        }
        guard appended else { return }
        storeEntries(current)
    }

    /// Pending entries, oldest first, with anything past `maxAgeMs` already
    /// excluded (a receipt is a courtesy signal — resending a day-old one is
    /// pointless, not worth a separate prune pass).
    public func drainable(nowMs: Int64) -> [Entry] {
        guard let current = loadEntries() else { return [] }
        return current.filter { nowMs - $0.createdAtMs < maxAgeMs }
                      .sorted { $0.createdAtMs < $1.createdAtMs }
    }

    public func remove(_ entry: Entry) {
        remove(contentsOf: [entry])
    }

    /// Removes every stored entry equal to any of `doomed` with ONE read and
    /// ONE write of the sealed blob (the drain used to call `remove(_:)` per
    /// entry: one Keychain read + AES-GCM open/seal + whole-list JSON
    /// decode/encode each, on the main actor). Matching is full `Entry`
    /// equality, exactly like the single-entry form. Nothing is written when
    /// the stored value is unreadable (see `loadEntries()`).
    public func remove(contentsOf doomed: [Entry]) {
        guard !doomed.isEmpty else { return }
        let doomedSet: Set<Entry> = Set(doomed)
        guard let current = loadEntries() else { return }
        let remaining: [Entry] = current.filter { !doomedSet.contains($0) }
        storeEntries(remaining)
    }
}
