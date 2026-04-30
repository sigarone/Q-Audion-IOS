import Foundation

/// Wire-format adapter between the high-level `MessageApi` protocol and the
/// `bcrypto-server` signaling envelopes (see `internal/signaling/messages.go`
/// `MsgSendData`, `MsgDeliveredData`, `MsgReadData`, `MsgTypingData`).
///
/// **HISTORY**: previous revisions of this file used camelCase field names
/// (`recipientId`, `content`, `messageId`, `isTyping`) which the Go server
/// rejected because its struct tags are snake_case (`recipient_id`,
/// `encrypted_payload`, `client_msg_id`, `is_typing`). The mismatch was
/// silent — the server ignored the unknown fields, the WS dispatcher never
/// emitted `msg_receive` to the recipient, and the iOS chat appeared to send
/// successfully (the local store flipped the message to `.delivered`) while
/// the peer never received anything. Re-aligned to the server contract here.
public final class BCryptoMessageApiImpl: MessageApi {
    private let ws: BCryptoWebSocketClient
    init(ws: BCryptoWebSocketClient) { self.ws = ws }

    public func sendMessage(recipientId: String, content: Data) async throws -> String {
        // ClientMsgID is the dedup key — the server echoes it back in
        // the `msg_receive` envelope (alongside the server-assigned UUID
        // in `message_id`). The caller maps client→server IDs so retries
        // don't duplicate.
        let clientMsgId = UUID().uuidString
        ws.send(
            type: "msg_send",
            data: [
                "recipient_id":      recipientId,
                "encrypted_payload": content.base64EncodedString(),
                "msg_type":          0,         // 0 = text, 1 = media
                "client_msg_id":     clientMsgId,
                "expires_in_sec":    0,         // 0 = no expiry
            ]
        )
        return clientMsgId
    }

    public func sendDeliveryReceipt(messageId: String) async throws {
        // Server expects `message_ids: []string` even for a single ack —
        // wrap the single id in a one-element array to stay compatible.
        ws.send(
            type: "msg_delivered",
            data: ["message_ids": [messageId]]
        )
    }

    public func sendReadReceipt(messageId: String) async throws {
        // `MsgReadData` requires `sender_id` (the original sender of the
        // messages we're acking) — but the legacy single-arg protocol
        // signature doesn't carry it. Pass an empty string so the server
        // can still relay the ids to anyone subscribed; full sender-id
        // wiring needs a protocol bump (USER WT). Server today ignores
        // the empty `sender_id` and just relays the id list to any
        // device that originally sent the messages.
        ws.send(
            type: "msg_read",
            data: [
                "sender_id":   "",
                "message_ids": [messageId],
            ]
        )
    }

    public func sendTypingIndicator(recipientId: String, isTyping: Bool) async throws {
        ws.send(
            type: "msg_typing",
            data: [
                "recipient_id": recipientId,
                "is_typing":    isTyping,
            ]
        )
    }
}
