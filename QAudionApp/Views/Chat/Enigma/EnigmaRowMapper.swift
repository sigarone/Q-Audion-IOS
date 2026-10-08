import Foundation
import QAudionEngine

/// Turns the newest messages of the open chat into the rows the effect needs (engine type `EnigmaRow`): an id, a direction, a
/// kind and the text the bubble shows. Takes only engine types.
///
/// Only a plain text row is a `.text` row, the same rows whose bubble is the final plain-text branch of the chat list. A file
/// descriptor is a `.file` row (outgoing only, the scene shows its name); a voice note, a view-once row received, the
/// undecryptable placeholder and everything with a media type are `.other` and never animate.
enum EnigmaRowMapper {
    /// The effect only ever needs the end of the list (a new message appears there).
    static let tailRows: Int = 40

    static func rows(_ messages: [Message]) -> [EnigmaRow] {
        var out: [EnigmaRow] = []
        out.reserveCapacity(min(messages.count, tailRows))
        for message in messages.suffix(tailRows) {
            out.append(row(for: message))
        }
        return out
    }

    static func row(for message: Message) -> EnigmaRow {
        let outgoing: Bool = message.direction == .outgoing
        let id: String = message.id.uuidString
        if let info = FileV2ChatBody.bubbleInfo(for: message) {
            let kind: EnigmaRow.Kind = outgoing ? .file : .other
            return EnigmaRow(id: id, isOutgoing: outgoing, kind: kind, text: info.displayName)
        }
        let hasMedia: Bool = !(message.mediaMimeType ?? "").isEmpty || (message.mediaDurationMs ?? 0) > 0
        let viewOnceReceived: Bool = message.isViewOnce == true && !outgoing
        let placeholder: Bool = message.isPlaceholder == true
        let plain: Bool = !hasMedia && !viewOnceReceived && !placeholder && !message.plaintext.isEmpty
        return EnigmaRow(id: id, isOutgoing: outgoing, kind: plain ? .text : .other, text: message.plaintext)
    }

    /// Changes whenever the list gains, loses or reorders its last message (cheap: a count and the last id).
    static func changeToken(_ messages: [Message]) -> Int {
        var hasher = Hasher()
        hasher.combine(messages.count)
        hasher.combine(messages.last?.id)
        return hasher.finalize()
    }
}
