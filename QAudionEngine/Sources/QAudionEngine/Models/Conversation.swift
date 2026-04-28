import Foundation

public struct Conversation: Equatable, Sendable, Hashable, Codable, Identifiable {

    public enum Kind: String, Sendable, Codable, Equatable {
        case oneToOne = "1:1"
        case group
    }

    public let id: UUID
    public let peerUserId: String
    public let peerDisplayName: String
    public let lastMessagePreview: String?
    public let lastActivity: Date
    public let unreadCount: Int
    public let pinned: Bool
    public let kind: Kind

    public init(id: UUID, peerUserId: String, peerDisplayName: String,
                lastMessagePreview: String?, lastActivity: Date,
                unreadCount: Int, pinned: Bool, kind: Kind = .oneToOne) {
        self.id = id
        self.peerUserId = peerUserId
        self.peerDisplayName = peerDisplayName
        self.lastMessagePreview = lastMessagePreview
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
        self.pinned = pinned
        self.kind = kind
    }
}
