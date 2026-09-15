import Foundation

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

    public struct Entry: Codable, Equatable {
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

    private var entries: [Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    public func enqueue(kind: String, groupId: String, serverMessageId: String, nowMs: Int64) {
        var current = entries
        guard !current.contains(where: {
            $0.kind == kind && $0.groupId == groupId && $0.serverMessageId == serverMessageId
        }) else { return }
        current.append(Entry(kind: kind, groupId: groupId, serverMessageId: serverMessageId, createdAtMs: nowMs))
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
        entries = entries.filter { $0 != entry }
    }
}
