import SwiftUI
import QAudionEngine

@MainActor
final class ChatContainer: ObservableObject {

    /// Reason codes 1:1 con Android `SendMessageUseCase.Outcome.Failed`
    /// (vedi `qaudion-android-new/feature/feature-chat/.../SendMessageUseCase.kt`).
    /// Mappato a stringhe Italian per UI feedback via QAudionSnackbar.
    enum SendFailureReason: String, Equatable {
        case pskMissing      = "psk_missing"
        case cryptoFailure   = "crypto_failure"
        case networkError    = "network_error"
        case notAuthenticated = "not_authenticated"
        case uploadFailure   = "upload_failure"
        case generic         = "send_error"

        var localizedDescription: String {
            switch self {
            case .pskMissing:
                return "Errore di cifratura. Contatto non verificato."
            case .cryptoFailure:
                return "Errore crittografico. Riprova."
            case .networkError:
                return "Errore di rete. Controlla la connessione."
            case .notAuthenticated:
                return "Sessione scaduta. Effettua di nuovo l'accesso."
            case .uploadFailure:
                return "Caricamento allegato fallito. Riprova."
            case .generic:
                return "Invio fallito. Riprova più tardi."
            }
        }
    }

    @Published private(set) var viewModel: ChatViewModel
    @Published var composerText: String = ""

    /// Id dell'ultimo messaggio fallito. nil quando nessun fallimento
    /// pending. Wired su QAudionSnackbar dalla `ChatDetailScreen`.
    @Published private(set) var failedMessageId: UUID? = nil
    /// Reason del fallimento corrente. nil se nessun fallimento.
    @Published private(set) var failureReason: SendFailureReason? = nil

    private let store: ConversationStore
    private let conversationId: UUID
    /// W71: real-encryption sender. Late-bound via `attach(appState:)` so
    /// previews / unit tests can construct the container without a full
    /// `AppState`. `sendMessage` falls back to envelope-only logging when
    /// nil (preserves the previous behaviour for callers that haven't
    /// migrated yet).
    private var sendService: ChatMessageSendService?
    private let peerUserId: String

    init(conversationId: UUID,
         peerUserId: String,
         peerDisplayName: String,
         store: ConversationStore = ConversationStore()) {
        self.peerUserId = peerUserId
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

    /// Late-bind the App-state-bound sender. Idempotent — calling with the
    /// same AppState is a no-op; calling with a different one rebuilds.
    /// Views pass this in via `.environmentObject` once mounted.
    func attach(appState: AppState) {
        self.sendService = ChatMessageSendService(appState: appState)
        // W76: listen for chat envelope events (msg_receive, typing,
        // delivery / read receipts) relayed from AppState's WS
        // dispatcher. Refresh the local view-model when something
        // landed for THIS conversation's peer.
        let center = NotificationCenter.default
        let peerId = self.peerUserId
        center.addObserver(forName: AppState.chatRefreshNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self = self else { return }
            // Refresh always — store changes may have arrived via any
            // peer (incoming msg_receive may have created a new
            // conversation row before the user opened the chat).
            if let info = note.userInfo as? [String: Any],
               let from = info["peerUserId"] as? String,
               from != peerId {
                // Message for a different peer; ignore.
                return
            }
            self.refreshFromStore()
        }
        center.addObserver(forName: AppState.chatTypingNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let info = note.userInfo as? [String: Any],
                  let from = info["senderId"] as? String,
                  from == peerId,
                  let isTyping = info["isTyping"] as? Bool else { return }
            // Patch isPeerTyping into the view-model without rebuilding
            // the whole list — keeps the chat scroll stable.
            self.viewModel = ChatViewModel(
                conversation: self.viewModel.conversation,
                messages: self.viewModel.messages,
                composerText: self.composerText,
                isPeerTyping: isTyping,
                isPeerOnline: self.viewModel.isPeerOnline
            )
        }
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
        composerText = ""
        refreshFromStore()

        // W71: real WS send pipeline. The MessageCrypto wire format
        // (salt||nonce||ciphertext||tag with HKDF-SHA256-derived key and
        // AES-256-GCM AAD = "msg:{sender}:{peer}:{msgId}") is parity with
        // qaudion-desktop and qaudion-android-new. Fallback PSK kicks in
        // for unpaired contacts so the wire still flows.
        if let sender = sendService {
            Task { [conversationId, peerUserId, msgId = msg.id] in
                let outcome = await sender.sendEncrypted(
                    messageId: msgId,
                    peerUserId: peerUserId,
                    plaintext: text
                )
                await MainActor.run {
                    switch outcome {
                    case .delivered, .sent:
                        self.store.updateMessageStatus(
                            id: msgId, conversationId: conversationId,
                            newStatus: .delivered, deliveredAt: Date()
                        )
                    case .failed(let reason):
                        self.markFailed(messageId: msgId, reason: reason)
                    }
                    self.refreshFromStore()
                }
            }
        } else {
            // Pre-attach fallback — preserve previous "envelope log + simulated
            // delivery" behaviour so previews and tests still mark messages
            // delivered. Production code paths always run after `attach`.
            if let envelopeJson = try? MessageSendEnvelope(
                messageId: msg.id,
                recipientId: viewModel.conversation.peerUserId,
                ciphertext: Data(text.utf8),
                clientTs: Int64(Date().timeIntervalSince1970 * 1000)
            ).encodeAsJsonString() {
                print("[Chat] would send envelope (no sendService attached): \(envelopeJson.prefix(120))...")
            }
            Task { [conversationId, msgId = msg.id] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    self.store.updateMessageStatus(
                        id: msgId, conversationId: conversationId,
                        newStatus: .delivered, deliveredAt: Date()
                    )
                    self.refreshFromStore()
                }
            }
        }
    }

    /// Marca un messaggio come fallito e pubblica i flag che la
    /// `ChatDetailScreen` legge per mostrare la snackbar di retry.
    /// Chiamabile dall'engine wiring quando la send pipeline lancia
    /// (network down, PSK missing, crypto failure). Per ora il chiamante
    /// è una test fixture in `simulateFailure(messageId:reason:)` finché
    /// la real send pipeline non è wired.
    func markFailed(messageId: UUID, reason: SendFailureReason) {
        store.updateMessageStatus(
            id: messageId, conversationId: conversationId,
            newStatus: .failed
        )
        failedMessageId = messageId
        failureReason = reason
        refreshFromStore()
    }

    /// Resetta i flag di failure e ri-tenta la send pipeline. Il composer
    /// viene ripopolato col plaintext del messaggio fallito così l'utente
    /// può modificarlo prima del retry o premere direttamente "Invia".
    func retryFailedMessage() {
        guard let id = failedMessageId,
              let msg = store.loadMessages(conversationId: conversationId)
                  .first(where: { $0.id == id })
        else { return }
        composerText = msg.plaintext
        failedMessageId = nil
        failureReason = nil
        // Marca il vecchio messaggio come "sending" così la UI mostra
        // di nuovo l'icona clock invece dell'errore.
        store.updateMessageStatus(
            id: id, conversationId: conversationId, newStatus: .sending
        )
        refreshFromStore()
        // sendMessage è il punto canonico — quando l'engine wires
        // crypto/WS, retry passerà per gli stessi catch handler.
        sendMessage()
    }

    /// Test/dev hook per simulare un fallimento di invio. Da rimuovere
    /// quando la real send pipeline (engine) chiama `markFailed`
    /// direttamente in caso di errore. Esposto come `internal` per
    /// poter essere testato dall'App layer.
    #if DEBUG
    func simulateFailure(reason: SendFailureReason = .networkError) {
        guard let last = viewModel.messages.last else { return }
        markFailed(messageId: last.id, reason: reason)
    }
    #endif

    /// Chiama questo dopo aver mostrato il feedback all'utente per
    /// eliminare la snackbar pending.
    func clearFailureFlag() {
        failedMessageId = nil
        failureReason = nil
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
