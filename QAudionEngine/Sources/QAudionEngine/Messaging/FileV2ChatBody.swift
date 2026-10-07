import Foundation

/// What the chat shows of a v2 file message: the values of a valid descriptor that the bubble, the preview and the
/// notification need. The key, the file id and the token are not here and never are.
public struct FileV2ChatFile: Equatable, Sendable {
    /// The name to show, already sanitised (`FileV2LocalName`): never empty, no control or bidirectional character.
    public let displayName: String
    /// The real size of the file; 0 when it is not known (a send that has not built its descriptor yet).
    public let size: UInt64
    public let mimeType: String?
    /// The `kind` of the descriptor (`file`, `image`, ...); this step shows every kind as a document.
    public let kind: String
    /// `ex`: -1 view once, 0 none, N seconds; `nil` when the sender did not set it.
    public let ex: Int64?
    /// `xp`: 0 export blocked; `nil` when the sender did not set it (allowed).
    public let xp: Int64?

    public init(displayName: String, size: UInt64, mimeType: String?, kind: String, ex: Int64?, xp: Int64?) {
        self.displayName = displayName
        self.size = size
        self.mimeType = mimeType
        self.kind = kind
        self.ex = ex
        self.xp = xp
    }

    init(descriptor: FileV2Descriptor) {
        self.init(displayName: FileV2LocalName.sanitised(descriptor.name), size: descriptor.size,
                  mimeType: descriptor.mimeType, kind: descriptor.kind.rawValue, ex: descriptor.ex, xp: descriptor.xp)
    }

    /// One line for the conversation list and a notification.
    public var previewText: String { FileV2ChatBody.glyph + displayName }
}

/// What a chat text message IS when the v2 file format is concerned (WIRE_SPEC 12.7.1, 12.7.6): ordinary text, a valid
/// descriptor, a descriptor that was recognised but rejected, or a control message.
///
/// Recognition is the library's, on the BYTES of the body exactly as decrypted (`FileV2Message.recognize`): never
/// `hasPrefix`, never a decoder that strips a byte order mark. A recognised body is NEVER ordinary text, whatever its content
/// and whatever the version: a rejected descriptor becomes one neutral placeholder (`unsupportedVersion` and `invalid`), a
/// control message (`qa_file_src`, `qa_file_cancel`, valid or not) is consumed and has no row at all.
public enum FileV2ChatBody: Equatable, Sendable {
    /// Not a file message: ordinary chat text.
    case text
    /// A valid descriptor.
    case file(FileV2ChatFile)
    /// Recognised, and its version is another one: "update the app".
    case unsupportedVersion
    /// Recognised, and rejected for any other reason.
    case invalid
    /// `qa_file_src` or `qa_file_cancel`: a control message, never shown.
    case control

    public static let glyph = "📎 "

    /// The two placeholders a rejected descriptor becomes (WIRE_SPEC 12.7.1): the content of the message is never shown, only one of these.
    public enum Placeholder: Sendable {
        /// The version of the file message is another one: "update the app".
        case unsupportedVersion
        /// Any other rejection.
        case invalid
    }

    /// The text of a placeholder. The engine has no localisation of its own: the default is Italian, and the app installs the
    /// localised lookup once at launch (set it before the first message is recorded; it is read at the time a row is written).
    public static var placeholderText: @Sendable (Placeholder) -> String = { placeholder in
        switch placeholder {
        case .unsupportedVersion: return "📎 Allegato non supportato: aggiorna l'app per aprirlo"
        case .invalid: return "📎 Allegato non valido"
        }
    }
    static var unsupportedText: String { placeholderText(.unsupportedVersion) }
    static var invalidText: String { placeholderText(.invalid) }
    /// `Message.mediaMimeType` of a file that is being sent or failed to be sent (no descriptor yet). It keeps such a row
    /// out of the text outbox (`ConversationStore.loadPendingOutboundTextMessages` is text only) so it can never be sent
    /// as the text it shows.
    public static let pendingMime = "application/x-qaudion-file-pending"

    public static func classify(utf8 body: Data) -> FileV2ChatBody {
        switch FileV2Message.recognize(utf8: body) {
        case .text:
            return .text
        case .descriptor(let descriptor):
            return .file(FileV2ChatFile(descriptor: descriptor))
        case .source, .cancel:
            return .control
        case .rejected(let kind, let error):
            guard kind == .descriptor else { return .control }
            if case .unsupportedVersion = error { return .unsupportedVersion }
            return .invalid
        }
    }

    /// `classify(utf8:)` for the text of a stored row (its UTF-8 bytes are the bytes that were decrypted).
    public static func classify(text: String) -> FileV2ChatBody { classify(utf8: Data(text.utf8)) }

    /// The user's own text may not be a file message (12.7.1): only the builders of the library produce such a body.
    public static func isUserTextAllowed(_ text: String) -> Bool { !FileV2Message.hasFileMessagePrefix(text) }

    /// The text that stands for the message wherever a body must not appear (placeholder row, preview, notification);
    /// `nil` for ordinary text and for a control message.
    public var displayText: String? {
        switch self {
        case .file(let file): return file.previewText
        case .unsupportedVersion: return Self.unsupportedText
        case .invalid: return Self.invalidText
        case .text, .control: return nil
        }
    }

    /// The parsed descriptor of a stored message, for the download; `nil` when the body is not a valid descriptor.
    public static func descriptor(ofBody body: String) -> FileV2Descriptor? {
        if case .descriptor(let descriptor) = FileV2Message.recognize(utf8: Data(body.utf8)) { return descriptor }
        return nil
    }

    /// What the bubble of `message` shows, or `nil` when the message is not a v2 file: a valid descriptor, or a file that is
    /// being sent (its row holds the name, with `pendingMime`).
    public static func bubbleInfo(for message: Message) -> FileV2ChatFile? {
        if message.mediaMimeType == pendingMime {
            var name = message.plaintext
            if name.hasPrefix(glyph) { name = String(name.dropFirst(glyph.count)) }
            return FileV2ChatFile(displayName: FileV2LocalName.sanitised(name), size: 0, mimeType: nil, kind: "file",
                                  ex: nil, xp: nil)
        }
        if case .file(let file) = classify(text: message.plaintext) { return file }
        return nil
    }

    /// The write boundary of an inbound user message: what to store and what to show of it. `nil` refuses it (a control
    /// message has no row, no preview, no unread). A valid descriptor keeps its body (the download needs it) and gets a
    /// preview of its own; a rejected one is stored as its placeholder, never as the body.
    static func applyInboundBoundary(_ message: Message, preview: String) -> (message: Message, preview: String)? {
        switch classify(text: message.plaintext) {
        case .text:
            return (message, preview)
        case .control:
            return nil
        case .file(let file):
            return (message, file.previewText)
        case .unsupportedVersion:
            return (message.replacingPlaintext(unsupportedText), unsupportedText)
        case .invalid:
            return (message.replacingPlaintext(invalidText), invalidText)
        }
    }
}

extension Message {
    /// The same message with another `plaintext`; every other field is carried over.
    func replacingPlaintext(_ text: String) -> Message {
        Message(id: id, conversationId: conversationId, direction: direction, plaintext: text, sentAt: sentAt,
                deliveredAt: deliveredAt, readAt: readAt, status: status, senderUserId: senderUserId,
                serverMessageId: serverMessageId, mediaLocalPath: mediaLocalPath, mediaDurationMs: mediaDurationMs,
                mediaMimeType: mediaMimeType, clientMsgId: clientMsgId, edited: edited, deletedAt: deletedAt,
                reactions: reactions, expiresAt: expiresAt, isViewOnce: isViewOnce, viewOnceOpened: viewOnceOpened,
                exportBlocked: exportBlocked, viaMesh: viaMesh, wireAttachmentId: wireAttachmentId,
                isPlaceholder: isPlaceholder)
    }
}
