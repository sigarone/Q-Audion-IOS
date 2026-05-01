import Foundation

public struct ConversationListViewModel: ViewModelProtocol {

    public struct Item: Equatable, Sendable, Hashable {
        public let conversationId: UUID
        public let peerUserId: String
        public let peerDisplayName: String
        public let lastMessagePreview: String?
        public let lastActivity: Date
        public let unreadCount: Int
        public let pinned: Bool
        public let kind: Conversation.Kind
        /// W89: mirror of `Conversation.muted` so the chat list row
        /// can render a bell-slash indicator without re-loading the
        /// underlying Conversation. Default false.
        public let muted: Bool

        public init(conversationId: UUID, peerUserId: String, peerDisplayName: String,
                    lastMessagePreview: String?, lastActivity: Date,
                    unreadCount: Int, pinned: Bool, kind: Conversation.Kind = .oneToOne,
                    muted: Bool = false) {
            self.conversationId = conversationId
            self.peerUserId = peerUserId
            self.peerDisplayName = peerDisplayName
            self.lastMessagePreview = lastMessagePreview
            self.lastActivity = lastActivity
            self.unreadCount = unreadCount
            self.pinned = pinned
            self.kind = kind
            self.muted = muted
        }
    }

    public let items: [Item]
    public let searchQuery: String

    public init(items: [Item], searchQuery: String = "") {
        self.items = items
        self.searchQuery = searchQuery
    }

    public var filteredItems: [Item] {
        let pinnedFirst = items.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.lastActivity > rhs.lastActivity
        }
        guard !searchQuery.isEmpty else { return pinnedFirst }
        let q = searchQuery.lowercased()
        return pinnedFirst.filter { $0.peerDisplayName.lowercased().contains(q) }
    }

    public static let mock = ConversationListViewModel(items: [
        Item(
            conversationId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            peerUserId: "user-alice", peerDisplayName: "Alice (Pixel 7)",
            lastMessagePreview: "Tutto bene, grazie. Ci vediamo alle 18?",
            lastActivity: Date(timeIntervalSince1970: 1_745_000_000),
            unreadCount: 0, pinned: true, kind: .oneToOne
        ),
        Item(
            conversationId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            peerUserId: "user-bob", peerDisplayName: "Bob (iPhone 14)",
            lastMessagePreview: "OK ricevuto, grazie",
            lastActivity: Date(timeIntervalSince1970: 1_744_900_000),
            unreadCount: 2, pinned: false, kind: .oneToOne
        ),
        Item(
            conversationId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            peerUserId: "group-team", peerDisplayName: "Q-Audion Team",
            lastMessagePreview: "Charlie: meeting alle 17",
            lastActivity: Date(timeIntervalSince1970: 1_744_800_000),
            unreadCount: 5, pinned: false, kind: .group
        )
    ])
}
