import Foundation

// The write boundary of an inbound USER message, for a body that begins with `{"qa_loc":` (WIRE_SPEC 14.3.2, 14.3.3, 14.6.2 step 6).
// `ConversationStore.recordInboundUserMessage` calls it through `FileV2ChatBody.applyInboundBoundary`, so every path that records an
// inbound 1:1 row (live, buffered retry, pending sync, mesh) passes here. A recognised body is NEVER stored as the text it is:
//
//  - a valid pin keeps its body (the coordinates are the message) and shows the fixed label;
//  - a valid live start keeps its LOCAL FORM only (`k` is dropped here, whatever the caller did before), exempt from the timer of the
//    conversation while the share runs (the app sets the expiry when the share ends) and never view-once;
//  - a body that is rejected (invalid, a newer version, a live start over the mesh) becomes one placeholder, never its content.
//
// The share itself (the key, the end time, the supersession) is the app's `LocationShareReceiver`, fed from the decrypted bytes before
// the row is written; this boundary is what guarantees that no row ever holds `k`.
enum LocationInboundBoundary {

    static func apply(_ message: Message) -> (message: Message, preview: String) {
        let body = Data(message.plaintext.utf8)
        let channel: LocationChannel = message.viaMesh == true ? .mesh : .chat
        switch LocationCodec.recognize(utf8: body, channel: channel) {
        case .location(.pin):
            return (message.replacing(plaintext: message.plaintext, expiresAt: message.expiresAt), LocationLabels.text(.pin))
        case .location(.live(let start, _)):
            let local: String = LocationRowForm.localForm(of: start)
            return (message.replacing(plaintext: local, expiresAt: nil), LocationLabels.text(.live))
        case .rejected(let rejection):
            let placeholder: LocationBodyPlaceholder = LocationBodyPlaceholder.forRejection(rejection, body: body)
            let text: String = LocationBodyPlaceholder.text(placeholder)
            return (message.replacing(plaintext: text, expiresAt: message.expiresAt), text)
        case .notLocation:
            return (message, message.plaintext)
        }
    }
}

extension LocationBackupBody {
    /// The message as a backup holds it: see `normalised(_:)`. Every other field is carried over.
    public static func normalised(_ message: Message) -> Message {
        let body: String = normalised(message.plaintext)
        guard body != message.plaintext else { return message }
        return message.replacing(plaintext: body, expiresAt: message.expiresAt, isViewOnce: message.isViewOnce,
                                 viewOnceOpened: message.viewOnceOpened)
    }
}

extension Message {
    /// The same message with another `plaintext` and expiry, and never view-once (a location is not): every other field is carried over.
    func replacing(plaintext text: String, expiresAt expiry: Date?) -> Message {
        replacing(plaintext: text, expiresAt: expiry, isViewOnce: nil, viewOnceOpened: nil)
    }

    /// The same message with another `plaintext`, expiry and view-once state: every other field is carried over.
    func replacing(plaintext text: String, expiresAt expiry: Date?, isViewOnce viewOnce: Bool?, viewOnceOpened opened: Bool?) -> Message {
        Message(id: id, conversationId: conversationId, direction: direction, plaintext: text, sentAt: sentAt,
                deliveredAt: deliveredAt, readAt: readAt, status: status, senderUserId: senderUserId,
                serverMessageId: serverMessageId, mediaLocalPath: mediaLocalPath, mediaDurationMs: mediaDurationMs,
                mediaMimeType: mediaMimeType, clientMsgId: clientMsgId, edited: edited, deletedAt: deletedAt,
                reactions: reactions, expiresAt: expiry, isViewOnce: viewOnce, viewOnceOpened: opened,
                exportBlocked: exportBlocked, viaMesh: viaMesh, wireAttachmentId: wireAttachmentId,
                isPlaceholder: isPlaceholder)
    }
}
