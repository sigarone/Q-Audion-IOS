import Foundation

public struct ContactsListViewModel: ViewModelProtocol {

    public struct Item: Equatable, Sendable, Hashable {
        public let userId: String
        public let displayName: String
        public let phoneHash: String         // §5.1 64 hex
        public let avatarUrl: URL?
        public let isOnline: Bool
        public let unreadMessageCount: Int
        public let isVerified: Bool          // SAS or NFC verified

        public init(userId: String, displayName: String, phoneHash: String,
                    avatarUrl: URL?, isOnline: Bool,
                    unreadMessageCount: Int, isVerified: Bool) {
            self.userId = userId
            self.displayName = displayName
            self.phoneHash = phoneHash
            self.avatarUrl = avatarUrl
            self.isOnline = isOnline
            self.unreadMessageCount = unreadMessageCount
            self.isVerified = isVerified
        }
    }

    public let items: [Item]
    public let searchQuery: String

    public init(items: [Item], searchQuery: String = "") {
        self.items = items
        self.searchQuery = searchQuery
    }

    /// Items filtered by `searchQuery` (case-insensitive substring match
    /// on displayName).
    public var filteredItems: [Item] {
        guard !searchQuery.isEmpty else { return items }
        let q = searchQuery.lowercased()
        return items.filter { $0.displayName.lowercased().contains(q) }
    }

    public static let mock = ContactsListViewModel(items: [
        Item(
            userId: "user-alice", displayName: "Alice (Pixel 7)",
            phoneHash: String(repeating: "ab", count: 32),
            avatarUrl: nil, isOnline: true,
            unreadMessageCount: 2, isVerified: true
        ),
        Item(
            userId: "user-bob", displayName: "Bob (iPhone 14)",
            phoneHash: String(repeating: "cd", count: 32),
            avatarUrl: nil, isOnline: false,
            unreadMessageCount: 0, isVerified: false
        ),
        Item(
            userId: "user-charlie", displayName: "Charlie (Desktop)",
            phoneHash: String(repeating: "ef", count: 32),
            avatarUrl: nil, isOnline: true,
            unreadMessageCount: 5, isVerified: true
        )
    ])
}
