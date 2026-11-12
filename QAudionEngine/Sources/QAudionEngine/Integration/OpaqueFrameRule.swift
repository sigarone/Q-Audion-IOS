import Foundation

/// The size rule of a handshake bundle (design section 5.6): the serialized WebSocket text frame that carries it must satisfy
/// `frame + 128 <= 24576`.
///
/// The quantity measured is the frame this app writes: the envelope object of `BCryptoWebSocketClient.trySend` serialized with
/// `JSONSerialization`, which is the serializer and the escaping of the socket (every quote and every slash of the bundle text is
/// escaped again by it). The 128 bytes are the margin for the `sender_id` and `sender_device_id` the server adds for the recipient.
/// The recipient id and the envelope id are fixed 36 character placeholders: only their length matters.
public enum OpaqueFrameRule {

    public static let maxFrameBytes = 24_576
    public static let serverMarginBytes = 128

    public static let placeholderId = "00000000-0000-0000-0000-000000000000"

    /// The exact length of the frame `sendOpaqueMessageString(recipientId:payload:)` writes for `payload`.
    public static func frameBytes(payload: String, recipientId: String = placeholderId) -> Int {
        let message = BCryptoWebSocketClient.envelope(
            type: "opaque_message", data: ["recipient_id": recipientId, "data": payload], id: placeholderId)
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return Int.max / 2 }
        return data.count
    }

    /// True when a payload may be written as one frame.
    public static func fits(payload: String, recipientId: String = placeholderId) -> Bool {
        frameBytes(payload: payload, recipientId: recipientId) + serverMarginBytes <= maxFrameBytes
    }

    /// Same, from the frame length already measured.
    public static func fits(frameBytes: Int) -> Bool {
        frameBytes + serverMarginBytes <= maxFrameBytes
    }
}
