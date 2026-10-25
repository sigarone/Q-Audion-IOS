import Foundation
import QAudionEngine

/// W139 — plaintext conversation export.
///
/// Produces a `.txt` file under `tmp/` ready to feed into the system
/// share sheet. Mirrors WhatsApp's "Esporta chat" file format closely
/// enough to feel familiar:
///
/// ```
/// Q-Audion — Chat con Mario Rossi
/// Esportata il 01/05/2026 14:32
/// 5 messaggi
///
/// [01/05/2026, 14:30] Tu: Ciao
/// [01/05/2026, 14:31] Mario Rossi: Ehi, come va?
/// [01/05/2026, 14:32] Tu: <messaggio eliminato>
/// ```
///
/// Attachments (voice / image) render as a placeholder line with the
/// MIME type and rough size — full media export would require zipping
/// the cache files together with the transcript, which is outside the
/// scope of this wave.
///
/// The output is plaintext, NOT encrypted. Once the user shares it via
/// `UIActivityViewController`, the bytes leave the app sandbox under
/// their direction. The file lands under `FileManager.default
/// .temporaryDirectory` so iOS reaps it automatically — typically at
/// next app launch or under storage pressure.
enum ConversationExporter {

    /// Build a transcript and write it to a temporary `.txt` file.
    /// Returns the file URL on success, nil on I/O failure.
    static func export(messages: [Message],
                       peerDisplayName: String,
                       myDisplayLabel: String = ReplyQuotePresenter.meLabel) -> URL? {
        let header = buildHeader(peerDisplayName: peerDisplayName,
                                 messageCount: messages.count)
        let body = messages
            .sorted { $0.sentAt < $1.sentAt }
            .map { format(message: $0,
                          among: messages,
                          peerDisplayName: peerDisplayName,
                          myDisplayLabel: myDisplayLabel) }
            .joined(separator: "\n")
        let transcript = header + "\n\n" + body + "\n"

        // Write to a stable per-export filename so subsequent shares
        // overwrite cleanly without piling up tmp/ entries.
        let safePeer = peerDisplayName
            .replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let stamp = Self.fileStampFormatter.string(from: Date())
        let fileName = "QAudion_chat_\(safePeer.isEmpty ? "export" : safePeer)_\(stamp).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try transcript.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            print("[ConversationExporter] write failed: \(error)")
            return nil
        }
    }

    // MARK: - Private formatters

    private static func buildHeader(peerDisplayName: String,
                                    messageCount: Int) -> String {
        let exportedAt = humanFormatter.string(from: Date())
        let titleLine: String = String(localized: "chat.export.title", defaultValue: "Q-Audion — Chat con \(peerDisplayName)", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): title; %@ is the name of the contact.")
        let exportedLine: String = String(localized: "chat.export.exported_on", defaultValue: "Esportata il \(exportedAt)", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): when it was exported; %@ is the date and time.")
        let countLine: String = messageCount == 1
            ? String(localized: "chat.export.count_one", defaultValue: "1 messaggio", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): the transcript holds exactly one message.")
            : String(localized: "chat.export.count_other", defaultValue: "\(messageCount) messaggi", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): number of messages in the transcript; %lld is the count.")
        return [titleLine, exportedLine, countLine].joined(separator: "\n")
    }

    private static func format(message m: Message,
                               among all: [Message],
                               peerDisplayName: String,
                               myDisplayLabel: String) -> String {
        let stamp = humanFormatter.string(from: m.sentAt)
        let author = (m.direction == .outgoing) ? myDisplayLabel : peerDisplayName
        let body: String
        if m.deletedAt != nil {
            body = String(localized: "chat.export.deleted_message", defaultValue: "<messaggio eliminato>", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): a message that was deleted.")
        } else if let shown = FileV2ChatBody.classify(text: m.plaintext).displayText {
            // A file message (WIRE_SPEC 12.7.1): its one-line preview, never the descriptor (it holds the key of the file).
            body = shown
        } else if FileV2ChatBody.isPending(mime: m.mediaMimeType) {
            // A file still being sent: its row already is the one-line name.
            body = m.plaintext
        } else if let mime = m.mediaMimeType, !mime.isEmpty {
            // Attachment placeholder — voice notes (audio/mp4) /
            // images (image/jpeg) etc. The actual binary stays in the
            // cache — exporting it inline would balloon the file.
            let dur = m.mediaDurationMs.map { "\($0)ms" } ?? ""
            body = dur.isEmpty
                ? String(localized: "chat.export.attachment", defaultValue: "<allegato: \(mime)>", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): an attachment; %@ is its MIME type.")
                : String(localized: "chat.export.attachment_with_duration", defaultValue: "<allegato: \(mime) · \(dur)>", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): an attachment with a duration; %1$@ is its MIME type, %2$@ the duration such as 4200ms.")
        } else {
            // Strip newlines from the message body so each entry stays
            // on a single line — easier to scan, paste, search.
            // A reply is exported as its `b` (WIRE_SPEC 13.7), never the object, followed by what it answers.
            let shown: String = MessageReplyCodec.shownText(ofBody: m.plaintext)
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            body = shown + replyNote(for: m, among: all, peerDisplayName: peerDisplayName, myDisplayLabel: myDisplayLabel)
        }
        let editedSuffix: String = (m.edited == true) ? " " + String(localized: "chat.export.edited", defaultValue: "(modificato)", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): appended to a message that was edited.") : ""
        return "[\(stamp)] \(author): \(body)\(editedSuffix)"
    }

    /// ` (in risposta a <autore>: <estratto>)` for a valid reply, empty for any other row. The quote is resolved as the chat resolves it
    /// (`MessageReplyCodec.resolve`, WIRE_SPEC 13.6): the local row of the same conversation gives author and excerpt, a row that is gone
    /// gives "non disponibile" (never the `q` it carried), an unknown row gives the sanitised `q` without an author.
    private static func replyNote(for m: Message, among all: [Message], peerDisplayName: String, myDisplayLabel: String) -> String {
        guard MessageReplyCodec.hasReplyPrefix(m.plaintext),
              case .reply(let reply) = MessageReplyCodec.recognize(m.plaintext) else { return "" }
        var rows: [MessageReplyRow] = []
        for other in all where other.serverMessageId == reply.to {
            let author: String = (other.direction == .outgoing) ? myDisplayLabel : peerDisplayName
            if let row = MessageReplyCodec.row(for: other, author: author) { rows.append(row) }
        }
        let block = MessageReplyCodec.resolve(reply, rows: rows)
        switch block.source {
        case .unavailable:
            return " " + String(localized: "chat.export.reply_unavailable", defaultValue: "(in risposta a un messaggio: non disponibile)", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): appended to a reply whose original message is no longer available.")
        case .local:
            let who: String = block.author ?? String(localized: "chat.export.reply_a_message", defaultValue: "un messaggio", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): stands for the author of the original message when it is not known (it follows 'in reply to').")
            return " " + (block.excerpt.isEmpty
                ? String(localized: "chat.export.reply_to", defaultValue: "(in risposta a \(who))", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): appended to a reply; %@ is the author of the original message.")
                : String(localized: "chat.export.reply_to_excerpt", defaultValue: "(in risposta a \(who): \(block.excerpt))", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): appended to a reply; %1$@ is the author of the original message, %2$@ its text."))
        case .quote:
            return " " + (block.excerpt.isEmpty
                ? String(localized: "chat.export.reply_to_message", defaultValue: "(in risposta a un messaggio)", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): appended to a reply to a message that is not in the transcript.")
                : String(localized: "chat.export.reply_to_message_excerpt", defaultValue: "(in risposta a un messaggio: \(block.excerpt))", comment: "Line of the exported plain-text transcript of a conversation (shared as a .txt file): appended to a reply to a message that is not in the transcript; %@ is the quoted text."))
        }
    }

    /// 01/05/2026, 14:32 — short date+time in the app's effective language.
    private static let humanFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: AppLanguageManager.effectiveLanguageCode)
        f.dateFormat = "dd/MM/yyyy, HH:mm"
        return f
    }()

    /// Filename stamp — sortable, no separator chars that confuse
    /// share-sheet receivers.
    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
