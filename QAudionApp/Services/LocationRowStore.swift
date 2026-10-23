import Foundation
import QAudionEngine

/// What `LocationShareCenter` needs from the message table and the outbox, and nothing else. The center holds the rules of location
/// sharing; this seam is where they touch the rows of the chat, so that the app tests can run the whole feature against a fake
/// (no database, no at-rest cipher, no keychain) and the production code against the real stores (`ConversationLocationRows`).
///
/// Nothing here logs, prints or describes a body, a position or a key.

/// One message row as the center needs to see it.
struct LocationRowInfo: Equatable {
    let rowId: UUID
    let conversationId: UUID
    /// The user id of the other account of the conversation, `nil` when the conversation cannot be found.
    let peerUserId: String?
    let outgoing: Bool
    /// The text of the row: for the row of an own live start, the full start body (with the key) until the echo, then the local form.
    let plaintext: String
    let mediaMimeType: String?
    /// The row was deleted for everyone (a tombstone).
    let deleted: Bool
    let hasExpiry: Bool
    /// The timer of the conversation in seconds (`nil` or 0: none, -1: view-once).
    let timerSeconds: Int?
}

@MainActor
protocol LocationRowStore: AnyObject {
    /// The row with this client message id, or `nil`.
    func row(forClientMsgId id: String) -> LocationRowInfo?
    /// Whether an outgoing row has this client message id (the cheap question: no conversation lookup).
    func hasOutgoingRow(clientMsgId id: String) -> Bool
    func setExpiresAt(rowId: UUID, to date: Date)
    func replaceContent(rowId: UUID, plaintext: String, mediaMimeType: String?)
    /// Removes the row (it may hold the key of a start that never left).
    func removeRow(rowId: UUID, conversationId: UUID)
    /// Puts the row back to "sending" and asks the outbox to send it again under the same client message id.
    func requeue(rowId: UUID, conversationId: UUID)
    /// Removes the retry entry of the outbox for this client message id.
    func removeOutboxEntry(clientMsgId id: String)
}

/// The real rows: the conversation store and the chat outbox.
@MainActor
final class ConversationLocationRows: LocationRowStore {

    func row(forClientMsgId id: String) -> LocationRowInfo? {
        let store = ConversationStore()
        guard let found = store.findByClientMsgId(id) else { return nil }
        let conversation = store.loadConversations().first(where: { $0.id == found.conversationId })
        return LocationRowInfo(
            rowId: found.message.id, conversationId: found.conversationId, peerUserId: conversation?.peerUserId,
            outgoing: found.message.direction == .outgoing, plaintext: found.message.plaintext,
            mediaMimeType: found.message.mediaMimeType, deleted: found.message.deletedAt != nil,
            hasExpiry: found.message.expiresAt != nil, timerSeconds: conversation?.ephemeralTimerSeconds)
    }

    func hasOutgoingRow(clientMsgId id: String) -> Bool {
        ConversationStore().findByClientMsgId(id)?.message.direction == .outgoing
    }

    func setExpiresAt(rowId: UUID, to date: Date) {
        ConversationStore().setExpiresAt(messageId: rowId, expiresAt: date)
    }

    func replaceContent(rowId: UUID, plaintext: String, mediaMimeType: String?) {
        ConversationStore().replaceContent(id: rowId, plaintext: plaintext, mediaMimeType: mediaMimeType)
    }

    func removeRow(rowId: UUID, conversationId: UUID) {
        ConversationStore().removeMessage(id: rowId, conversationId: conversationId)
    }

    func requeue(rowId: UUID, conversationId: UUID) {
        ConversationStore().updateMessageStatus(id: rowId, conversationId: conversationId, newStatus: .sending)
        ChatOutboxDrain.shared.kick(reason: "location-start-requeue")
    }

    func removeOutboxEntry(clientMsgId id: String) {
        ChatOutboxStore().remove(id: id)
    }
}
