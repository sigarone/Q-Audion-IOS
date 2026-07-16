import Foundation

/// W-GRPMSG — persistent local store for group TEXT messages
/// (both the sender's optimistic bubbles AND decrypted inbound text).
///
/// Before the `group_msg_*` server transport was wired, the group chat
/// UI kept messages in ephemeral SwiftUI `@State` (the old "Beta"
/// banner). Now that `GroupChatScreen` sends via `group_msg_send` and
/// AppState receives via `group_msg_receive` / `group_msg_pending_sync`,
/// both directions must survive to the next time the screen opens —
/// mirroring how 1:1 chat persists via `ConversationStore`.
///
/// **Storage:** UserDefaults JSON keyed by group id HEX (the same key
/// space `GroupChatService` / `GroupRegistry` use — NOT the dashed
/// UUID). Same trade-off as `GroupRegistry`: adequate for local
/// plaintext history (no key material; the plaintext here is no more
/// sensitive than the 1:1 `ConversationStore`).
///
/// **Concurrency:** `@MainActor` — owned by the AppState receive path
/// and the `GroupChatScreen` send path, both main-actor.
@MainActor
public final class GroupMessageStore: ObservableObject {

    public static let shared = GroupMessageStore()

    /// Posted after any successful `append` / `bindServerId`.
    /// `userInfo["groupHex"]` lets an open `GroupChatScreen` reload only
    /// for its own group.
    public static let didChangeNotification =
        Notification.Name("qaudion.group.messages.didChange")

    public struct Stored: Codable, Equatable, Identifiable {
        /// Stable id = `clientMsgId` (survives the server self-echo so
        /// the sender's optimistic row is never duplicated).
        public let id: String
        public var serverMessageId: String?
        public let senderId: String
        public let mine: Bool
        /// For an attachment row this holds the (optional) caption — an
        /// empty string when the attachment has no caption. For a plain
        /// text message it is the message body, exactly as before.
        public let text: String
        public let ts: Date
        // Fase 1B — group attachment fields. All nil for a plain text row,
        // so old persisted JSON (which lacks these keys) decodes unchanged
        // via Swift's synthesized `decodeIfPresent` for optionals.
        /// "image" | "file" when this row is an attachment; nil = text.
        public let attachmentKind: String?
        public let mediaMime: String?
        public let fileName: String?
        public let byteLength: Int64?
        /// Decrypted local blob path once downloaded (sender stamps it up
        /// front; receiver stamps it after the async download completes).
        public var mediaLocalPath: String?
        /// The raw 0xE4 descriptor JSON, retained so a failed download can
        /// be retried without re-fetching the group frame.
        public let descriptorJson: String?
        // Fase 2 — per-member receipt tracking, meaningful ONLY on our own
        // (`mine == true`) outbound rows: the userIds of OTHER members who
        // have ACKed `group_msg_delivered` / `group_msg_read` for this
        // message (via the server's targeted `group_msg_receipt`, see
        // groups_receipts.go). nil/empty on inbound rows and on old
        // persisted JSON predating this field — decodes to nil via Swift's
        // synthesized Decodable (missing key ⇒ nil for an Optional
        // property), same trade-off as the Fase 1B attachment fields above.
        public var deliveredBy: [String]?
        public var readBy: [String]?
        // Export-permission + group-TTL fields — GROUP counterpart of
        // Message's expiresAt/isViewOnce/viewOnceOpened/exportBlocked.
        // Group had NO TTL/view-once concept before this; nil for every
        // pre-existing row and for every plain-text row (the concept only
        // applies to attachments). Old persisted JSON lacking these keys
        // decodes unchanged via Swift's synthesized `decodeIfPresent` for
        // Optionals — same additive-field contract already documented
        // above for `deliveredBy`/`readBy` and the Fase 1B attachment
        // fields, no separate migration mechanism needed (this store is
        // a UserDefaults JSON blob, not GRDB).
        /// UTC timestamp at which this row auto-deletes locally. Resolved
        /// via the SAME ``AttachmentTimerResolver`` the 1:1 path uses (no
        /// group-specific reimplementation of the precedence rule).
        public var expiresAt: Date?
        /// nil = false for backward compat with older stored rows.
        public var isViewOnce: Bool?
        /// True once the user has tapped to reveal a view-once row.
        public var viewOnceOpened: Bool?
        /// Mirrors ``Message/exportBlocked`` — nil/false = export allowed
        /// (today's behavior); true = the sender marked this attachment
        /// export-blocked. Client-side/UI honor-system signal only.
        public var exportBlocked: Bool?

        public init(id: String, serverMessageId: String?, senderId: String,
                    mine: Bool, text: String, ts: Date,
                    attachmentKind: String? = nil, mediaMime: String? = nil,
                    fileName: String? = nil, byteLength: Int64? = nil,
                    mediaLocalPath: String? = nil, descriptorJson: String? = nil,
                    deliveredBy: [String]? = nil, readBy: [String]? = nil,
                    expiresAt: Date? = nil, isViewOnce: Bool? = nil,
                    viewOnceOpened: Bool? = nil, exportBlocked: Bool? = nil) {
            self.id = id
            self.serverMessageId = serverMessageId
            self.senderId = senderId
            self.mine = mine
            self.text = text
            self.ts = ts
            self.attachmentKind = attachmentKind
            self.mediaMime = mediaMime
            self.fileName = fileName
            self.byteLength = byteLength
            self.mediaLocalPath = mediaLocalPath
            self.descriptorJson = descriptorJson
            self.deliveredBy = deliveredBy
            self.readBy = readBy
            self.expiresAt = expiresAt
            self.isViewOnce = isViewOnce
            self.viewOnceOpened = viewOnceOpened
            self.exportBlocked = exportBlocked
        }
    }

    /// groupHex → chronological messages (oldest first).
    private var byGroup: [String: [Stored]] = [:]
    /// Fase 1B — groupHex → wall-clock of the newest message the user has
    /// seen (set when a `GroupChatScreen` for that group is open). Mirrors
    /// the 1:1 `Conversation.unreadCount` read-marker, but derived rather
    /// than a stored counter (the group message list is the source of truth).
    private var lastRead: [String: Date] = [:]
    private static let storageKey = "qaudion.groups.messages.v1"
    private static let readStorageKey = "qaudion.groups.messages.lastread.v1"
    private static let maxPerGroup = 500

    private init() { load() }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: [Stored]].self, from: data) {
            byGroup = decoded
        } else {
            byGroup = [:]
        }
        if let data = UserDefaults.standard.data(forKey: Self.readStorageKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastRead = decoded
        } else {
            lastRead = [:]
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(byGroup) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func persistReadMarkers() {
        guard let data = try? JSONEncoder().encode(lastRead) else { return }
        UserDefaults.standard.set(data, forKey: Self.readStorageKey)
    }

    // MARK: - Reads

    public func messages(forGroupHex groupHex: String) -> [Stored] {
        return byGroup[groupHex] ?? []
    }

    /// Fase 1B — newest message for the chat-list row preview/timestamp.
    public func lastMessage(forGroupHex groupHex: String) -> Stored? {
        return byGroup[groupHex]?.last
    }

    /// Fase 1B — number of inbound (non-mine) messages newer than the last
    /// time the user opened this group. Mirrors the 1:1 unread badge, but
    /// derived from the message list + a read-marker instead of a stored
    /// counter (the server does not push a per-group unread count to iOS).
    public func unreadCount(forGroupHex groupHex: String) -> Int {
        guard let arr = byGroup[groupHex] else { return 0 }
        let since = lastRead[groupHex] ?? .distantPast
        return arr.reduce(0) { acc, m in
            (!m.mine && m.ts > since) ? acc + 1 : acc
        }
    }

    /// True if a message with this server id is already persisted — used
    /// to short-circuit the server's re-delivery of an already-consumed
    /// message (crypto replay would reject it anyway, but this keeps
    /// re-deliveries out of the retry buffer).
    public func contains(groupHex: String, serverMessageId: String) -> Bool {
        guard let arr = byGroup[groupHex] else { return false }
        return arr.contains(where: { $0.serverMessageId == serverMessageId })
    }

    // MARK: - Writes

    /// Insert a message, deduped by `id` (clientMsgId) and by
    /// `serverMessageId`. Returns true only when a NEW row is inserted
    /// (false when it merged into / duplicated an existing row).
    @discardableResult
    public func append(groupHex: String, _ msg: Stored) -> Bool {
        var arr = byGroup[groupHex] ?? []
        if let idx = arr.firstIndex(where: { existing in
            existing.id == msg.id ||
            (msg.serverMessageId != nil && existing.serverMessageId == msg.serverMessageId)
        }) {
            // Merge: fill serverMessageId if we just learned it.
            if arr[idx].serverMessageId == nil, let sid = msg.serverMessageId {
                arr[idx].serverMessageId = sid
                byGroup[groupHex] = arr
                persist()
                postDidChange(groupHex)
            }
            return false
        }
        arr.append(msg)
        if arr.count > Self.maxPerGroup {
            arr.removeFirst(arr.count - Self.maxPerGroup)
        }
        byGroup[groupHex] = arr
        persist()
        postDidChange(groupHex)
        return true
    }

    /// Bind the server-assigned id to the sender's optimistic row (the
    /// self-echo path). No-op if `clientMsgId` is unknown or already set.
    public func bindServerId(groupHex: String, clientMsgId: String, serverMessageId: String) {
        guard var arr = byGroup[groupHex],
              let idx = arr.firstIndex(where: { $0.id == clientMsgId }),
              arr[idx].serverMessageId != serverMessageId else { return }
        arr[idx].serverMessageId = serverMessageId
        byGroup[groupHex] = arr
        persist()
        postDidChange(groupHex)
    }

    /// Fase 2 — record one member's `delivered`/`read` receipt against our
    /// own outbound row (matched by `serverMessageId`, since the receipt
    /// only ever carries the server id, never our local `clientMsgId`).
    /// No-op if the message is unknown locally, is not one of OUR rows
    /// (a receipt should never land on somebody else's message — the
    /// server itself only ever targets the original sender, but stay
    /// defensive), or the member is already recorded for this status
    /// (idempotent — a duplicate/replayed receipt is a silent no-op).
    public func recordReceipt(groupHex: String, serverMessageId: String, memberUserId: String, status: String) {
        guard var arr = byGroup[groupHex],
              let idx = arr.firstIndex(where: { $0.serverMessageId == serverMessageId }),
              arr[idx].mine else { return }
        switch status {
        case "read":
            var readers = Set(arr[idx].readBy ?? [])
            guard !readers.contains(memberUserId) else { return }
            readers.insert(memberUserId)
            arr[idx].readBy = Array(readers)
        case "delivered":
            var deliverers = Set(arr[idx].deliveredBy ?? [])
            guard !deliverers.contains(memberUserId) else { return }
            deliverers.insert(memberUserId)
            arr[idx].deliveredBy = Array(deliverers)
        default:
            return
        }
        byGroup[groupHex] = arr
        persist()
        postDidChange(groupHex)
    }

    /// Fase 1B — stamp the decrypted local blob path onto an attachment
    /// row once the async download completes. Matched by `id` (clientMsgId)
    /// first, then `serverMessageId`. No-op if unknown or already set.
    public func setMediaPath(groupHex: String, id: String, path: String) {
        guard var arr = byGroup[groupHex],
              let idx = arr.firstIndex(where: { $0.id == id || $0.serverMessageId == id }),
              arr[idx].mediaLocalPath != path else { return }
        arr[idx].mediaLocalPath = path
        byGroup[groupHex] = arr
        persist()
        postDidChange(groupHex)
    }

    /// Fase 1B — mark this group as read up to its newest message (called
    /// when a `GroupChatScreen` for the group is open / receives). Idempotent:
    /// a no-op (no persist / no didChange) when already current, so the
    /// reload → markRead → didChange → reload cycle terminates immediately.
    public func markRead(groupHex: String) {
        // No messages ⇒ nothing to read; return WITHOUT setting a marker.
        // A `?? Date()` fallback here would advance `newest` on every call
        // (wall-clock keeps moving), so `cur >= newest` never holds and each
        // markRead posts didChange → an open GroupChatScreen reloads → calls
        // markRead again → infinite loop (hit on the common path of opening a
        // freshly-created, still-empty group). Guarding on a real message ts
        // makes the marker a fixed value, so the cycle terminates in one hop.
        guard let newest = byGroup[groupHex]?.last?.ts else { return }
        if let cur = lastRead[groupHex], cur >= newest { return }
        lastRead[groupHex] = newest
        persistReadMarkers()
        postDidChange(groupHex)
    }

    // MARK: - Ephemeral timers (W-XPTTL)

    /// Delete all messages (across every group) whose `expiresAt` is
    /// non-nil and in the past, called by `EphemeralMessageJanitor` every
    /// 60s alongside the 1:1 sweep.
    ///
    /// Mirrors `ConversationStore.deleteExpiredMessages()`'s exact
    /// capture-then-remove + best-effort disk cleanup contract (W612):
    /// this store had NO expiry sweep at all before this field — TTL is
    /// meaningless without one. Cached attachment blobs (a decrypted
    /// TTL/view-once photo/file in the sender's `writeLocalCopy` temp dir
    /// or the receiver's download cache) are captured BEFORE the rows are
    /// dropped from `byGroup`, then best-effort removed from disk AFTER
    /// the in-memory removal + `persist()` — a missing file or filesystem
    /// error is logged and swallowed, never blocks the sweep.
    public func deleteExpiredMessages() {
        let now = Date()
        var cachedPathsToRemove: [String] = []
        var changedGroupHexes: [String] = []
        // Snapshot the keys first — mutating `byGroup` while iterating
        // it directly is unnecessary risk to reason about; iterating a
        // separate `[String]` snapshot is unambiguous.
        for groupHex in Array(byGroup.keys) {
            guard let arr = byGroup[groupHex] else { continue }
            let expired = arr.filter { msg in
                guard let exp = msg.expiresAt else { return false }
                return exp <= now
            }
            guard !expired.isEmpty else { continue }
            cachedPathsToRemove.append(contentsOf: expired.compactMap { $0.mediaLocalPath }.filter { !$0.isEmpty })
            let remaining = arr.filter { msg in
                guard let exp = msg.expiresAt else { return true }
                return exp > now
            }
            byGroup[groupHex] = remaining
            changedGroupHexes.append(groupHex)
        }
        guard !changedGroupHexes.isEmpty else { return }
        persist()
        // Rows are committed to UserDefaults — now best-effort reclaim the
        // cached blobs. Never propagate failures here: the row removal
        // already succeeded.
        for path in cachedPathsToRemove {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            } catch {
                print("[GroupMessageStore] deleteExpiredMessages: cache cleanup failed for \(path): \(error)")
            }
        }
        // Notify every open GroupChatScreen/GroupCallChatPanel so a
        // swept row disappears from the currently-visible list — same
        // notification `append`/`bindServerId`/etc. already post, no new
        // observer wiring needed on the UI side.
        for groupHex in changedGroupHexes {
            postDidChange(groupHex)
        }
    }

    public func clear(groupHex: String) {
        guard byGroup[groupHex] != nil else { return }
        byGroup.removeValue(forKey: groupHex)
        if lastRead.removeValue(forKey: groupHex) != nil { persistReadMarkers() }
        persist()
        postDidChange(groupHex)
    }

    private func postDidChange(_ groupHex: String) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: ["groupHex": groupHex])
    }
}
