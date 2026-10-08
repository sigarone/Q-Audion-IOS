import SwiftUI
import QAudionEngine

// Message replies (WIRE_SPEC section 13), the part that draws. Everything here takes plain values and engine types: no AppState (CLAUDE.md
// section 16), and the decisions (recognition, resolution of `to`, EXCERPT) are the engine's (`MessageReplyCodec`).
//
// This code was written on a machine that cannot compile Swift: the macOS CI job is the only thing that has run it.

/// What the quote block of a received reply shows and says.
struct ReplyQuoteDisplay: Equatable {
    /// The author of the quoted row, or `nil` when the block shows no author (the row is not found or gone).
    let author: String?
    /// The line under the author: the excerpt, a label of the kind, or the "no longer available" line.
    let text: String
    /// `true` when `text` is a label and not text of the quoted message: drawn in italics.
    let textIsLabel: Bool
    /// The local row the block opens, or `nil` when it is not a link.
    let linkId: UUID?
    /// What VoiceOver reads before the text of the reply ("In risposta a ...").
    let accessibilityText: String
}

/// Turns a valid reply and the rows of the open conversation into what is drawn. Pure: it reads, it never writes.
enum ReplyQuotePresenter {

    static var meLabel: String {
        String(localized: "reply.author_me", defaultValue: "Tu", comment: "Author label of the quote block when the quoted message is the user's own.")
    }

    /// The label that stands for the kind of a message whose text is not shown (a voice note, a photo, a video, a document).
    static func kindLabel(_ kind: MessageReplyKind) -> String {
        switch kind {
        case .voice: return FileV2ChatBody.kindLabelText(.voice)
        case .image: return FileV2ChatBody.kindLabelText(.image)
        case .video: return FileV2ChatBody.kindLabelText(.video)
        case .file: return String(localized: "reply.kind.file", defaultValue: "📎 Allegato", comment: "Quote block of a reply to a document that has no name.")
        case .text: return String(localized: "reply.generic_message", defaultValue: "Messaggio", comment: "Quote block of a reply when the text of the quoted message is not shown.")
        }
    }

    /// The block of `reply` among `messages` (the rows of the same conversation). `to` is matched against the server message id of
    /// the rows, never against the local id; an unknown id falls back to the sanitised `q` and nothing is asked of the server.
    static func display(for reply: MessageReply, messages: [Message], meLabel: String, peerLabel: String) -> ReplyQuoteDisplay {
        var rows: [MessageReplyRow] = []
        var localIds: [String: UUID] = [:]
        for message in messages where message.serverMessageId == reply.to {
            let label: String = message.direction == .outgoing ? meLabel : peerLabel
            if let row = MessageReplyCodec.row(for: message, author: label) {
                rows.append(row)
                localIds[row.id] = message.id
            }
        }
        let block = MessageReplyCodec.resolve(reply, rows: rows)
        // The kind of the row that is shown wins over the `k` the sender wrote.
        let kind: MessageReplyKind = rows.first?.kind ?? reply.kind
        let shownText: String
        var isLabel = false
        switch block.source {
        case .unavailable:
            shownText = String(localized: "reply.unavailable", defaultValue: "Messaggio non più disponibile", comment: "Quote block of a reply whose quoted message has expired or been deleted.")
            isLabel = true
        case .local, .quote:
            if block.excerpt.isEmpty {
                shownText = kindLabel(kind)
                isLabel = true
            } else {
                shownText = block.excerpt
            }
        }
        let linkId: UUID? = block.link.flatMap { localIds[$0] }
        return ReplyQuoteDisplay(
            author: block.author, text: shownText, textIsLabel: isLabel, linkId: linkId,
            accessibilityText: accessibilityText(author: block.author, excerpt: block.excerpt, kind: kind,
                                                  unavailable: block.source == .unavailable))
    }

    /// "In risposta a <author>: <excerpt>"; "In risposta a un messaggio" when there is no author or no excerpt; "In risposta a un
    /// messaggio vocale" for a voice note (WIRE_SPEC 13.7).
    static func accessibilityText(author: String?, excerpt: String, kind: MessageReplyKind, unavailable: Bool) -> String {
        if kind == .voice && !unavailable {
            return String(localized: "reply.a11y.to_voice", defaultValue: "In risposta a un messaggio vocale", comment: "VoiceOver text of the quote block of a reply to a voice note.")
        }
        if let author = author, !author.isEmpty, !excerpt.isEmpty {
            let format: String = String(localized: "reply.a11y.to_author_excerpt", defaultValue: "In risposta a %1$@: %2$@", comment: "VoiceOver text of the quote block: %1$@ is the author, %2$@ the excerpt of the quoted message.")
            return String(format: format, author, excerpt)
        }
        return String(localized: "reply.a11y.to_message", defaultValue: "In risposta a un messaggio", comment: "VoiceOver text of the quote block when it has no author or no excerpt.")
    }

    /// The line of the composer banner while a reply is being written. A message with a lifetime shows no content (its `q` is empty).
    static func bannerExcerpt(for info: MessageReplyQuoteInfo) -> String {
        if info.ephemeral {
            return String(localized: "reply.banner.ephemeral", defaultValue: "Messaggio a scadenza", comment: "Composer banner when the message being answered has a timer or is view-once: its content is not shown.")
        }
        let line = MessageReplyCodec.excerpt(info.source)
        if !line.isEmpty && info.kind != .voice { return line }
        return kindLabel(info.kind)
    }
}

/// The quote block drawn at the top of the bubble of a reply: a bar, the author, the excerpt. A link (the quoted row is here) opens
/// the quoted message; otherwise it is plain text. One accessible element, read before `b`.
struct ReplyQuoteBlockView: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let isSent: Bool
    let display: ReplyQuoteDisplay
    let onOpen: (UUID) -> Void

    var body: some View {
        blockWithAction
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: display.accessibilityText))
    }

    /// Only a tap gesture (not a Button): a Button would swallow the long press that opens the menu of the message.
    @ViewBuilder
    private var blockWithAction: some View {
        if let id = display.linkId {
            content
                .contentShape(Rectangle())
                .onTapGesture { onOpen(id) }
                .accessibilityAddTraits(.isLink)
                .accessibilityHint(Text(verbatim: goToMessageText))
                .accessibilityAction { onOpen(id) }
        } else {
            content
        }
    }

    private var goToMessageText: String {
        String(localized: "reply.a11y.go_to_message", defaultValue: "Vai al messaggio", comment: "VoiceOver action of the quote block of a reply: scroll to the quoted message.")
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(isSent ? scheme.primary : scheme.secondary)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                if let author = display.author, !author.isEmpty {
                    Text(verbatim: author)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(1)
                }
                lineText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var lineText: some View {
        if display.textIsLabel {
            Text(verbatim: display.text)
                .qaudionStyle(type.bodySmall)
                .italic()
                .foregroundStyle(scheme.onSurfaceVariant)
                .lineLimit(2)
        } else {
            Text(verbatim: display.text)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface.opacity(0.85))
                .lineLimit(2)
        }
    }
}

/// The body of a reply bubble: the quote block over `inner` (the text, `b`, possibly drawn by the Enigma effect). While the effect holds
/// the row back or animates it, the quote is invisible and not announced: the block and `b` are revealed together, and neither `q` nor
/// the local excerpt shows before (WIRE_SPEC 13.7). The block keeps its place, so nothing jumps at the reveal.
struct ReplyQuotedBody<Inner: View>: View {
    @ObservedObject private var host: EnigmaHost = EnigmaHost.shared

    let rowId: String
    let isSent: Bool
    let display: ReplyQuoteDisplay
    let onOpen: (UUID) -> Void
    private let inner: Inner

    init(rowId: String, isSent: Bool, display: ReplyQuoteDisplay, onOpen: @escaping (UUID) -> Void,
         @ViewBuilder inner: () -> Inner) {
        self.rowId = rowId
        self.isSent = isSent
        self.display = display
        self.onOpen = onOpen
        self.inner = inner()
    }

    var body: some View {
        let hidden: Bool = host.activeId == rowId || host.isHeldBack(rowId)
        VStack(alignment: .leading, spacing: 8) {
            ReplyQuoteBlockView(isSent: isSent, display: display, onOpen: onOpen)
                .opacity(hidden ? 0 : 1)
                .accessibilityHidden(hidden)
            inner
        }
    }
}
