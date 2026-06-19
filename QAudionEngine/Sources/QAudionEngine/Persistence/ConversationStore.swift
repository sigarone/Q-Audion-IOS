import Foundation
import GRDB

/// Local persistence for conversation list + message history.
///
/// **Hardened Storage.** Uses SQLCipher-encrypted SQLite with secure_delete
/// and auto_vacuum. Migrates from legacy plaintext UserDefaults on first run.
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
            print("[ConversationStore] upsertConversation failed: \(error)")
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
            print("[ConversationStore] appendMessage failed: \(error)")
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

    public func updateMessageStatus(id: UUID, conversationId: UUID, newStatus: Message.Status,
                                    deliveredAt: Date? = nil, readAt: Date? = nil) {
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
                        expiresAt: msg.expiresAt
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
                        expiresAt: msg.expiresAt
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
                        expiresAt: msg.expiresAt
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
                        expiresAt: msg.expiresAt
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
                        expiresAt: msg.expiresAt
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

    @discardableResult
    public func applyDeleteByClientMsgId(_ clientMsgId: String,
                                         tombstone: String = "Messaggio eliminato",
                                         at deletedAt: Date = Date()) -> Bool {
        do {
            return try db.writer.write { db in
                if var msg = try Message.filter(Column("clientMsgId") == clientMsgId).fetchOne(db) {
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
                        expiresAt: nil  // tombstone has no expiry
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
                    expiresAt: msg.expiresAt
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
    public func deleteExpiredMessages() {
        do {
            let now = Date()
            _ = try db.writer.write { db in
                try Message
                    .filter(Column("expiresAt") != nil)
                    .filter(Column("expiresAt") <= now)
                    .deleteAll(db)
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
    public func markViewOnceOpened(messageId: UUID, conversationId: UUID) {
        do {
            let deadline = Date().addingTimeInterval(5)
            try db.writer.write { db in
                if var msg = try Message.fetchOne(db, key: messageId) {
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
                        viewOnceOpened: true
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
