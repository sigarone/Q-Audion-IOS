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
    /// `enqueue` or the drain's `remove`). The setter fails closed: if the
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
    private var entries: [Entry] {
        get {
            if let sealed = UserDefaults.standard.string(forKey: defaultsKey),
               let json = LocalStoreCipher.open(sealed),
               let decoded = try? JSONDecoder().decode([Entry].self, from: Data(json.utf8)) {
                return decoded
            }
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else { return }
            let attempt: String?? = try? LocalStoreCipher.seal(json)
            guard let unwrapped = attempt, let sealed = unwrapped else { return }
            UserDefaults.standard.set(sealed, forKey: defaultsKey)
        }
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
    /// same batch, is skipped; nothing is written when nothing was appended.
    public func enqueue(contentsOf newEntries: [Entry]) {
        guard !newEntries.isEmpty else { return }
        var current: [Entry] = entries
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
        entries = current
    }

    /// Pending entries, oldest first, with anything past `maxAgeMs` already
    /// excluded (a receipt is a courtesy signal — resending a day-old one is
    /// pointless, not worth a separate prune pass).
    public func drainable(nowMs: Int64) -> [Entry] {
        entries.filter { nowMs - $0.createdAtMs < maxAgeMs }
               .sorted { $0.createdAtMs < $1.createdAtMs }
    }

    public func remove(_ entry: Entry) {
        remove(contentsOf: [entry])
    }

    /// Removes every stored entry equal to any of `doomed` with ONE read and
    /// ONE write of the sealed blob (the drain used to call `remove(_:)` per
    /// entry: one Keychain read + AES-GCM open/seal + whole-list JSON
    /// decode/encode each, on the main actor). Matching is full `Entry`
    /// equality, exactly like the single-entry form.
    public func remove(contentsOf doomed: [Entry]) {
        guard !doomed.isEmpty else { return }
        let doomedSet: Set<Entry> = Set(doomed)
        let current: [Entry] = entries
        let remaining: [Entry] = current.filter { !doomedSet.contains($0) }
        entries = remaining
    }
}
