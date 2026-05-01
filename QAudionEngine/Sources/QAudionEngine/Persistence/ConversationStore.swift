import Foundation

/// Local persistence for conversation list + message history.
///
/// **Plaintext storage on disk.** Real ratchet/cipher for at-rest
/// encryption is a Track B follow-on. Currently the messages are
/// already in clear once the user is logged in, so this matches the
/// existing security posture (key vault is the boundary).
///
/// Keys: `qaudion.conv.list` (Conversation list)
///       `qaudion.conv.msgs.<conversation-uuid>` (per-conversation Message[])
public final class ConversationStore {

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        self.encoder = e
        self.decoder = d
    }

    private static let conversationsKey = "qaudion.conv.list"
    private static func messagesKey(for cid: UUID) -> String {
        return "qaudion.conv.msgs.\(cid.uuidString.lowercased())"
    }

    // MARK: - Conversations

    public func loadConversations() -> [Conversation] {
        guard let data = defaults.data(forKey: ConversationStore.conversationsKey),
              let list = try? decoder.decode([Conversation].self, from: data) else {
            return []
        }
        return list
    }

    public func saveConversations(_ list: [Conversation]) {
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: ConversationStore.conversationsKey)
    }

    public func upsertConversation(_ conv: Conversation) {
        var list = loadConversations()
        if let idx = list.firstIndex(where: { $0.id == conv.id }) {
            list[idx] = conv
        } else {
            list.append(conv)
        }
        saveConversations(list)
    }

    public func deleteConversation(id: UUID) {
        var list = loadConversations()
        list.removeAll { $0.id == id }
        saveConversations(list)
        // Also clear messages.
        defaults.removeObject(forKey: ConversationStore.messagesKey(for: id))
    }

    /// W83 — bump `lastMessagePreview` + `lastActivity` (and optionally
    /// `unreadCount`) on the conversation row. Called whenever a new
    /// message arrives or is sent. Without this, the chat list shows
    /// the FIRST message preview forever and never reorders by recency.
    ///
    /// - Parameters:
    ///   - id: conversation id.
    ///   - lastMessagePreview: friendly preview (already rendered —
    ///     pass the placeholder for cross-platform attachments, not
    ///     raw JSON).
    ///   - lastActivity: unix-Date of the new message.
    ///   - incrementUnread: `true` for inbound messages received while
    ///     the chat is closed; `false` for outbound or when the user
    ///     is actively viewing the conversation.
    public func recordNewMessage(conversationId id: UUID,
                                 lastMessagePreview: String,
                                 lastActivity: Date,
                                 incrementUnread: Bool) {
        var list = loadConversations()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let old = list[idx]
        // Cap preview at 120 chars so the chat list doesn't render
        // a multi-line wall on long messages.
        let truncated: String
        if lastMessagePreview.count > 120 {
            truncated = String(lastMessagePreview.prefix(120)) + "…"
        } else {
            truncated = lastMessagePreview
        }
        list[idx] = Conversation(
            id: old.id,
            peerUserId: old.peerUserId,
            peerDisplayName: old.peerDisplayName,
            lastMessagePreview: truncated,
            lastActivity: lastActivity,
            unreadCount: incrementUnread ? old.unreadCount + 1 : old.unreadCount,
            pinned: old.pinned,
            kind: old.kind
        )
        saveConversations(list)
    }

    /// W83 — reset `unreadCount` to zero for one conversation (called
    /// when the user opens the chat detail screen). Idempotent.
    public func markConversationRead(id: UUID) {
        var list = loadConversations()
        guard let idx = list.firstIndex(where: { $0.id == id }),
              list[idx].unreadCount > 0 else { return }
        let old = list[idx]
        list[idx] = Conversation(
            id: old.id,
            peerUserId: old.peerUserId,
            peerDisplayName: old.peerDisplayName,
            lastMessagePreview: old.lastMessagePreview,
            lastActivity: old.lastActivity,
            unreadCount: 0,
            pinned: old.pinned,
            kind: old.kind
        )
        saveConversations(list)
    }

    // MARK: - Messages

    public func loadMessages(conversationId: UUID) -> [Message] {
        guard let data = defaults.data(forKey: ConversationStore.messagesKey(for: conversationId)),
              let list = try? decoder.decode([Message].self, from: data) else {
            return []
        }
        return list
    }

    public func appendMessage(_ msg: Message) {
        var list = loadMessages(conversationId: msg.conversationId)
        list.append(msg)
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: ConversationStore.messagesKey(for: msg.conversationId))
    }

    /// W88: hard-remove a message row (used by the retry flow after a
    /// failed voice/image send — we delete the failed row then re-emit
    /// to avoid showing two bubbles for the same content).
    public func removeMessage(id: UUID, conversationId: UUID) {
        var list = loadMessages(conversationId: conversationId)
        list.removeAll { $0.id == id }
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: ConversationStore.messagesKey(for: conversationId))
    }

    public func updateMessageStatus(id: UUID, conversationId: UUID, newStatus: Message.Status,
                                    deliveredAt: Date? = nil, readAt: Date? = nil) {
        var list = loadMessages(conversationId: conversationId)
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let old = list[idx]
        list[idx] = Message(
            id: old.id, conversationId: old.conversationId, direction: old.direction,
            plaintext: old.plaintext, sentAt: old.sentAt,
            deliveredAt: deliveredAt ?? old.deliveredAt,
            readAt: readAt ?? old.readAt,
            status: newStatus,
            senderUserId: old.senderUserId,
            serverMessageId: old.serverMessageId,
            mediaLocalPath: old.mediaLocalPath,
            mediaDurationMs: old.mediaDurationMs,
            mediaMimeType: old.mediaMimeType,
            clientMsgId: old.clientMsgId,
            edited: old.edited,
            deletedAt: old.deletedAt,
            reactions: old.reactions
        )
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: ConversationStore.messagesKey(for: conversationId))
    }

    /// W80/W82: bind decrypted media (local cache path + optional
    /// duration + MIME) to a previously-stored message. Updates
    /// plaintext too so the chat bubble shows the friendly preview
    /// instead of the "download in arrivo" placeholder.
    public func setMediaInfo(localId: UUID, conversationId: UUID,
                             plaintext: String?, mediaLocalPath: String,
                             mediaDurationMs: Int64?,
                             mediaMimeType: String?) {
        var list = loadMessages(conversationId: conversationId)
        guard let idx = list.firstIndex(where: { $0.id == localId }) else { return }
        let old = list[idx]
        list[idx] = Message(
            id: old.id, conversationId: old.conversationId, direction: old.direction,
            plaintext: plaintext ?? old.plaintext,
            sentAt: old.sentAt,
            deliveredAt: old.deliveredAt, readAt: old.readAt,
            status: old.status, senderUserId: old.senderUserId,
            serverMessageId: old.serverMessageId,
            mediaLocalPath: mediaLocalPath,
            mediaDurationMs: mediaDurationMs ?? old.mediaDurationMs,
            mediaMimeType: mediaMimeType ?? old.mediaMimeType
        )
        do {
            let data = try encoder.encode(list)
            defaults.set(data, forKey: ConversationStore.messagesKey(for: conversationId))
        } catch {
            print("[ConversationStore] setMediaInfo encode failed for conv=\(conversationId): \(error)")
        }
    }

    // MARK: - W78: server message-id reconciliation

    /// Bind the server-issued message id to a locally-persisted message,
    /// so subsequent `msg_delivered` / `msg_read` events (which carry
    /// only server ids) can flip the right row. Idempotent.
    public func setServerMessageId(localId: UUID, conversationId: UUID, serverMessageId: String) {
        var list = loadMessages(conversationId: conversationId)
        guard let idx = list.firstIndex(where: { $0.id == localId }) else { return }
        let old = list[idx]
        // Skip if already bound — server delivers the same ack at most once.
        if old.serverMessageId == serverMessageId { return }
        list[idx] = Message(
            id: old.id, conversationId: old.conversationId, direction: old.direction,
            plaintext: old.plaintext, sentAt: old.sentAt,
            deliveredAt: old.deliveredAt, readAt: old.readAt,
            status: old.status, senderUserId: old.senderUserId,
            serverMessageId: serverMessageId,
            mediaLocalPath: old.mediaLocalPath,
            mediaDurationMs: old.mediaDurationMs,
            mediaMimeType: old.mediaMimeType,
            clientMsgId: old.clientMsgId,
            edited: old.edited,
            deletedAt: old.deletedAt,
            reactions: old.reactions
        )
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: ConversationStore.messagesKey(for: conversationId))
    }

    /// Update status by server id (used by msg_delivered / msg_read
    /// handlers). Returns true if at least one row was matched and updated.
    /// Server ids are globally unique by design, but we still scan every
    /// conversation because (a) a buggy server could in theory emit the
    /// same id twice and we'd rather flip both rows than half-flip, and
    /// (b) defensive programming costs almost nothing here (UserDefaults
    /// I/O is local).
    @discardableResult
    public func updateStatusByServerId(serverMessageId: String, newStatus: Message.Status,
                                       deliveredAt: Date? = nil, readAt: Date? = nil) -> Bool {
        var anyMatched = false
        for conv in loadConversations() {
            var list = loadMessages(conversationId: conv.id)
            guard let idx = list.firstIndex(where: { $0.serverMessageId == serverMessageId }) else {
                continue
            }
            anyMatched = true
            let old = list[idx]
            list[idx] = Message(
                id: old.id, conversationId: old.conversationId, direction: old.direction,
                plaintext: old.plaintext, sentAt: old.sentAt,
                deliveredAt: deliveredAt ?? old.deliveredAt,
                readAt: readAt ?? old.readAt,
                status: newStatus,
                senderUserId: old.senderUserId,
                serverMessageId: old.serverMessageId,
                mediaLocalPath: old.mediaLocalPath,
                mediaDurationMs: old.mediaDurationMs,
            mediaMimeType: old.mediaMimeType,
            clientMsgId: old.clientMsgId,
            edited: old.edited,
            deletedAt: old.deletedAt,
            reactions: old.reactions
            )
            do {
                let data = try encoder.encode(list)
                defaults.set(data, forKey: ConversationStore.messagesKey(for: conv.id))
            } catch {
                print("[ConversationStore] updateStatusByServerId encode failed for conv=\(conv.id): \(error)")
            }
        }
        return anyMatched
    }

    // MARK: - W86: clientMsgId-keyed mutations (qa_ctl envelopes)

    /// Locate a message by its sender-generated `clientMsgId`. Returns
    /// the conversation id along with the row so the caller can re-save
    /// without scanning every conv twice. iOS rows have unique
    /// `clientMsgId` values across the entire store (UUIDv4); a hit is
    /// the only hit.
    public func findByClientMsgId(_ clientMsgId: String) -> (conversationId: UUID, message: Message)? {
        for conv in loadConversations() {
            let msgs = loadMessages(conversationId: conv.id)
            if let m = msgs.first(where: { $0.clientMsgId == clientMsgId }) {
                return (conv.id, m)
            }
        }
        return nil
    }

    /// W86: apply a `qa_ctl:1` t="edit" envelope. Replaces `plaintext`
    /// and stamps `edited = true`. Caller (AppState) is responsible for
    /// the spoof check (only the original sender can edit) before
    /// invoking. Returns true if a row was matched and updated.
    @discardableResult
    public func applyEditByClientMsgId(_ clientMsgId: String,
                                       newPlaintext: String) -> Bool {
        guard let (convId, _) = findByClientMsgId(clientMsgId) else { return false }
        var list = loadMessages(conversationId: convId)
        guard let idx = list.firstIndex(where: { $0.clientMsgId == clientMsgId }) else { return false }
        let old = list[idx]
        list[idx] = Message(
            id: old.id, conversationId: old.conversationId, direction: old.direction,
            plaintext: newPlaintext,
            sentAt: old.sentAt, deliveredAt: old.deliveredAt, readAt: old.readAt,
            status: old.status, senderUserId: old.senderUserId,
            serverMessageId: old.serverMessageId,
            mediaLocalPath: old.mediaLocalPath,
            mediaDurationMs: old.mediaDurationMs,
            mediaMimeType: old.mediaMimeType,
            clientMsgId: old.clientMsgId,
            edited: true,
            deletedAt: old.deletedAt,
            reactions: old.reactions
        )
        guard let data = try? encoder.encode(list) else { return false }
        defaults.set(data, forKey: ConversationStore.messagesKey(for: convId))
        return true
    }

    /// W86: apply a `qa_ctl:1` t="delete" envelope. Replaces `plaintext`
    /// with the localized tombstone and stamps `deletedAt`. Caller
    /// performs the spoof check. Returns true on match.
    @discardableResult
    public func applyDeleteByClientMsgId(_ clientMsgId: String,
                                         tombstone: String = "Messaggio eliminato",
                                         at deletedAt: Date = Date()) -> Bool {
        guard let (convId, _) = findByClientMsgId(clientMsgId) else { return false }
        var list = loadMessages(conversationId: convId)
        guard let idx = list.firstIndex(where: { $0.clientMsgId == clientMsgId }) else { return false }
        let old = list[idx]
        list[idx] = Message(
            id: old.id, conversationId: old.conversationId, direction: old.direction,
            plaintext: tombstone,
            sentAt: old.sentAt, deliveredAt: old.deliveredAt, readAt: old.readAt,
            status: old.status, senderUserId: old.senderUserId,
            serverMessageId: old.serverMessageId,
            mediaLocalPath: nil,    // detach the media — playable bubble would reference a
            mediaDurationMs: nil,   //  decrypted file that no longer represents the message.
            mediaMimeType: nil,
            clientMsgId: old.clientMsgId,
            edited: old.edited,
            deletedAt: deletedAt
        )
        guard let data = try? encoder.encode(list) else { return false }
        defaults.set(data, forKey: ConversationStore.messagesKey(for: convId))
        return true
    }

    /// W87: toggle a reaction. If `userId` already reacted with `emoji`
    /// to the target, REMOVE that reaction (the user is "un-reacting").
    /// Otherwise ADD it. Empty emoji buckets are pruned to keep the
    /// dict tidy.
    ///
    /// Returns `nil` if the target wasn't found, otherwise `true` if
    /// a reaction was ADDED, `false` if REMOVED. Caller can use the
    /// boolean for analytics/UI feedback.
    @discardableResult
    public func applyReactionToggleByClientMsgId(_ clientMsgId: String,
                                                 userId: String,
                                                 emoji: String) -> Bool? {
        guard let (convId, _) = findByClientMsgId(clientMsgId) else { return nil }
        var list = loadMessages(conversationId: convId)
        guard let idx = list.firstIndex(where: { $0.clientMsgId == clientMsgId }) else { return nil }
        let old = list[idx]
        var dict: [String: [String]] = old.reactions ?? [:]
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
        list[idx] = Message(
            id: old.id, conversationId: old.conversationId, direction: old.direction,
            plaintext: old.plaintext, sentAt: old.sentAt,
            deliveredAt: old.deliveredAt, readAt: old.readAt,
            status: old.status, senderUserId: old.senderUserId,
            serverMessageId: old.serverMessageId,
            mediaLocalPath: old.mediaLocalPath,
            mediaDurationMs: old.mediaDurationMs,
            mediaMimeType: old.mediaMimeType,
            clientMsgId: old.clientMsgId,
            edited: old.edited,
            deletedAt: old.deletedAt,
            reactions: dict.isEmpty ? nil : dict
        )
        do {
            let data = try encoder.encode(list)
            defaults.set(data, forKey: ConversationStore.messagesKey(for: convId))
        } catch {
            print("[ConversationStore] applyReactionToggle encode failed for conv=\(convId): \(error)")
            return nil
        }
        return added
    }

    // MARK: - Reset

    public func wipeAll() {
        let convList = loadConversations()
        for conv in convList {
            defaults.removeObject(forKey: ConversationStore.messagesKey(for: conv.id))
        }
        defaults.removeObject(forKey: ConversationStore.conversationsKey)
    }
}
