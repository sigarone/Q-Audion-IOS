import Foundation

public protocol MessageApi {
    func sendMessage(recipientId: String, content: Data) async throws -> String
    func sendDeliveryReceipt(messageId: String) async throws
    func sendReadReceipt(messageId: String) async throws
    func sendTypingIndicator(recipientId: String, isTyping: Bool) async throws
}
