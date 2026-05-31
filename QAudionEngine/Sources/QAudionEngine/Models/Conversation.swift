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
    /// W89: muted conversations don't trigger banner / sound on inbound
    /// messages and skip the unread-bump (their badge stays clean).
    /// W498: changed from Bool? to Bool — nil was being serialised as NULL
    /// by GRDB, violating the NOT NULL constraint on conversations.muted and
    /// dropping every new conversation created from an incoming message.
    public let muted: Bool
    /// W441: per-conversation ephemeral timer in seconds.
    /// 0 or nil = off.  Positive value = TTL applied to each new
    /// outbound message (expiresAt = sentAt + ephemeralTimerSeconds).
    /// Mirrors Android's ConversationEntity.ephemeralTimerSec.
    /// Optional for Codable backward compat with pre-W441 stored rows.
    public let ephemeralTimerSeconds: Int?
    /// Screenshot permission granted by the remote peer for this conversation.
    /// nil = not requested. false = denied. true = granted.
    /// Stored locally — the peer sends a control envelope to set it.
    public let screenshotGrantedByPeer: Bool?

    public init(id: UUID, peerUserId: String, peerDisplayName: String,
                lastMessagePreview: String?, lastActivity: Date,
                unreadCount: Int, pinned: Bool, kind: Kind = .oneToOne,
                muted: Bool = false,
                ephemeralTimerSeconds: Int? = nil,
                screenshotGrantedByPeer: Bool? = nil) {
        self.id = id
        self.peerUserId = peerUserId
        self.peerDisplayName = peerDisplayName
        self.lastMessagePreview = lastMessagePreview
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
        self.pinned = pinned
        self.kind = kind
        self.muted = muted
        self.ephemeralTimerSeconds = ephemeralTimerSeconds
        self.screenshotGrantedByPeer = screenshotGrantedByPeer
    }
}
