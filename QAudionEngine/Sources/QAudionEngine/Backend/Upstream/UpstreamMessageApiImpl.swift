import Foundation

public final class UpstreamMessageApiImpl: MessageApi {
    public init() {}
    public func sendMessage(recipientId: String, content: Data) async throws -> String { UUID().uuidString }
    public func sendDeliveryReceipt(messageId: String) async throws {}
    public func sendReadReceipt(messageId: String) async throws {}
    public func sendTypingIndicator(recipientId: String, isTyping: Bool) async throws {}
}
