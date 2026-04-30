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
        let items = conversations.map { conv in
            ConversationListViewModel.Item(
                conversationId: conv.id,
                peerUserId: conv.peerUserId,
                peerDisplayName: conv.peerDisplayName,
                lastMessagePreview: conv.lastMessagePreview,
                lastActivity: conv.lastActivity,
                unreadCount: conv.unreadCount,
                pinned: conv.pinned,
                kind: conv.kind
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
            kind: old.kind
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

    /// W50: zera `unreadCount` su tutte le conversazioni con unread > 0.
    /// Engine wire (real `ConversationRepository.markAllRead()`) deferred
    /// — oggi muta lo store locale e re-emette la lista. Quando l'engine
    /// surface esporrà ack-receipts via WS, sostituire con la chiamata
    /// repo che propaga read-receipt al peer.
    func markAllAsRead() {
        var convs = store.loadConversations()
        var changed = false
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
            changed = true
        }
        if changed { loadFromStore() }
    }
}
