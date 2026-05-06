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
                       myDisplayLabel: String = "Tu") -> URL? {
        let header = buildHeader(peerDisplayName: peerDisplayName,
                                 messageCount: messages.count)
        let body = messages
            .sorted { $0.sentAt < $1.sentAt }
            .map { format(message: $0,
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
        return """
        Q-Audion — Chat con \(peerDisplayName)
        Esportata il \(exportedAt)
        \(messageCount) \(messageCount == 1 ? "messaggio" : "messaggi")
        """
    }

    private static func format(message m: Message,
                               peerDisplayName: String,
                               myDisplayLabel: String) -> String {
        let stamp = humanFormatter.string(from: m.sentAt)
        let author = (m.direction == .outgoing) ? myDisplayLabel : peerDisplayName
        let body: String
        if m.deletedAt != nil {
            body = "<messaggio eliminato>"
        } else if let mime = m.mediaMimeType, !mime.isEmpty {
            // Attachment placeholder — voice notes (audio/mp4) /
            // images (image/jpeg) etc. The actual binary stays in the
            // cache — exporting it inline would balloon the file.
            let dur = m.mediaDurationMs.map { "\($0)ms" } ?? ""
            body = "<allegato: \(mime)\(dur.isEmpty ? "" : " · \(dur)")>"
        } else {
            // Strip newlines from the message body so each entry stays
            // on a single line — easier to scan, paste, search.
            body = m.plaintext
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        let editedSuffix = (m.edited == true) ? " (modificato)" : ""
        return "[\(stamp)] \(author): \(body)\(editedSuffix)"
    }

    /// 01/05/2026, 14:32 — Italian short date+time.
    private static let humanFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
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
