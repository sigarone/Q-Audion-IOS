import Foundation

/// Sends encrypted messages through Signal-compatible REST endpoints.
///
/// Messages are already encrypted by `MessageCrypto` before reaching this layer.
/// This provider is a thin transport wrapper that delivers opaque ciphertext blobs
/// via Signal's message submission endpoint and handles delivery/read receipts
/// plus typing indicators.
public final class UpstreamMessageApiImpl: MessageApi {
    private let rest: BCryptoRestClient

    init(rest: BCryptoRestClient) {
        self.rest = rest
    }

    // MARK: - MessageApi

    /// Submit an encrypted message payload to a Signal-compatible endpoint.
    /// The `content` is already encrypted -- we just transport it.
    public func sendMessage(recipientId: String, content: Data) async throws -> String {
        let messageId = UUID().uuidString
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let envelope: [String: Any] = [
            "destination": recipientId,
            "timestamp": timestamp,
            "messageId": messageId,
            "type": 6, // Signal CIPHERTEXT (pre-encrypted opaque content)
            "content": content.base64EncodedString()
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        _ = try await rest.post("/v1/messages/\(recipientId)", body: body)

        return messageId
    }

    /// Notify the server that a message was delivered to this device.
    public func sendDeliveryReceipt(messageId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "messageId": messageId,
            "type": "delivery"
        ])
        _ = try await rest.post("/v1/receipts/\(messageId)", body: body)
    }

    /// Notify the server that a message was read by this user.
    public func sendReadReceipt(messageId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "messageId": messageId,
            "type": "read"
        ])
        _ = try await rest.post("/v1/receipts/\(messageId)", body: body)
    }

    /// W84 — batch read receipts. Signal-compatible REST has no native
    /// batch endpoint, so fall back to N parallel single-id calls.
    public func sendReadReceipts(senderId: String, messageIds: [String]) async throws {
        // Parallel for speed; per-id failures don't block the rest.
        await withTaskGroup(of: Void.self) { group in
            for id in messageIds {
                group.addTask { [weak self] in
                    try? await self?.sendReadReceipt(messageId: id)
                }
            }
        }
    }

    /// Send a typing indicator to the recipient.
    public func sendTypingIndicator(recipientId: String, isTyping: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "destination": recipientId,
            "action": isTyping ? "STARTED" : "STOPPED"
        ])
        _ = try await rest.post("/v1/messages/typing/\(recipientId)", body: body)
    }
}
