import Foundation

// The part of message replies (WIRE_SPEC section 13) that depends on the rows a device holds: which rows can be quoted, what the
// builder takes from them, and what the quote block of a received reply shows (13.4 to 13.7). Pure functions on engine values; the
// app maps its rows onto them and draws the result.

/// What the builder takes from a row that is being answered.
public struct MessageReplyQuoteInfo: Equatable, Sendable {
    /// The server message id of the row, the `to` of the reply.
    public let serverMessageId: String
    public let kind: MessageReplyKind
    /// The text `q` is made from: the text of a plain message, the `b` of a reply, the `nm` of a file, image or video as received;
    /// empty for a voice note.
    public let source: String
    /// The row has a lifetime (a timer or view-once): the reply writes an empty `q`.
    public let ephemeral: Bool

    public init(serverMessageId: String, kind: MessageReplyKind, source: String, ephemeral: Bool) {
        self.serverMessageId = serverMessageId
        self.kind = kind
        self.source = source
        self.ephemeral = ephemeral
    }
}

/// A local row, reduced to the few properties the resolution rule reads (section 13.6). `id` is the server message id.
public struct MessageReplyRow: Equatable, Sendable {
    public let id: String
    /// `false` for a row of another conversation: it counts as not found.
    public let sameConversation: Bool
    public let kind: MessageReplyKind
    /// Its text, its `b` if it is a reply, or its `nm` if it is a file, image or video.
    public let text: String
    /// An opaque label of the sender of the row, shown as the author of the quote.
    public let author: String
    /// View-once, or a row whose content is never quoted (the placeholder of a rejected file message).
    public let viewOnce: Bool
    /// Expired or deleted: a tombstone.
    public let gone: Bool

    public init(id: String, sameConversation: Bool, kind: MessageReplyKind, text: String, author: String, viewOnce: Bool,
                gone: Bool) {
        self.id = id
        self.sameConversation = sameConversation
        self.kind = kind
        self.text = text
        self.author = author
        self.viewOnce = viewOnce
        self.gone = gone
    }
}

/// What the quote block of a received reply shows.
public struct MessageReplyBlock: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// `to` named a local row of the same conversation: author and excerpt come from the row, `q` is ignored. The block is a link.
        case local
        /// No such row: the text is `EXCERPT(q)` (nothing for a voice note). No author, not a link.
        case quote = "q"
        /// The row exists but is gone: nothing of it is shown, `q` neither. No author, not a link.
        case unavailable
    }

    public let source: Source
    /// The server message id the block opens, or `nil` when it is not a link.
    public let link: String?
    public let author: String?
    public let excerpt: String

    public init(source: Source, link: String?, author: String?, excerpt: String) {
        self.source = source
        self.link = link
        self.author = author
        self.excerpt = excerpt
    }
}

extension MessageReplyCodec {

    // MARK: Resolution (section 13.6)

    /// The quote block of a valid reply, given the local rows. A row of the same conversation with id `to`: its author and its excerpt
    /// (`EXCERPT` of its text, nothing for a voice note or a view-once row), and `q` is ignored, so a sender cannot make the quote of a
    /// message the receiver holds say something else; a gone row: nothing, `q` not shown; no row: `EXCERPT(q)`. Nothing is asked of the
    /// server or of another device.
    public static func resolve(_ reply: MessageReply, rows: [MessageReplyRow]) -> MessageReplyBlock {
        for row in rows where row.id == reply.to && row.sameConversation {
            if row.gone {
                return MessageReplyBlock(source: .unavailable, link: nil, author: nil, excerpt: "")
            }
            let hidden: Bool = row.viewOnce || row.kind == .voice
            let shown: String = hidden ? "" : excerpt(row.text)
            return MessageReplyBlock(source: .local, link: row.id, author: row.author, excerpt: shown)
        }
        return MessageReplyBlock(source: .quote, link: nil, author: nil, excerpt: reply.displayedQuote)
    }

    // MARK: Rows of the app

    /// What a stored message IS for the purposes of a quote.
    private struct Facts {
        let kind: MessageReplyKind
        let text: String
        /// The content is never quoted or shown (view-once, the placeholder of a rejected file message).
        let contentHidden: Bool
        let ephemeral: Bool
        /// A row the reply action may be offered on (before the server id is looked at).
        let quotable: Bool
    }

    private static func facts(of message: Message) -> Facts {
        let viewOnce: Bool = message.isViewOnce == true
        let hasLifetime: Bool = viewOnce || message.expiresAt != nil
        // A file being sent has no descriptor yet and no server id: nothing to quote.
        if FileV2ChatBody.isPending(mime: message.mediaMimeType) {
            return Facts(kind: .file, text: "", contentHidden: false, ephemeral: hasLifetime, quotable: false)
        }
        // A file transfer v2 message: the kind of its descriptor, and its `nm` as received.
        if let descriptor = FileV2ChatBody.descriptor(ofBody: message.plaintext) {
            guard let kind = MessageReplyKind(rawValue: descriptor.kind.rawValue) else {
                // An avatar or a thumbnail is not a chat message.
                return Facts(kind: .file, text: "", contentHidden: true, ephemeral: hasLifetime, quotable: false)
            }
            let name: String = kind == .voice ? "" : (descriptor.name ?? "")
            let timer: Bool = (descriptor.ex ?? 0) != 0
            return Facts(kind: kind, text: name, contentHidden: viewOnce, ephemeral: hasLifetime || timer, quotable: true)
        }
        // The placeholder of a rejected file message: its content is never quoted (section 13.5).
        if message.direction == .incoming,
           message.plaintext == FileV2ChatBody.unsupportedText || message.plaintext == FileV2ChatBody.invalidText {
            return Facts(kind: .text, text: "", contentHidden: true, ephemeral: hasLifetime, quotable: false)
        }
        // An attachment of an earlier format (a voice note, a photo, a document announced the old way): it can be answered
        // neither with a descriptor name nor with an excerpt, so the reply action is not offered on it.
        if let mime = message.mediaMimeType, !mime.isEmpty {
            let kind: MessageReplyKind
            if mime.hasPrefix("audio/") {
                kind = .voice
            } else if mime.hasPrefix("image/") {
                kind = .image
            } else {
                kind = .file
            }
            return Facts(kind: kind, text: "", contentHidden: true, ephemeral: hasLifetime, quotable: false)
        }
        if let duration = message.mediaDurationMs, duration > 0 {
            return Facts(kind: .voice, text: "", contentHidden: true, ephemeral: hasLifetime, quotable: false)
        }
        // Text: an ordinary text, a reply (its `b`) or a rejected reply shown as text (its whole body).
        let text: String = shownText(ofBody: message.plaintext)
        let usable: Bool = message.deletedAt == nil && message.isPlaceholder != true && message.viaMesh != true
            && !message.plaintext.isEmpty
        return Facts(kind: .text, text: text, contentHidden: viewOnce, ephemeral: hasLifetime, quotable: usable)
    }

    /// What the builder takes from `message`, or `nil` when the reply action is disabled for it (section 13.5): no server message id yet
    /// (a message of one's own still in the outbox), a message that travelled only over the BLE mesh, the placeholder of a rejected file
    /// message, a deleted row, an undecryptable placeholder, an attachment of an earlier format, an avatar or a thumbnail.
    public static func quoteInfo(for message: Message) -> MessageReplyQuoteInfo? {
        let found: Facts = facts(of: message)
        guard found.quotable else { return nil }
        guard message.deletedAt == nil, message.isPlaceholder != true, message.viaMesh != true else { return nil }
        guard let serverId = message.serverMessageId, isServerMessageId(serverId) else { return nil }
        return MessageReplyQuoteInfo(serverMessageId: serverId, kind: found.kind, source: found.text, ephemeral: found.ephemeral)
    }

    /// The local row for the resolution of a reply: `nil` when `message` has no server message id (it cannot be named by `to`).
    /// `author` is the label to show for the sender of the row. The row belongs to the conversation being displayed, so it counts as the
    /// same conversation.
    public static func row(for message: Message, author: String) -> MessageReplyRow? {
        guard let serverId = message.serverMessageId, !serverId.isEmpty else { return nil }
        let found: Facts = facts(of: message)
        return MessageReplyRow(id: serverId, sameConversation: true, kind: found.kind, text: found.text, author: author,
                               viewOnce: found.contentHidden, gone: message.deletedAt != nil)
    }
}
