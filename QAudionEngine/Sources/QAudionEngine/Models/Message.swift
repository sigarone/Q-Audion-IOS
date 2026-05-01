import Foundation

public struct Message: Equatable, Sendable, Hashable, Codable, Identifiable {

    public enum Direction: String, Sendable, Codable {
        case outgoing
        case incoming
    }

    public enum Status: String, Sendable, Codable {
        case sending
        case sent
        case delivered
        case read
        case failed
    }

    public let id: UUID
    public let conversationId: UUID
    public let direction: Direction
    public let plaintext: String           // decrypted content
    public let sentAt: Date
    public let deliveredAt: Date?
    public let readAt: Date?
    public let status: Status
    public let senderUserId: String?       // non-nil for incoming group messages
    /// W78: server-issued message id (string from `msg_receive.message_id`
    /// or `msg_send` ack). Persisted alongside the local UUID so delivery
    /// / read receipts (which only carry server ids) can be reconciled
    /// against the local row. Optional for backward compat with v1.0.140
    /// stored conversations — older messages decode with `nil` here and
    /// the receipts handler simply falls back to the broadcast-refresh
    /// path until those messages are re-sent or replaced.
    public let serverMessageId: String?
    /// W80: local filesystem path to a decrypted media payload (voice
    /// note / attachment). `nil` for plain text messages and for inbound
    /// voice notes that haven't finished downloading yet. Optional for
    /// backward compat with v1.0.140-v1.0.143 stored conversations.
    public let mediaLocalPath: String?
    /// W80: voice-note duration in milliseconds. Lifted from the qfile
    /// v3 marker on receive so the bubble can render "🎤 Nota vocale
    /// (4.2s)" before AVAudioPlayer probes the file.
    public let mediaDurationMs: Int64?
    /// W82: MIME type of the attached media (`audio/mp4`, `image/jpeg`,
    /// etc.). Lets the chat bubble route to the right preview view
    /// (voice note vs. image) without filename heuristics. Optional for
    /// backward compat — older messages decode with `nil` and the bubble
    /// falls back to the legacy "render-by-duration" branch.
    public let mediaMimeType: String?

    public init(id: UUID, conversationId: UUID, direction: Direction,
                plaintext: String, sentAt: Date, deliveredAt: Date?,
                readAt: Date?, status: Status, senderUserId: String? = nil,
                serverMessageId: String? = nil,
                mediaLocalPath: String? = nil,
                mediaDurationMs: Int64? = nil,
                mediaMimeType: String? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.direction = direction
        self.plaintext = plaintext
        self.sentAt = sentAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.status = status
        self.senderUserId = senderUserId
        self.serverMessageId = serverMessageId
        self.mediaLocalPath = mediaLocalPath
        self.mediaDurationMs = mediaDurationMs
        self.mediaMimeType = mediaMimeType
    }
}
