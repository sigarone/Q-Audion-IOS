import Foundation

public protocol MessageApi {
    /// Send an encrypted message wire blob.
    ///
    /// - Parameters:
    ///   - recipientId: the peer's userId
    ///   - content: the encrypted wire blob (already sealed by the caller)
    ///   - clientMsgId: the dedup key used as AEAD AAD on the send path.
    ///     MUST be the same UUID string that was passed to `MessageCrypto`
    ///     or `MessageRatchet.encrypt` as `clientMsgId` so the receiver can
    ///     reconstruct the identical AAD and pass AEAD verification.
    ///     The server echoes this verbatim in the recipient's `msg_receive`
    ///     envelope under `client_msg_id`.
    func sendMessage(recipientId: String, content: Data, clientMsgId: String) async throws -> String
    func sendDeliveryReceipt(messageId: String) async throws
    func sendReadReceipt(messageId: String) async throws
    /// W84 — batch read receipt with explicit `sender_id` so the server
    /// can relay the relevant ids to the original sender's open
    /// session(s) (✓✓ blue check on their UI).
    func sendReadReceipts(senderId: String, messageIds: [String]) async throws
    func sendTypingIndicator(recipientId: String, isTyping: Bool) async throws
}
