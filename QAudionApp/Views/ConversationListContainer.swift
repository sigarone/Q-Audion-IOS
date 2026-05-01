import SwiftUI
import QAudionEngine

@MainActor
final class ConversationListContainer: ObservableObject {

    @Published private(set) var viewModel: ConversationListViewModel
    @Published var searchText: String = ""

    private let store: ConversationStore

    init(store: ConversationStore = ConversationStore()) {
        self.store = store
        self.viewModel = ConversationListViewModel(items: [])
        loadFromStore()
    }

    func loadFromStore() {
        let conversations = store.loadConversations()
        // W68b: applica read-mark filter. Se l'utente ha fatto markAllAsRead
        // in passato e poi il repo resyncs con vecchi unreadCount dal
        // server, il filter forza unreadCount = 0 finché lastActivity
        // non è successiva al marked-read timestamp.
        let readMarks = Self.loadReadMarks()
        let items = conversations.map { conv -> ConversationListViewModel.Item in
            var unread = conv.unreadCount
            if let markedAt = readMarks[conv.id.uuidString],
               conv.lastActivity <= markedAt {
                unread = 0
            }
            return ConversationListViewModel.Item(
                conversationId: conv.id,
                peerUserId: conv.peerUserId,
                peerDisplayName: conv.peerDisplayName,
                lastMessagePreview: conv.lastMessagePreview,
                lastActivity: conv.lastActivity,
                unreadCount: unread,
                pinned: conv.pinned,
                kind: conv.kind,
                muted: conv.muted ?? false
            )
        }
        viewModel = ConversationListViewModel(items: items, searchQuery: searchText)
    }

    func setSearchQuery(_ query: String) {
        searchText = query
        viewModel = ConversationListViewModel(items: viewModel.items, searchQuery: query)
    }

    func startConversation(peerUserId: String, peerDisplayName: String) -> UUID {
        let id = UUID()
        let conv = Conversation(
            id: id,
            peerUserId: peerUserId,
            peerDisplayName: peerDisplayName,
            lastMessagePreview: nil,
            lastActivity: Date(),
            unreadCount: 0,
            pinned: false,
            kind: .oneToOne
        )
        store.upsertConversation(conv)
        loadFromStore()
        return id
    }

    func togglePinned(conversationId: UUID) {
        var convs = store.loadConversations()
        guard let idx = convs.firstIndex(where: { $0.id == conversationId }) else { return }
        let old = convs[idx]
        // `Conversation` resolves unambiguously to the engine model now that
        // AppState's legacy struct was renamed to `LegacyConversation`.
        convs[idx] = Conversation(
            id: old.id,
            peerUserId: old.peerUserId,
            peerDisplayName: old.peerDisplayName,
            lastMessagePreview: old.lastMessagePreview,
            lastActivity: old.lastActivity,
            unreadCount: old.unreadCount,
            pinned: !old.pinned,
            kind: old.kind,
            muted: old.muted
        )
        store.upsertConversation(convs[idx])
        loadFromStore()
    }

    /// W89: toggle the mute flag. Muted conversations:
    ///   - skip the unread-bump on inbound messages (badge stays at 0).
    ///   - in a future patch, suppress local-notification banner +
    ///     APNs sound (server already supports a per-conversation mute
    ///     hint via the push payload).
    /// Idempotent (re-firing flips state). UI surfaces the state via
    /// the bell-slash icon next to the row.
    func toggleMuted(conversationId: UUID) {
        var convs = store.loadConversations()
        guard let idx = convs.firstIndex(where: { $0.id == conversationId }) else { return }
        let old = convs[idx]
        let nowMuted = !(old.muted ?? false)
        convs[idx] = Conversation(
            id: old.id,
            peerUserId: old.peerUserId,
            peerDisplayName: old.peerDisplayName,
            lastMessagePreview: old.lastMessagePreview,
            lastActivity: old.lastActivity,
            unreadCount: old.unreadCount,
            pinned: old.pinned,
            kind: old.kind,
            muted: nowMuted
        )
        store.upsertConversation(convs[idx])
        loadFromStore()
    }

    func deleteConversation(conversationId: UUID) {
        store.deleteConversation(id: conversationId)
        loadFromStore()
    }

    /// Total unread count across all conversations. Used by the
    /// ChatListScreen overflow menu to gate the "Segna tutti come letti"
    /// action — disabled when zero.
    var totalUnread: Int {
        viewModel.items.reduce(0) { $0 + $1.unreadCount }
    }

    /// W50+W68b: zera `unreadCount` su tutte le conversazioni con unread > 0.
    /// La pure-engine wire reale (`ConversationRepository.markAllRead()` +
    /// WS broadcast read-receipts al peer) resta deferred. App-layer
    /// persistence aggiunta in W68b: gli ID delle convs marcate come lette
    /// vengono persistite in UserDefaults così se il backend resync di
    /// `loadFromStore` ri-popola le convs con vecchi unreadCount, noi
    /// applichiamo il filter post-load.
    private static let readSinceKey = "com.qaudion.chat.markedReadAt"

    /// Returns map of conversationId.uuidString → Date marked-read.
    private static func loadReadMarks() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: readSinceKey) as? [String: TimeInterval] else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func saveReadMark(conversationId: UUID, at date: Date) {
        var marks = loadReadMarks()
        marks[conversationId.uuidString] = date
        let raw = marks.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: readSinceKey)
    }

    func markAllAsRead() {
        var convs = store.loadConversations()
        var changed = false
        let now = Date()
        for (idx, conv) in convs.enumerated() where conv.unreadCount > 0 {
            convs[idx] = Conversation(
                id: conv.id,
                peerUserId: conv.peerUserId,
                peerDisplayName: conv.peerDisplayName,
                lastMessagePreview: conv.lastMessagePreview,
                lastActivity: conv.lastActivity,
                unreadCount: 0,
                pinned: conv.pinned,
                kind: conv.kind
            )
            store.upsertConversation(convs[idx])
            // W68b: persist read mark for this conv at `now` so the next
            // loadFromStore() can apply post-filter even if the repo
            // resyncs old unreadCount from server.
            Self.saveReadMark(conversationId: conv.id, at: now)
            changed = true
        }
        if changed { loadFromStore() }
    }
}
