import SwiftUI
import QAudionEngine

@MainActor
final class ChatContainer: ObservableObject {

    @Published private(set) var viewModel: ChatViewModel
    @Published var composerText: String = ""

    private let store: ConversationStore
    private let conversationId: UUID

    init(conversationId: UUID,
         peerUserId: String,
         peerDisplayName: String,
         store: ConversationStore = ConversationStore()) {
        self.store = store
        self.conversationId = conversationId

        // Bootstrap the conversation if missing.
        let existing = store.loadConversations().first(where: { $0.id == conversationId })
        let conv: Conversation
        if let e = existing {
            conv = e
        } else {
            conv = Conversation(
                id: conversationId,
                peerUserId: peerUserId,
                peerDisplayName: peerDisplayName,
                lastMessagePreview: nil,
                lastActivity: Date(),
                unreadCount: 0,
                pinned: false
            )
            store.upsertConversation(conv)
        }

        let messages = store.loadMessages(conversationId: conversationId)
        self.viewModel = ChatViewModel(
            conversation: conv,
            messages: messages,
            composerText: "",
            isPeerTyping: false,
            isPeerOnline: false
        )
    }

    func sendMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let msg = Message(
            id: UUID(),
            conversationId: conversationId,
            direction: .outgoing,
            plaintext: text,
            sentAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            status: .sending
        )
        store.appendMessage(msg)

        // Encode envelope (proves wire shape works) — actual send via WS is TODO.
        // For now, log the wire form so the user can see chat works.
        if let envelopeJson = try? MessageSendEnvelope(
            messageId: msg.id,
            recipientId: viewModel.conversation.peerUserId,
            ciphertext: Data(text.utf8),  // TODO: real encryption via session ratchet
            clientTs: Int64(Date().timeIntervalSince1970 * 1000)
        ).encodeAsJsonString() {
            print("[Chat] would send envelope: \(envelopeJson.prefix(120))...")
        }

        composerText = ""

        // Reload from store to refresh the list.
        refreshFromStore()

        // Simulate delivery after 0.5s for now (real WS round-trip later).
        Task { [conversationId] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                self.store.updateMessageStatus(
                    id: msg.id, conversationId: conversationId,
                    newStatus: .delivered, deliveredAt: Date()
                )
                self.refreshFromStore()
            }
        }
    }

    func refreshFromStore() {
        let messages = store.loadMessages(conversationId: conversationId)
        let conv = store.loadConversations().first { $0.id == conversationId } ?? viewModel.conversation
        viewModel = ChatViewModel(
            conversation: conv,
            messages: messages,
            composerText: composerText,
            isPeerTyping: viewModel.isPeerTyping,
            isPeerOnline: viewModel.isPeerOnline
        )
    }
}
