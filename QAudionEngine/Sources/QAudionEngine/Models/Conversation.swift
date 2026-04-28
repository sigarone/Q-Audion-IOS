import Foundation

public struct Conversation: Equatable, Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let peerUserId: String
    public let peerDisplayName: String
    public let lastMessagePreview: String?
    public let lastActivity: Date
    public let unreadCount: Int
    public let pinned: Bool

    public init(id: UUID, peerUserId: String, peerDisplayName: String,
                lastMessagePreview: String?, lastActivity: Date,
                unreadCount: Int, pinned: Bool) {
        self.id = id
        self.peerUserId = peerUserId
        self.peerDisplayName = peerDisplayName
        self.lastMessagePreview = lastMessagePreview
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
        self.pinned = pinned
    }
}
