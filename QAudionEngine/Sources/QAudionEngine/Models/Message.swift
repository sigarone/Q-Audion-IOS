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

    public init(id: UUID, conversationId: UUID, direction: Direction,
                plaintext: String, sentAt: Date, deliveredAt: Date?,
                readAt: Date?, status: Status, senderUserId: String? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.direction = direction
        self.plaintext = plaintext
        self.sentAt = sentAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.status = status
        self.senderUserId = senderUserId
    }
}
