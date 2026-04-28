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
}
