import Foundation

public protocol MessageApi {
    func sendMessage(recipientId: String, content: Data) async throws -> String
    func sendDeliveryReceipt(messageId: String) async throws
    func sendReadReceipt(messageId: String) async throws
    /// W84 — batch read receipt with explicit `sender_id` so the server
    /// can relay the relevant ids to the original sender's open
    /// session(s) (✓✓ blue check on their UI).
    func sendReadReceipts(senderId: String, messageIds: [String]) async throws
    func sendTypingIndicator(recipientId: String, isTyping: Bool) async throws
}
