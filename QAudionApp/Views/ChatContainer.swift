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
    /// W79: cached AppState ref so `sendVoiceNote` can build the
    /// `ChatVoiceNoteSender` (which needs auth token + currentUserId
    /// + serverUrl). Kept weak via guard at call site to avoid a
    /// retain cycle through the container hierarchy.
    private weak var appState: AppState?
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
        self.appState = appState
        // W76: listen for chat envelope events (msg_receive, typing,
        // delivery / read receipts) relayed from AppState's WS
        // dispatcher. Refresh the local view-model when something
        // landed for THIS conversation's peer.
        let center = NotificationCenter.default
        let peerId = self.peerUserId
        // The NotificationCenter closure is `@Sendable` per the iOS 18
        // signature — mutating @MainActor state must hop into a
        // `Task { @MainActor in ... }`. Same fix as W74c on AppState's
        // willEnterForeground observer.
        center.addObserver(forName: AppState.chatRefreshNotification,
                           object: nil, queue: .main) { note in
            // Capture only Sendable values out of the note so we don't
            // close over the non-Sendable `Notification` itself.
            let peerMatch: Bool = {
                guard let info = note.userInfo as? [String: Any],
                      let from = info["peerUserId"] as? String else {
                    // Notes without peerUserId (delivery/read receipts)
                    // always refresh — store-level updates may apply
                    // to any conversation.
                    return true
                }
                return from == peerId
            }()
            guard peerMatch else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // W83: while the user is looking at this conversation,
                // any inbound message bumped unreadCount on the row.
                // Auto-clear so the badge stays at zero until the user
                // navigates away.
                self.store.markConversationRead(id: self.conversationId)
                self.refreshFromStore()
            }
        }
        center.addObserver(forName: AppState.chatTypingNotification,
                           object: nil, queue: .main) { note in
            guard let info = note.userInfo as? [String: Any],
                  let from = info["senderId"] as? String,
                  from == peerId,
                  let isTyping = info["is_typing"] as? Bool ??
                                  (info["isTyping"] as? Bool) else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
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
        // W83: bump conversation preview + activity for outbound text.
        // Outbound never increments unread (sender already read what
        // they typed). Truncated preview is computed inside the store.
        store.recordNewMessage(
            conversationId: conversationId,
            lastMessagePreview: text,
            lastActivity: Date(),
            incrementUnread: false
        )
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
                    case .delivered(let serverMessageId):
                        // W78: bind the server id to the local row so
                        // subsequent msg_delivered/msg_read receipts can
                        // be reconciled.
                        self.store.setServerMessageId(
                            localId: msgId,
                            conversationId: conversationId,
                            serverMessageId: serverMessageId
                        )
                        self.store.updateMessageStatus(
                            id: msgId, conversationId: conversationId,
                            newStatus: .delivered, deliveredAt: Date()
                        )
                    case .sent:
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

    /// W83: zero `unreadCount` for this conversation. Called by
    /// `ChatDetailScreen.onAppear` so opening a chat clears its badge.
    /// Idempotent — no-op if already zero.
    func markRead() {
        store.markConversationRead(id: conversationId)
        refreshFromStore()
    }

    /// W84: emit a `msg_read` receipt to the peer for all inbound
    /// messages with a server id. Server relays so the peer's UI flips
    /// ✓✓ to ✓✓ blue. Best-effort fire-and-forget; failures don't
    /// surface (logs only).
    ///
    /// Called from `ChatDetailScreen.onAppear` — once per chat open,
    /// not on every refresh, to keep the WS chatter bounded. The chat-
    /// refresh notification handler intentionally does NOT call this
    /// method; it just zeros the local badge via `markConversationRead`.
    func emitReadReceipts() {
        guard let provider = self.appState?.liveProvider else { return }
        let peerId = peerUserId
        let inboundServerIds = store.loadMessages(conversationId: conversationId)
            .filter { $0.direction == .incoming }
            .compactMap { $0.serverMessageId }
        guard !inboundServerIds.isEmpty else { return }
        Task { [peerId, inboundServerIds] in
            do {
                try await provider.messageApi.sendReadReceipts(
                    senderId: peerId,
                    messageIds: inboundServerIds
                )
            } catch {
                print("[ChatContainer] sendReadReceipts failed: \(error)")
            }
        }
    }

    /// W79: ship a recorded voice note over the existing 1:1 chat path.
    /// Pipeline: encrypt+upload via `ChatVoiceNoteSender` → use the
    /// resulting `qfile` v3 marker JSON as the plaintext of a normal
    /// `msg_send`. The local conversation row carries a friendly
    /// placeholder ("🎤 Nota vocale (4.2s)") so the user sees a
    /// recognizable bubble instead of the marker JSON.
    /// Receiver-side handling: `AppState.handleIncomingMessage`
    /// detects the qfile marker; today (v1.0.143) it shows the same
    /// placeholder text (download/playback wiring lands in v1.0.144).
    func sendVoiceNote(_ recording: VoiceNoteRecorder.Recording) {
        let peerId = peerUserId
        let convId = conversationId
        let durSec = Double(recording.durationMs) / 1000.0
        let displayText = String(format: "🎤 Nota vocale (%.1fs)", durSec)
        let msgId = UUID()

        // W81: copy the captured M4A from /tmp into the persistent
        // voice-notes cache so the sender can replay their own bubble
        // after the app restarts. /tmp is reclaimed by iOS on next
        // launch; Library/Caches survives suspension.
        let localCachePath: String? = Self.persistOutboundVoiceNote(
            from: recording.fileURL, msgId: msgId
        )

        // Local row first so the chat reflects the action immediately.
        // mediaDurationMs makes the row render via VoiceNoteBubbleContent
        // (W81); mediaLocalPath populates the play button immediately.
        let local = Message(
            id: msgId,
            conversationId: convId,
            direction: .outgoing,
            plaintext: displayText,
            sentAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            status: .sending,
            mediaLocalPath: localCachePath,
            mediaDurationMs: Int64(recording.durationMs),
            mediaMimeType: recording.mimeType
        )
        store.appendMessage(local)
        store.recordNewMessage(
            conversationId: convId,
            lastMessagePreview: displayText,
            lastActivity: Date(),
            incrementUnread: false
        )
        refreshFromStore()

        // Async upload + send. Failures flip the row to .failed via
        // `markFailed` so the existing snackbar surfaces a Retry CTA.
        guard let sendService = self.sendService,
              let appState = self.appState else {
            // No backend wired (preview / unit test) — fall back to a
            // simulated delivery so the UI still flows.
            Task { @MainActor [weak self, msgId, convId] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.store.updateMessageStatus(
                    id: msgId, conversationId: convId,
                    newStatus: .delivered, deliveredAt: Date()
                )
                self?.refreshFromStore()
            }
            return
        }

        Task { [weak self, peerId, convId, msgId] in
            let prep = ChatVoiceNoteSender(appState: appState)
            let markerJson: String
            do {
                markerJson = try await prep.prepareMarkerJson(
                    for: recording,
                    recipientUserId: peerId
                )
            } catch let e as ChatVoiceNoteSender.Error {
                print("[ChatContainer] voice note prep failed: \(e.localizedDescription)")
                await MainActor.run {
                    self?.markFailed(messageId: msgId, reason: .uploadFailure)
                }
                return
            } catch {
                print("[ChatContainer] voice note prep failed: \(error)")
                await MainActor.run {
                    self?.markFailed(messageId: msgId, reason: .generic)
                }
                return
            }
            // Marker prepared — encrypt-and-ship via the same WS send
            // pipeline as a regular text message. The wire `plaintext`
            // is the marker JSON; the local store keeps the friendly
            // display text untouched.
            let outcome = await sendService.sendEncrypted(
                messageId: msgId,
                peerUserId: peerId,
                plaintext: markerJson
            )
            await MainActor.run {
                guard let self = self else { return }
                switch outcome {
                case .delivered(let serverMsgId):
                    self.store.setServerMessageId(
                        localId: msgId,
                        conversationId: convId,
                        serverMessageId: serverMsgId
                    )
                    self.store.updateMessageStatus(
                        id: msgId, conversationId: convId,
                        newStatus: .delivered, deliveredAt: Date()
                    )
                case .sent:
                    self.store.updateMessageStatus(
                        id: msgId, conversationId: convId,
                        newStatus: .delivered, deliveredAt: Date()
                    )
                case .failed(let reason):
                    self.markFailed(messageId: msgId, reason: reason)
                }
                self.refreshFromStore()
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

    /// W82: ship an image attachment via the same qfile v3 pipeline as
    /// voice notes. Performs three normalizations before encryption:
    ///   1. Re-encode through `UIImage` → `jpegData(compressionQuality:)`
    ///      to strip EXIF (geolocation, device serial, timestamps, etc.).
    ///      Apple's CGImage I/O preserves EXIF by default; bouncing
    ///      through UIImage is the simplest portable strip.
    ///   2. Downscale long-side to ≤ 2048px so a 12 MP capture doesn't
    ///      blow the recipient's cache budget. Aspect-preserved.
    ///   3. Cap the encoded JPEG at 10 MB hard ceiling — anything larger
    ///      is rejected (the user gets a snackbar via the failure flag).
    func sendImage(_ rawImageData: Data) {
        let peerId = peerUserId
        let convId = conversationId
        let msgId = UUID()

        // Normalize: load → downscale → re-encode JPEG (no EXIF).
        guard let normalized = Self.normalizeImageForChat(rawImageData) else {
            print("[ChatContainer] sendImage normalization failed")
            return
        }
        let jpeg = normalized.data
        guard jpeg.count <= 10 * 1024 * 1024 else {
            print("[ChatContainer] sendImage rejected: \(jpeg.count) bytes > 10MB cap")
            return
        }

        // Persist the local copy first so the sender bubble shows the
        // image immediately while the upload is in flight.
        let localCachePath = Self.persistOutboundImage(jpeg: jpeg, msgId: msgId)

        let local = Message(
            id: msgId,
            conversationId: convId,
            direction: .outgoing,
            plaintext: "📷 Foto",
            sentAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            status: .sending,
            mediaLocalPath: localCachePath,
            mediaDurationMs: nil,
            mediaMimeType: "image/jpeg"
        )
        store.appendMessage(local)
        store.recordNewMessage(
            conversationId: convId,
            lastMessagePreview: "📷 Foto",
            lastActivity: Date(),
            incrementUnread: false
        )
        refreshFromStore()

        guard let sendService = self.sendService,
              let appState = self.appState else {
            // Preview / unit-test fallback — simulate delivery.
            Task { @MainActor [weak self, msgId, convId] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.store.updateMessageStatus(
                    id: msgId, conversationId: convId,
                    newStatus: .delivered, deliveredAt: Date()
                )
                self?.refreshFromStore()
            }
            return
        }

        Task { [weak self, peerId, convId, msgId, jpeg] in
            let prep = ChatVoiceNoteSender(appState: appState)
            let markerJson: String
            do {
                markerJson = try await prep.prepareAttachmentMarkerJson(
                    bytes: jpeg,
                    mime: "image/jpeg",
                    filename: "image-\(msgId.uuidString).jpg",
                    durationMs: nil,
                    recipientUserId: peerId
                )
            } catch {
                print("[ChatContainer] sendImage prep failed: \(error)")
                await MainActor.run { self?.markFailed(messageId: msgId, reason: .uploadFailure) }
                return
            }
            let outcome = await sendService.sendEncrypted(
                messageId: msgId, peerUserId: peerId, plaintext: markerJson
            )
            await MainActor.run {
                guard let self = self else { return }
                switch outcome {
                case .delivered(let serverMsgId):
                    self.store.setServerMessageId(
                        localId: msgId, conversationId: convId,
                        serverMessageId: serverMsgId
                    )
                    self.store.updateMessageStatus(
                        id: msgId, conversationId: convId,
                        newStatus: .delivered, deliveredAt: Date()
                    )
                case .sent:
                    self.store.updateMessageStatus(
                        id: msgId, conversationId: convId,
                        newStatus: .delivered, deliveredAt: Date()
                    )
                case .failed(let reason):
                    self.markFailed(messageId: msgId, reason: reason)
                }
                self.refreshFromStore()
            }
        }
    }

    /// W82 — image normalization: strip EXIF + downscale to ≤2048px.
    /// Returns the JPEG data + the size used. Returns nil if the
    /// original bytes don't decode as a UIImage (corrupted / unsupported).
    private static func normalizeImageForChat(_ rawData: Data) -> (data: Data, size: CGSize)? {
        guard let img = UIImage(data: rawData) else { return nil }
        let maxLong: CGFloat = 2048
        let original = img.size
        let longest = max(original.width, original.height)
        let scale: CGFloat = (longest > maxLong) ? (maxLong / longest) : 1.0
        let target = CGSize(width: floor(original.width * scale),
                            height: floor(original.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target,
                                               format: { let f = UIGraphicsImageRendererFormat();
                                                         f.scale = 1.0; f.opaque = true;
                                                         return f }())
        let normalized = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        // jpegData(compressionQuality:) re-encodes from the rendered
        // bitmap — drops all EXIF / IPTC / XMP from the source.
        guard let jpeg = normalized.jpegData(compressionQuality: 0.85) else {
            return nil
        }
        return (jpeg, target)
    }

    /// W82: persist a JPEG to Library/Caches/images/<msgId>.jpg so the
    /// sender's bubble can render the local copy without re-fetching.
    private static func persistOutboundImage(jpeg: Data, msgId: UUID) -> String? {
        do {
            let base = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let dir = base.appendingPathComponent("images", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let dst = dir.appendingPathComponent("\(msgId.uuidString).jpg")
            try? FileManager.default.removeItem(at: dst)
            try jpeg.write(to: dst, options: [.atomic])
            return dst.path
        } catch {
            print("[ChatContainer] persistOutboundImage failed: \(error)")
            return nil
        }
    }

    /// W81: copy a freshly-captured /tmp M4A into the durable voice-note
    /// cache (Library/Caches/voicenotes/<msgId>.m4a) so the sender can
    /// replay their own bubble after the app restarts. Returns the
    /// destination path on success, or `nil` on copy failure (the
    /// bubble will then show the placeholder + spinner; the file's
    /// already been uploaded ciphertext-side so the receiver still
    /// works).
    private static func persistOutboundVoiceNote(from src: URL, msgId: UUID) -> String? {
        do {
            let base = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let dir = base.appendingPathComponent("voicenotes", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let dst = dir.appendingPathComponent("\(msgId.uuidString).m4a")
            // If the file already exists (rare race), remove first.
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            return dst.path
        } catch {
            print("[ChatContainer] persistOutboundVoiceNote failed: \(error)")
            return nil
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
