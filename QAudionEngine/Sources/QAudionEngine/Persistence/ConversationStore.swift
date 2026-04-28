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
            senderUserId: old.senderUserId
        )
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: ConversationStore.messagesKey(for: conversationId))
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
