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
        public let text: String
        public let ts: Date

        public init(id: String, serverMessageId: String?, senderId: String,
                    mine: Bool, text: String, ts: Date) {
            self.id = id
            self.serverMessageId = serverMessageId
            self.senderId = senderId
            self.mine = mine
            self.text = text
            self.ts = ts
        }
    }

    /// groupHex → chronological messages (oldest first).
    private var byGroup: [String: [Stored]] = [:]
    private static let storageKey = "qaudion.groups.messages.v1"
    private static let maxPerGroup = 500

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: [Stored]].self, from: data) else {
            byGroup = [:]
            return
        }
        byGroup = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(byGroup) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - Reads

    public func messages(forGroupHex groupHex: String) -> [Stored] {
        return byGroup[groupHex] ?? []
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

    public func clear(groupHex: String) {
        guard byGroup[groupHex] != nil else { return }
        byGroup.removeValue(forKey: groupHex)
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
