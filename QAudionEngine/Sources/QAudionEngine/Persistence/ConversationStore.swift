import Foundation
import GRDB

/// Local persistence for conversation list + message history.
///
/// **Storage.** SQLite (GRDB) with `secure_delete` + `auto_vacuum`, the file
/// carrying the iOS Data Protection class
/// `completeUntilFirstUserAuthentication`. Migrates from legacy plaintext
/// UserDefaults on first run.
///
/// This comment used to claim "SQLCipher-encrypted SQLite". It was never
/// true — `QAudionDatabase` says so in its own header ("GRDB-SQLCipher is
/// not available as an SPM product ... deferred to a future sprint") — and a
/// false claim of encryption in the one place a reader looks for it is worse
/// than no claim at all. What IS true since 2026-08-02: message bodies and
/// the conversation preview are sealed field-by-field with a device-held
/// AES-256-GCM key before they reach a row (`LocalStoreCipher`), so the
/// content is encrypted at rest even though the surrounding database file
/// is not. Non-content metadata (timestamps, status, ids) stays in the
/// clear so the list can still be ordered and filtered without unsealing
/// anything.
public final class ConversationStore {

    private let db: QAudionDatabase
    private let defaults: UserDefaults
    private let decoder: JSONDecoder

    public init(db: QAudionDatabase = .shared, defaults: UserDefaults = .standard) {
        self.db = db
        self.defaults = defaults
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = d

        // One-time migration from UserDefaults
        migrateIfNeeded()
        // W-MSGATREST (2026-08-02) — one-time seal of rows written before
        // message bodies were encrypted at rest.
        sealExistingRowsIfNeeded()
    }

    private static let atRestMigrationKey = "qaudion.store.atrest.v1.done"

    /// Rewrites every existing message and conversation row so the mapper
    /// seals its content column. Reading a legacy row returns the plaintext
    /// verbatim (no marker) and saving it back runs it through
    /// `LocalStoreCipher`, so a plain fetch-all/save-all is the whole
    /// migration — no bespoke SQL, no second code path that could disagree
    /// with the mapper about the format.
    ///
    /// The done-flag is set ONLY after the write actually succeeds. If the
    /// Keychain key is unreachable (first launch after a reboot, before the
    /// device has been unlocked once) `seal` throws, the transaction rolls
    /// back untouched, and the next launch tries again — rather than marking
    /// the migration done over a history that is still in the clear.
    private func sealExistingRowsIfNeeded() {
        guard !defaults.bool(forKey: Self.atRestMigrationKey) else { return }
        do {
            try db.writer.write { db in
                for msg in try Message.fetchAll(db) {
                    try msg.save(db)
                }
                for conv in try Conversation.fetchAll(db) {
                    try conv.save(db)
                }
            }
            defaults.set(true, forKey: Self.atRestMigrationKey)
        } catch {
            print("[ConversationStore] at-rest seal migration deferred: \(error)")
        }
    }

    private static let conversationsKey = "qaudion.conv.list"
    private static func messagesKey(for cid: UUID) -> String {
        return "qaudion.conv.msgs.\(cid.uuidString.lowercased())"
    }

    // MARK: - Conversations

    public func loadConversations() -> [Conversation] {
        do {
            let convs = try db.reader.read { db in
                try Conversation.order(Column("lastActivity").desc).fetchAll(db)
            }
            // Reverse the nil→"" coercion applied at write time so callers see
            // nil (not Optional("")) for conversations with no preview yet.
            return convs.map { conv in
                guard conv.lastMessagePreview == "" else { return conv }
                return Conversation(id: conv.id, peerUserId: conv.peerUserId,
                                    peerDisplayName: conv.peerDisplayName,
                                    lastMessagePreview: nil,
                                    lastActivity: conv.lastActivity,
                                    unreadCount: conv.unreadCount, pinned: conv.pinned,
                                    kind: conv.kind, muted: conv.muted,
                                    ephemeralTimerSeconds: conv.ephemeralTimerSeconds,
                                    screenshotGrantedByPeer: conv.screenshotGrantedByPeer)
            }
        } catch {
            print("[ConversationStore] loadConversations failed: \(error)")
            return []
        }
    }

    public func upsertConversation(_ conv: Conversation) {
        // The `conversations.lastMessagePreview` column is NOT NULL (migration v1),
        // but the model allows nil (a brand-new conversation with no messages yet).
        // GRDB writes nil as NULL → "NOT NULL constraint failed" → the whole insert
        // is dropped, so creating a chat from a contact / call-history / fresh
        // conversation silently fails. Coerce nil → "" at the single storage
        // chokepoint so no caller (present or future) can trip the constraint.
        let safe: Conversation
        if conv.lastMessagePreview == nil {
            safe = Conversation(
                id: conv.id, peerUserId: conv.peerUserId,
                peerDisplayName: conv.peerDisplayName,
                lastMessagePreview: "",
                lastActivity: conv.lastActivity,
                unreadCount: conv.unreadCount, pinned: conv.pinned,
                kind: conv.kind, muted: conv.muted,
                ephemeralTimerSeconds: conv.ephemeralTimerSeconds,
                screenshotGrantedByPeer: conv.screenshotGrantedByPeer
            )
        } else {
            safe = conv
        }
        do {
            try db.writer.write { db in
                try safe.save(db)
            }
        } catch {
            // saved=0 is the greppable marker. The engine module has no
            // access to RTLog (it lives in the app target), but the app tees
            // stdout into the ring buffer under the allow-listed "stdout"
            // tag, so this does reach a log pull. It matters because a
            // sealed-store write can legitimately fail — before the first
            // unlock after a reboot the key is unreachable — and a lost
            // conversation row must not be silent.
            print("[ConversationStore] upsertConversation saved=0 error: \(error)")
        }
    }

    public func deleteConversation(id: UUID) {
        do {
            _ = try db.writer.write { db in
                try Conversation.filter(key: id).deleteAll(db)
                // messages are deleted via cascade
            }
        } catch {
            print("[ConversationStore] deleteConversation failed: \(error)")
        }
    }

    public func recordNewMessage(conversationId id: UUID,
                                 lastMessagePreview: String,
                                 lastActivity: Date,
                                 incrementUnread: Bool) {
        do {
            try db.writer.write { db in
                if var conv = try Conversation.fetchOne(db, key: id) {
                    let truncated = lastMessagePreview.count > 120
                        ? String(lastMessagePreview.prefix(120)) + "…"
                        : lastMessagePreview

                    conv = Conversation(
                        id: conv.id,
                        peerUserId: conv.peerUserId,
                        peerDisplayName: conv.peerDisplayName,
                        lastMessagePreview: truncated,
                        lastActivity: lastActivity,
                        unreadCount: incrementUnread ? conv.unreadCount + 1 : conv.unreadCount,
                        pinned: conv.pinned,
                        kind: conv.kind,
                        muted: conv.muted,
                        ephemeralTimerSeconds: conv.ephemeralTimerSeconds
                    )
                    try conv.save(db)
                }
            }
        } catch {
            print("[ConversationStore] recordNewMessage failed: \(error)")
        }
    }

    public func markConversationRead(id: UUID) {
        do {
            try db.writer.write { db in
                if var conv = try Conversation.fetchOne(db, key: id), conv.unreadCount > 0 {
                    conv = Conversation(
                        id: conv.id,
                        peerUserId: conv.peerUserId,
                        peerDisplayName: conv.peerDisplayName,
                        lastMessagePreview: conv.lastMessagePreview,
                        lastActivity: conv.lastActivity,
                        unreadCount: 0,
                        pinned: conv.pinned,
                        kind: conv.kind,
                        muted: conv.muted,
                        ephemeralTimerSeconds: conv.ephemeralTimerSeconds
                    )
                    try conv.save(db)
                }
            }
        } catch {
            print("[ConversationStore] markConversationRead failed: \(error)")
        }
    }

    // MARK: - Messages

    public func loadMessages(conversationId: UUID) -> [Message] {
        do {
            return try db.reader.read { db in
                try Message
                    .filter(Column("conversationId") == conversationId)
                    .order(Column("sentAt").asc)
                    .fetchAll(db)
            }
        } catch {
            print("[ConversationStore] loadMessages failed: \(error)")
            return []
        }
    }

    public func appendMessage(_ msg: Message) {
        do {
            try db.writer.write { db in
                try msg.save(db)
            }
        } catch {
            print("[ConversationStore] appendMessage saved=0 error: \(error)")
        }
    }

    public func removeMessage(id: UUID, conversationId: UUID) {
        do {
            _ = try db.writer.write { db in
                try Message.filter(key: id).deleteAll(db)
            }
        } catch {
            print("[ConversationStore] removeMessage failed: \(error)")
        }
    }

    /// `viaMesh: true` marks the row as having travelled over the BLE mesh
    /// rather than the public network. Only the mesh send path passes it; every
    /// other caller leaves it nil and the stored value is carried forward.
    public func updateMessageStatus(id: UUID, conversationId: UUID, newStatus: Message.Status,
                                    deliveredAt: Date? = nil, readAt: Date? = nil,
                                    viaMesh: Bool? = nil) {
        do {
            try db.writer.write { db in
                if var msg = try Message.fetchOne(db, key: id) {
                    msg = Message(
                        id: msg.id, conversationId: msg.conversationId, direction: msg.direction,
                        plaintext: msg.plaintext, sentAt: msg.sentAt,
                        deliveredAt: deliveredAt ?? msg.deliveredAt,
                        readAt: readAt ?? msg.readAt,
                        status: newStatus,
                        senderUserId: msg.senderUserId,
                        serverMessageId: msg.serverMessageId,
                        mediaLocalPath: msg.mediaLocalPath,
                        mediaDurationMs: msg.mediaDurationMs,
                        mediaMimeType: msg.mediaMimeType,
                        clientMsgId: msg.clientMsgId,
                        edited: msg.edited,
                        deletedAt: msg.deletedAt,
                        reactions: msg.reactions,
                        expiresAt: msg.expiresAt,
                        isViewOnce: msg.isViewOnce,
                        viewOnceOpened: msg.viewOnceOpened,
                        exportBlocked: msg.exportBlocked,
                        viaMesh: viaMesh ?? msg.viaMesh
                    )
                    try msg.save(db)
                }
            }
        } catch {
            print("[ConversationStore] updateMessageStatus failed: \(error)")
        }
    }

    public func setMediaInfo(localId: UUID, conversationId: UUID,
                             plaintext: String?, mediaLocalPath: String,
                             mediaDurationMs: Int64?,
                             mediaMimeType: String?) {
        do {
            try db.writer.write { db in
                if var msg = try Message.fetchOne(db, key: localId) {
                    msg = Message(
                        id: msg.id, conversationId: msg.conversationId, direction: msg.direction,
                        plaintext: plaintext ?? msg.plaintext,
                        sentAt: msg.sentAt,
                        deliveredAt: msg.deliveredAt, readAt: msg.readAt,
                        status: msg.status, senderUserId: msg.senderUserId,
                        serverMessageId: msg.serverMessageId,
                        mediaLocalPath: mediaLocalPath,
                        mediaDurationMs: mediaDurationMs ?? msg.mediaDurationMs,
                        mediaMimeType: mediaMimeType ?? msg.mediaMimeType,
                        clientMsgId: msg.clientMsgId,
                        edited: msg.edited,
                        deletedAt: msg.deletedAt,
                        reactions: msg.reactions,
                        expiresAt: msg.expiresAt,
                        isViewOnce: msg.isViewOnce,
                        viewOnceOpened: msg.viewOnceOpened,
                        exportBlocked: msg.exportBlocked,
                        viaMesh: msg.viaMesh
                    )
                    try msg.save(db)
                }
            }
        } catch {
            print("[ConversationStore] setMediaInfo failed: \(error)")
        }
    }

    public func setServerMessageId(localId: UUID, conversationId: UUID, serverMessageId: String) {
        do {
            try db.writer.write { db in
                if var msg = try Message.fetchOne(db, key: localId), msg.serverMessageId != serverMessageId {
                    msg = Message(
                        id: msg.id, conversationId: msg.conversationId, direction: msg.direction,
                        plaintext: msg.plaintext, sentAt: msg.sentAt,
                        deliveredAt: msg.deliveredAt, readAt: msg.readAt,
                        status: msg.status, senderUserId: msg.senderUserId,
                        serverMessageId: serverMessageId,
                        mediaLocalPath: msg.mediaLocalPath,
                        mediaDurationMs: msg.mediaDurationMs,
                        mediaMimeType: msg.mediaMimeType,
                        clientMsgId: msg.clientMsgId,
                        edited: msg.edited,
                        deletedAt: msg.deletedAt,
                        reactions: msg.reactions,
                        expiresAt: msg.expiresAt,
                        isViewOnce: msg.isViewOnce,
                        viewOnceOpened: msg.viewOnceOpened,
                        exportBlocked: msg.exportBlocked,
                        viaMesh: msg.viaMesh
                    )
                    try msg.save(db)
                }
            }
        } catch {
            print("[ConversationStore] setServerMessageId failed: \(error)")
        }
    }

    @discardableResult
    public func updateStatusByServerId(serverMessageId: String, newStatus: Message.Status,
                                       deliveredAt: Date? = nil, readAt: Date? = nil) -> Bool {
        do {
            return try db.writer.write { db in
                let msgs = try Message.filter(Column("serverMessageId") == serverMessageId).fetchAll(db)
                for var msg in msgs {
                    msg = Message(
                        id: msg.id, conversationId: msg.conversationId, direction: msg.direction,
                        plaintext: msg.plaintext, sentAt: msg.sentAt,
                        deliveredAt: deliveredAt ?? msg.deliveredAt,
                        readAt: readAt ?? msg.readAt,
                        status: newStatus,
                        senderUserId: msg.senderUserId,
                        serverMessageId: msg.serverMessageId,
                        mediaLocalPath: msg.mediaLocalPath,
                        mediaDurationMs: msg.mediaDurationMs,
                        mediaMimeType: msg.mediaMimeType,
                        clientMsgId: msg.clientMsgId,
                        edited: msg.edited,
                        deletedAt: msg.deletedAt,
                        reactions: msg.reactions,
                        expiresAt: msg.expiresAt,
                        isViewOnce: msg.isViewOnce,
                        viewOnceOpened: msg.viewOnceOpened,
                        exportBlocked: msg.exportBlocked,
                        viaMesh: msg.viaMesh
                    )
                    try msg.save(db)
                }
                return !msgs.isEmpty
            }
        } catch {
            print("[ConversationStore] updateStatusByServerId failed: \(error)")
            return false
        }
    }

    /// W78-fix: bind the *real* server-assigned message id to the local
    /// outbound row, looked up by `clientMsgId` rather than by the local
    /// row UUID.
    ///
    /// Why this exists: the send path previously stamped `serverMessageId`
    /// with the value `sendMessage()` returns synchronously — but that
    /// value is just the caller's own `clientMsgId` echoed back locally
    /// (see `BCryptoMessageApiImpl.sendMessage`), NOT the server's actual
    /// DB-assigned `messages.id` (`internal/db/db.go` `StoreMessage` mints
    /// a fresh `uuid.NewString()` unrelated to `client_msg_id`). The real
    /// id only ever reaches the sender asynchronously, in the `msg_receive`
    /// echo the server sends back to the sender's own device
    /// (`internal/signaling/client.go` `handleMsgSend` → `c.send(MsgReceive,
    /// receiveData)`). `msg_delivered`/`msg_read` receipts are keyed
    /// strictly on that real id (`internal/signaling/messages.go`
    /// `MsgDeliveredData`/`MsgReadData`), so a row that never captured it
    /// can never be reconciled by a later receipt — this is the root cause
    /// of image (and text) sends staying stuck on a red `.failed` status
    /// forever even after the peer genuinely received them.
    ///
    /// Call this from the self-echo branch of the `msg_receive` handler
    /// once the real id is known. Two things happen atomically:
    ///   1. `serverMessageId` is corrected to the real id (so any *later*
    ///      `msg_delivered`/`msg_read` for this message can finally match
    ///      via `updateStatusByServerId`).
    ///   2. If the row is currently stuck at `.failed`, it is immediately
    ///      promoted to `.delivered` — the self-echo landing at all is
    ///      itself proof the server received and stored the message, so
    ///      there is no need to wait for a further receipt to clear the
    ///      stale red state. Rows already past `.failed` (`.sending`,
    ///      `.sent`, `.delivered`, `.read`) are left at their current
    ///      status — this only *repairs* a wrongly-failed row, it never
    ///      regresses a row that's already further along (e.g. `.read`).
    /// Returns `true` if a local row was found and updated.
    @discardableResult
    public func bindServerMessageId(clientMsgId: String, serverMessageId: String,
                                    deliveredAt: Date = Date()) -> Bool {
        do {
            return try db.writer.write { db in
                guard var msg = try Message.filter(Column("clientMsgId") == clientMsgId).fetchOne(db) else {
                    return false
                }
                let repairedStatus: Message.Status = (msg.status == .failed) ? .delivered : msg.status
                let repairedDeliveredAt: Date? = (msg.status == .failed) ? deliveredAt : msg.deliveredAt
                msg = Message(
                    id: msg.id, conversationId: msg.conversationId, direction: msg.direction,
                    plaintext: msg.plaintext, sentAt: msg.sentAt,
                    deliveredAt: repairedDeliveredAt,
                    readAt: msg.readAt,
                    status: repairedStatus,
                    senderUserId: msg.senderUserId,
                    serverMessageId: serverMessageId,
                    mediaLocalPath: msg.mediaLocalPath,
                    mediaDurationMs: msg.mediaDurationMs,
                    mediaMimeType: msg.mediaMimeType,
                    clientMsgId: msg.clientMsgId,
                    edited: msg.edited,
                    deletedAt: msg.deletedAt,
                    reactions: msg.reactions,
                    expiresAt: msg.expiresAt,
                    isViewOnce: msg.isViewOnce,
                    viewOnceOpened: msg.viewOnceOpened,
                    exportBlocked: msg.exportBlocked,
                    viaMesh: msg.viaMesh
                )
                try msg.save(db)
                return true
            }
        } catch {
            print("[ConversationStore] bindServerMessageId failed: \(error)")
            return false
        }
    }

    public func findByClientMsgId(_ clientMsgId: String) -> (conversationId: UUID, message: Message)? {
        do {
            return try db.reader.read { db in
                if let msg = try Message.filter(Column("clientMsgId") == clientMsgId).fetchOne(db) {
                    return (msg.conversationId, msg)
                }
                return nil
            }
        } catch {
            print("[ConversationStore] findByClientMsgId failed: \(error)")
            return nil
        }
    }

    @discardableResult
    public func applyEditByClientMsgId(_ clientMsgId: String,
                                       newPlaintext: String) -> Bool {
        do {
            return try db.writer.write { db in
                if var msg = try Message.filter(Column("clientMsgId") == clientMsgId).fetchOne(db) {
                    msg = Message(
                        id: msg.id, conversationId: msg.conversationId, direction: msg.direction,
                        plaintext: newPlaintext,
                        sentAt: msg.sentAt, deliveredAt: msg.deliveredAt, readAt: msg.readAt,
                        status: msg.status, senderUserId: msg.senderUserId,
                        serverMessageId: msg.serverMessageId,
                        mediaLocalPath: msg.mediaLocalPath,
                        mediaDurationMs: msg.mediaDurationMs,
                        mediaMimeType: msg.mediaMimeType,
                        clientMsgId: msg.clientMsgId,
                        edited: true,
                        deletedAt: msg.deletedAt,
                        reactions: msg.reactions,
                        expiresAt: msg.expiresAt,
                        isViewOnce: msg.isViewOnce,
                        viewOnceOpened: msg.viewOnceOpened,
                        exportBlocked: msg.exportBlocked,
                        viaMesh: msg.viaMesh
                    )
                    try msg.save(db)
                    return true
                }
                return false
            }
        } catch {
            print("[ConversationStore] applyEditByClientMsgId failed: \(error)")
            return false
        }
    }

    /// Shared by both the local-delete flow (`ChatContainer.deleteMessage` /
    /// `deleteMessageLocally`) and the inbound "peer deleted their message"
    /// flow (`AppState` applying a received `qa_ctl:1` t="delete" envelope).
    /// Rewrites the row to a tombstone and — best-effort — removes the
    /// cached attachment blob (voice note / image) the message pointed at.
    ///
    /// Cleanup is signal-not-kill: a missing file, a permissions error, or
    /// any other filesystem failure is logged and swallowed. It NEVER
    /// blocks or fails the tombstone write itself, which is why the path
    /// is captured before the DB transaction and the removal happens only
    /// after the transaction has already committed successfully.
    @discardableResult
    public func applyDeleteByClientMsgId(_ clientMsgId: String,
                                         tombstone: String = "Messaggio eliminato",
                                         at deletedAt: Date = Date()) -> Bool {
        var cachedPathToRemove: String?
        let applied: Bool
        do {
            applied = try db.writer.write { db in
                if var msg = try Message.filter(Column("clientMsgId") == clientMsgId).fetchOne(db) {
                    // Capture the pre-tombstone path now — msg.mediaLocalPath
                    // is about to be wiped from the row below.
                    cachedPathToRemove = msg.mediaLocalPath
                    msg = Message(
                        id: msg.id, conversationId: msg.conversationId, direction: msg.direction,
                        plaintext: tombstone,
                        sentAt: msg.sentAt, deliveredAt: msg.deliveredAt, readAt: msg.readAt,
                        status: msg.status, senderUserId: msg.senderUserId,
                        serverMessageId: msg.serverMessageId,
                        mediaLocalPath: nil,
                        mediaDurationMs: nil,
                        mediaMimeType: nil,
                        clientMsgId: msg.clientMsgId,
                        edited: msg.edited,
                        deletedAt: deletedAt,
                        reactions: nil,
                        expiresAt: nil  // tombstone has no expiry,
                        isViewOnce: msg.isViewOnce,
                        viewOnceOpened: msg.viewOnceOpened,
                        exportBlocked: msg.exportBlocked,
                        viaMesh: msg.viaMesh
                    )
                    try msg.save(db)
                    return true
                }
                return false
            }
        } catch {
            print("[ConversationStore] applyDeleteByClientMsgId failed: \(error)")
            return false
        }
        // Tombstone is committed — now best-effort reclaim the cached blob.
        // Never propagate failures here: the delete already succeeded.
        if applied, let path = cachedPathToRemove, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    print("[ConversationStore] applyDeleteByClientMsgId: cache cleanup failed for \(path): \(error)")
                }
            }
        }
        return applied
    }

    @discardableResult
    public func applyReactionToggleByClientMsgId(_ clientMsgId: String,
                                                 userId: String,
                                                 emoji: String) -> Bool? {
        do {
            return try db.writer.write { db in
                guard var msg = try Message.filter(Column("clientMsgId") == clientMsgId).fetchOne(db) else { return nil }
                var dict: [String: [String]] = msg.reactions ?? [:]
                var users = dict[emoji] ?? []
                let added: Bool
                if let pos = users.firstIndex(of: userId) {
                    users.remove(at: pos)
                    added = false
                } else {
                    users.append(userId)
                    added = true
                }
                if users.isEmpty {
                    dict.removeValue(forKey: emoji)
                } else {
                    dict[emoji] = users
                }

                msg = Message(
                    id: msg.id, conversationId: msg.conversationId, direction: msg.direction,
                    plaintext: msg.plaintext, sentAt: msg.sentAt,
                    deliveredAt: msg.deliveredAt, readAt: msg.readAt,
                    status: msg.status, senderUserId: msg.senderUserId,
                    serverMessageId: msg.serverMessageId,
                    mediaLocalPath: msg.mediaLocalPath,
                    mediaDurationMs: msg.mediaDurationMs,
                    mediaMimeType: msg.mediaMimeType,
                    clientMsgId: msg.clientMsgId,
                    edited: msg.edited,
                    deletedAt: msg.deletedAt,
                    reactions: dict.isEmpty ? nil : dict,
                    expiresAt: msg.expiresAt,
                    isViewOnce: msg.isViewOnce,
                    viewOnceOpened: msg.viewOnceOpened,
                    exportBlocked: msg.exportBlocked,
                    viaMesh: msg.viaMesh
                )
                try msg.save(db)
                return added
            }
        } catch {
            print("[ConversationStore] applyReactionToggleByClientMsgId failed: \(error)")
            return nil
        }
    }

    // MARK: - Ephemeral timers

    /// Delete all messages whose `expiresAt` is non-nil and in the past.
    /// Called by EphemeralMessageJanitor every 60 s.
    ///
    /// W612: mirrors `applyDeleteByClientMsgId`'s capture-then-remove
    /// pattern — a bare `deleteAll` only drops the DB row, leaving any
    /// cached attachment blob the expired message pointed at (e.g. a
    /// decrypted TTL/view-once photo in `Library/Caches/images/`) on
    /// disk forever. That defeats the entire point of TTL/view-once:
    /// the plaintext must actually become unrecoverable, not just
    /// hidden from the UI. Cleanup is signal-not-kill: capture the
    /// paths before the transaction, delete the rows, then — only
    /// after the commit has succeeded — best-effort remove the files.
    /// A missing file or filesystem error is logged and swallowed; it
    /// never blocks or fails the DB delete itself.
    public func deleteExpiredMessages() {
        do {
            let now = Date()
            var cachedPathsToRemove: [String] = []
            _ = try db.writer.write { db in
                let expired = try Message
                    .filter(Column("expiresAt") != nil)
                    .filter(Column("expiresAt") <= now)
                    .fetchAll(db)
                cachedPathsToRemove = expired.compactMap { $0.mediaLocalPath }.filter { !$0.isEmpty }
                try Message
                    .filter(Column("expiresAt") != nil)
                    .filter(Column("expiresAt") <= now)
                    .deleteAll(db)
            }
            // Rows are committed — now best-effort reclaim the cached
            // blobs. Never propagate failures here: the DB delete
            // already succeeded.
            for path in cachedPathsToRemove {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                } catch {
                    print("[ConversationStore] deleteExpiredMessages: cache cleanup failed for \(path): \(error)")
                }
            }
        } catch {
            print("[ConversationStore] deleteExpiredMessages failed: \(error)")
        }
    }

    /// Persist the per-conversation ephemeral timer.
    /// Pass `nil` or `0` to disable.
    public func setEphemeralTimer(conversationId: UUID, seconds: Int?) {
        do {
            try db.writer.write { db in
                if var conv = try Conversation.fetchOne(db, key: conversationId) {
                    conv = Conversation(
                        id: conv.id,
                        peerUserId: conv.peerUserId,
                        peerDisplayName: conv.peerDisplayName,
                        lastMessagePreview: conv.lastMessagePreview,
                        lastActivity: conv.lastActivity,
                        unreadCount: conv.unreadCount,
                        pinned: conv.pinned,
                        kind: conv.kind,
                        muted: conv.muted,
                        ephemeralTimerSeconds: seconds
                    )
                    try conv.save(db)
                }
            }
        } catch {
            print("[ConversationStore] setEphemeralTimer failed: \(error)")
        }
    }

    // MARK: - View-once

    /// Mark a view-once message as opened: sets viewOnceOpened=true and
    /// expiresAt=now+5s so EphemeralMessageJanitor wipes it quickly.
    ///
    /// Defense-in-depth: no-op for the sender's own outgoing rows. The
    /// UI tap-to-reveal flow that calls this (ChatDetailScreen.messageRow)
    /// is already gated to never invoke it for `.outgoing` messages, but
    /// this guard ensures a future or alternate caller can't accidentally
    /// arm the 5s deletion timer on the sender's own copy — view-once
    /// must only constrain the recipient's experience.
    public func markViewOnceOpened(messageId: UUID, conversationId: UUID) {
        do {
            let deadline = Date().addingTimeInterval(5)
            try db.writer.write { db in
                if var msg = try Message.fetchOne(db, key: messageId) {
                    guard msg.direction != .outgoing else { return }
                    msg = Message(
                        id: msg.id, conversationId: msg.conversationId,
                        direction: msg.direction, plaintext: msg.plaintext,
                        sentAt: msg.sentAt, deliveredAt: msg.deliveredAt,
                        readAt: msg.readAt, status: msg.status,
                        senderUserId: msg.senderUserId,
                        serverMessageId: msg.serverMessageId,
                        mediaLocalPath: msg.mediaLocalPath,
                        mediaDurationMs: msg.mediaDurationMs,
                        mediaMimeType: msg.mediaMimeType,
                        clientMsgId: msg.clientMsgId,
                        edited: msg.edited, deletedAt: msg.deletedAt,
                        reactions: msg.reactions,
                        expiresAt: deadline,
                        isViewOnce: msg.isViewOnce,
                        viewOnceOpened: true,
                        exportBlocked: msg.exportBlocked,
                        viaMesh: msg.viaMesh
                    )
                    try msg.save(db)
                }
            }
        } catch {
            print("[ConversationStore] markViewOnceOpened failed: \(error)")
        }
    }

    // MARK: - Screenshot permission

    /// Persist the screenshot permission granted by the remote peer.
    public func setScreenshotGranted(conversationId: UUID, granted: Bool?) {
        do {
            try db.writer.write { db in
                if var conv = try Conversation.fetchOne(db, key: conversationId) {
                    conv = Conversation(
                        id: conv.id, peerUserId: conv.peerUserId,
                        peerDisplayName: conv.peerDisplayName,
                        lastMessagePreview: conv.lastMessagePreview,
                        lastActivity: conv.lastActivity,
                        unreadCount: conv.unreadCount, pinned: conv.pinned,
                        kind: conv.kind, muted: conv.muted,
                        ephemeralTimerSeconds: conv.ephemeralTimerSeconds,
                        screenshotGrantedByPeer: granted
                    )
                    try conv.save(db)
                }
            }
        } catch {
            print("[ConversationStore] setScreenshotGranted failed: \(error)")
        }
    }

    // MARK: - Reset

    public func wipeAll() {
        do {
            _ = try db.writer.write { db in
                try Conversation.deleteAll(db)
            }
        } catch {
            print("[ConversationStore] wipeAll failed: \(error)")
        }
    }

    // MARK: - Migration

    private func migrateIfNeeded() {
        guard let convData = defaults.data(forKey: ConversationStore.conversationsKey),
              let conversations = try? decoder.decode([Conversation].self, from: convData) else {
            return
        }

        print("[ConversationStore] Migrating \(conversations.count) conversations to secure DB...")

        do {
            try db.writer.write { db in
                for conv in conversations {
                    try conv.save(db)

                    // Migrate messages
                    if let msgData = defaults.data(forKey: ConversationStore.messagesKey(for: conv.id)),
                       let messages = try? decoder.decode([Message].self, from: msgData) {
                        for msg in messages {
                            try msg.save(db)
                        }
                    }
                }
            }

            // Clear UserDefaults only after successful migration
            print("[ConversationStore] Migration successful. Purging legacy UserDefaults.")
            for conv in conversations {
                defaults.removeObject(forKey: ConversationStore.messagesKey(for: conv.id))
            }
            defaults.removeObject(forKey: ConversationStore.conversationsKey)

        } catch {
            print("[ConversationStore] Migration failed: \(error). DANGER: keeping legacy data.")
        }
    }
}
