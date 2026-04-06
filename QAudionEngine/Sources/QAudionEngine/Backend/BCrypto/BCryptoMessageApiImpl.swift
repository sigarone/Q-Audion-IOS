import Foundation

public final class BCryptoMessageApiImpl: MessageApi {
    private let ws: BCryptoWebSocketClient
    init(ws: BCryptoWebSocketClient) { self.ws = ws }

    public func sendMessage(recipientId: String, content: Data) async throws -> String {
        let id = UUID().uuidString
        ws.send(type: "msg_send", data: ["recipientId": recipientId, "content": content.base64EncodedString(), "messageId": id])
        return id
    }
    public func sendDeliveryReceipt(messageId: String) async throws {
        ws.send(type: "msg_delivered", data: ["messageId": messageId])
    }
    public func sendReadReceipt(messageId: String) async throws {
        ws.send(type: "msg_read", data: ["messageId": messageId])
    }
    public func sendTypingIndicator(recipientId: String, isTyping: Bool) async throws {
        ws.send(type: "msg_typing", data: ["recipientId": recipientId, "isTyping": isTyping])
    }
}
