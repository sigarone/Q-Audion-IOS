import SwiftUI
import QAudionEngine

/// W-BGUP: trivial weak-reference box.
///
/// A plain `ChatContainer?` function parameter is a **strong** reference
/// for the entire lifetime of the call — including every `await` suspension
/// inside it — even if the caller resolved it from `[weak self]` right
/// before passing it in. `[weak weakContainer]` on a closure that merely
/// *captures* an already-strong local does nothing to fix this: the local
/// itself is what's keeping the object alive.
///
/// `Weak<T>` sidesteps that: the box itself is passed (and captured) by
/// reference with no effect on `T`'s refcount, and each read of `.value`
/// re-resolves the weak reference at that exact point. Passing the box
/// down through `sendXAsync` → `completeXSend` → the `onProgress`/`catch`/
/// terminal-`MainActor.run` sites means `ChatContainer` can deallocate at
/// any point — including mid-upload — exactly like the original
/// `Task { [weak self] in ... self?.foo() ... }` pattern on `main`.
private final class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}

@MainActor
final class ChatContainer: ObservableObject {

    /// Reason codes 1:1 con Android `SendMessageUseCase.Outcome.Failed`
    /// (vedi `qaudion-android-new/feature/feature-chat/.../SendMessageUseCase.kt`).
    /// Mappato a stringhe Italian per UI feedback via QAudionSnackbar.
    /// `Error`-conforming (branch claude/ble-mesh-cleanroom-spike added
    /// this): `ChatMessageSendService.encryptForWire` returns
    /// `Result<Data, SendFailureReason>`, and `Result`'s `Failure`
    /// generic parameter requires `Failure: Error` — a plain
    /// `Equatable`-only enum does not satisfy that on its own.
    enum SendFailureReason: String, Equatable, Error {
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

    @Published private(set) var failedMessageId: UUID? = nil
    @Published private(set) var failureReason: SendFailureReason? = nil
    /// When true, the NEXT message sent will be flagged as view-once.
    /// Mirrors conversation.screenshotGrantedByPeer for reactive UI.
    @Published private(set) var screenshotGrantedByPeer: Bool? = nil
    /// W446: local-only attachment upload progress, keyed by the
    /// outgoing message's local id. `0.0...1.0`, updated as TUS chunks
    /// complete. Purely in-memory UI state — never persisted to
    /// `ConversationStore`/`Message.Status` and never touches the wire.
    /// Entries are removed once the send reaches a terminal state
    /// (`sent`/`delivered`/`failed`), at which point `messageRow` falls
    /// back to the normal `mapDelivery(msg.status)` path.
    @Published private(set) var uploadProgress: [UUID: Double] = [:]

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
        // W137: restore any per-conversation composer draft saved from
        // a prior session. Empty when the user sent / explicitly cleared
        // last time. Read BEFORE building the view-model so the very
        // first render shows the draft instead of an empty field.
        let restoredDraft = ComposerDraftStore.load(for: conversationId)
        self.composerText = restoredDraft
        self.viewModel = ChatViewModel(
            conversation: conv,
            messages: messages,
            composerText: restoredDraft,
            isPeerTyping: false,
            isPeerOnline: false
        )
    }

    /// W137: debounced draft save. The composer fires this on every
    /// keystroke; we coalesce to a single UserDefaults write 0.5s after
    /// the last keystroke so heavy typing doesn't thrash the disk.
    private var draftSaveWorkItem: DispatchWorkItem?

    /// Called by the composer binding setter on every text change.
    /// Captures the current `composerText` snapshot inside the work
    /// item so the eventual write reflects the latest typed value.
    func scheduleDraftSave() {
        draftSaveWorkItem?.cancel()
        let convId = self.conversationId
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            ComposerDraftStore.save(self.composerText, for: convId)
        }
        draftSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// W137: synchronous draft flush — call when the screen is going
    /// away or the app is backgrounding so the partial text isn't lost
    /// before the debounce timer fires.
    func flushDraftNow() {
        draftSaveWorkItem?.cancel()
        ComposerDraftStore.save(composerText, for: conversationId)
    }

    /// Late-bind the App-state-bound sender. Idempotent — calling with the
    /// same AppState is a no-op; calling with a different one rebuilds.
    /// Views pass this in via `.environmentObject` once mounted.
    func attach(_ state: AppState) {
        self.sendService = ChatMessageSendService(appState: state)
        self.appState = state
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
        // W137: flush any pending draft when the app is about to lose
        // active state. onDisappear on ChatDetailScreen covers the
        // navigation-away case; this covers the user dragging the app
        // off-screen WHILE the detail view is still on top.
        center.addObserver(forName: UIApplication.willResignActiveNotification,
                           object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                self?.flushDraftNow()
            }
        }
    }

    func sendMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // W114: soft haptic tap so the user feels the send fire.
        HapticFeedback.messageSent()
        let outboundId = UUID()
        // W441: derive expiresAt from the conversation's ephemeral timer.
        // nil = no expiry (disabled or timer is 0).
        let sentNow = Date()
        let ephSecs = viewModel.conversation.ephemeralTimerSeconds
        let ephExpiry: Date? = ephSecs.flatMap { s in
            s > 0 ? sentNow.addingTimeInterval(Double(s)) : nil
        }
        // View-once is a per-conversation timer value of -1 (Android parity).
        // When the conversation timer is -1, every outgoing message is view-once.
        let convTimerSec = viewModel.conversation.ephemeralTimerSeconds ?? 0
        let isViewOnce = convTimerSec == -1
        let msg = Message(
            id: outboundId,
            conversationId: conversationId,
            direction: .outgoing,
            plaintext: text,
            sentAt: sentNow,
            deliveredAt: nil,
            readAt: nil,
            status: .sending,
            clientMsgId: outboundId.uuidString,
            expiresAt: ephExpiry,
            isViewOnce: isViewOnce ? true : nil
        )
        let wireText = text
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
        // W137: a successful send clears the persisted draft so the
        // next entry into this conversation starts fresh.
        ComposerDraftStore.clear(for: conversationId)
        draftSaveWorkItem?.cancel()
        refreshFromStore()

        // BLE-mesh offline chat fallback (branch claude/ble-mesh-cleanroom-spike):
        // when this conversation has an active mesh send target selected
        // (set from `MeshSheetView`'s "Invia messaggio via mesh" button),
        // route THIS message over the mesh transport instead of the normal
        // WS pipeline below. Mirrors the Android sibling's
        // `SendMessageUseCase` mesh pre-flight branch.
        if let sender = sendService,
           let target = MeshRuntime.shared.activeTarget(for: conversationId.uuidString) {
            sendViaMesh(
                sender: sender, target: target,
                messageId: msg.id, wireText: wireText
            )
            return
        }

        // W71: real WS send pipeline. The MessageCrypto wire format
        // (salt||nonce||ciphertext||tag with HKDF-SHA256-derived key and
        // AES-256-GCM AAD = "msg:{sender}:{peer}:{msgId}") is parity with
        // qaudion-desktop and qaudion-android-new. Fallback PSK kicks in
        // for unpaired contacts so the wire still flows.
        if let sender = sendService {
            Task { [conversationId, peerUserId, msgId = msg.id, wireText] in
                let outcome = await sender.sendEncrypted(
                    messageId: msgId,
                    peerUserId: peerUserId,
                    plaintext: wireText
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
                recipientId: viewModel.conversation.peerUserId,
                encryptedPayload: Data(text.utf8),
                clientMsgId: msg.id.uuidString
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

    /// BLE-mesh send path (branch claude/ble-mesh-cleanroom-spike). Reuses
    /// `ChatMessageSendService.encryptForWire` — the SAME crypto dispatch
    /// the normal WS path uses — then wraps the opaque ciphertext in a
    /// `MeshChatMessage` envelope and hands it to `MeshRuntime`. Mirrors
    /// the Android sibling's `MeshSendCoordinator.sendMeshMessage` shape.
    /// Body kept shallow (single `Task`, helper methods do the real work)
    /// per CLAUDE.md §13 — a deeper inline closure here has repeatedly
    /// timed out the Swift 6 type-checker elsewhere in this app.
    private func sendViaMesh(
        sender: ChatMessageSendService,
        target: MeshTargetSelection,
        messageId: UUID,
        wireText: String
    ) {
        Task { [weak self, conversationId, peerUserId, target, messageId, wireText] in
            guard let self else { return }
            guard let selfId = await self.appState?.currentUserId else {
                await MainActor.run { self.markFailed(messageId: messageId, reason: .notAuthenticated) }
                return
            }
            // v2 seals the ENVELOPE, so what goes into the cipher is the
            // serialised envelope rather than the bare body. Everything that
            // identifies the parties travels inside it; see MeshChatMessage.
            let envelope = MeshChatMessage(
                senderUserId: selfId,
                recipientUserId: peerUserId,
                clientMsgId: messageId.uuidString,
                conversationId: conversationId.uuidString,
                body: wireText,
                sentAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                senderNodeHex: await MeshRuntime.shared.localNodeIdHex,
                recipientNodeHex: target.nodeHex
            )
            let envelopeText = String(data: envelope.encode(), encoding: .utf8) ?? ""
            let outcome = await sender.encryptForWire(
                messageId: messageId, peerUserId: peerUserId, plaintext: envelopeText
            )
            await MainActor.run {
                self.completeMeshSend(
                    outcome: outcome, conversationId: conversationId,
                    peerUserId: peerUserId, target: target, messageId: messageId
                )
            }
        }
    }

    /// MainActor tail of `sendViaMesh` — separated so the `Task` body above
    /// stays a single, trivial call (CLAUDE.md §13/§14: the deeper the
    /// inline closure, the more likely a type-checker timeout).
    private func completeMeshSend(
        outcome: Result<Data, ChatContainer.SendFailureReason>,
        conversationId: UUID,
        peerUserId: String,
        target: MeshTargetSelection,
        messageId: UUID
    ) {
        guard let selfUserId = appState?.currentUserId else {
            markFailed(messageId: messageId, reason: .notAuthenticated)
            return
        }
        switch outcome {
        case .failure(let reason):
            markFailed(messageId: messageId, reason: reason)
        case .success(let sealed):
            // Wire v2: `sealed` is the encrypted ENVELOPE, not an encrypted
            // body — sendViaMesh hands the whole serialised envelope to
            // encryptForWire as its plaintext. Only the message id rides
            // outside, in the shell, because the ratchet needs it to rebuild
            // its own associated data before it can decrypt anything.
            let shell = MeshSealedShell(
                clientMsgId: messageId.uuidString,
                sealedB64: sealed.base64EncodedString()
            )
            MeshRuntime.shared.sendData(toNodeHex: target.nodeHex, payload: shell.encode()) { [weak self] delivered in
                self?.finishMeshSend(delivered: delivered, conversationId: conversationId, messageId: messageId)
            }
        }
    }

    private func finishMeshSend(delivered: Bool, conversationId: UUID, messageId: UUID) {
        if delivered {
            // R4 — mark the row as having gone over the mesh, so the sender's
            // own transcript distinguishes it from a normal network message.
            // The flag, its column and its rendering all existed; nothing on
            // the SEND side ever set it, so the glyph only ever appeared on
            // received messages — while MessageBubble's accessibility label
            // already read "Inviato via mesh Bluetooth", describing a case that
            // could not occur.
            store.updateMessageStatus(
                id: messageId, conversationId: conversationId,
                newStatus: .delivered, deliveredAt: Date(),
                viaMesh: true
            )
        } else {
            markFailed(messageId: messageId, reason: .networkError)
        }
        refreshFromStore()
    }

    /// W101: emit typing-start envelope when the user starts typing,
    /// debounced typing-stop after 3 seconds of inactivity. Idempotent
    /// — repeated calls while already typing just refresh the stop
    /// timer. Server relays via msg_typing → peer's chatTypingNotification
    /// → ChatContainer.observer flips isPeerTyping.
    private var typingActive = false
    private var typingStopWorkItem: DispatchWorkItem?

    func notifyComposerInput() {
        // W404: real gating on the typing indicator privacy flag. When
        // the user has disabled "Indicatore di scrittura" in Privacy /
        // Chat settings, we keep the local typingActive bookkeeping
        // (so a future enable doesn't immediately fire a stale envelope)
        // but skip the actual sendTypingIndicator call.
        let typingEnabled = PrivacyGate.typingIndicatorEnabled
        guard let provider = self.appState?.liveProvider else { return }
        let peerId = peerUserId
        // Send typing=true once per "session of typing".
        if !typingActive {
            typingActive = true
            if typingEnabled {
                Task {
                    try? await provider.messageApi.sendTypingIndicator(
                        recipientId: peerId, isTyping: true
                    )
                }
            }
        }
        // Reset the auto-stop timer.
        typingStopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.typingActive = false
            if typingEnabled {
                Task {
                    try? await provider.messageApi.sendTypingIndicator(
                        recipientId: peerId, isTyping: false
                    )
                }
            }
        }
        typingStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// W101: explicitly emit typing=false (called when the user sends
    /// the message — sendMessage already cleared composerText, but
    /// the peer still sees "sta scrivendo…" until the auto-stop fires).
    func notifyComposerCleared() {
        typingStopWorkItem?.cancel()
        guard typingActive, let provider = self.appState?.liveProvider else { return }
        typingActive = false
        // W404: also gated. Without this the user could ship a "stop
        // typing" without ever having shipped a "start typing" — server
        // would just ignore but the privacy contract is still violated.
        guard PrivacyGate.typingIndicatorEnabled else { return }
        let peerId = peerUserId
        Task {
            try? await provider.messageApi.sendTypingIndicator(
                recipientId: peerId, isTyping: false
            )
        }
    }

    /// W83: zero `unreadCount` for this conversation. Called by
    /// `ChatDetailScreen.onAppear` so opening a chat clears its badge.
    /// W90: also stamp the active-peer hint on AppState so inbound
    /// banners are suppressed while this chat is on screen.
    /// Idempotent — no-op if already zero.
    func markRead() {
        store.markConversationRead(id: conversationId)
        appState?.activePeerUserId = peerUserId
        refreshFromStore()
    }

    /// W93: hard-clear local message history for this conversation.
    /// Conversation row stays around (so the contact remains in the
    /// list with empty preview); only the messages bucket is wiped.
    func clearLocalHistory() {
        // ConversationStore stores messages under
        // `qaudion.conv.msgs.<conversationId>`. We can re-purpose the
        // existing deleteConversation path partially: remove only the
        // messages bucket without touching the convo list.
        UserDefaults.standard.removeObject(
            forKey: "qaudion.conv.msgs.\(conversationId.uuidString.lowercased())"
        )
        // W137: hard-clear nukes the composer draft too — any unsent
        // text the user typed prior to wiping the chat is intentional
        // collateral; we don't want a stray draft surviving a "delete
        // history" gesture.
        ComposerDraftStore.clear(for: conversationId)
        draftSaveWorkItem?.cancel()
        composerText = ""
        // Reset preview on the conversation row.
        store.recordNewMessage(
            conversationId: conversationId,
            lastMessagePreview: "",
            lastActivity: Date(),
            incrementUnread: false
        )
        refreshFromStore()
    }

    /// W93: server-side block/unblock via ContactsApi. Returns true on
    /// success. Idempotent semantically (blocking an already-blocked
    /// contact returns success per server behaviour).
    func toggleBlock() async -> Bool {
        guard let provider = self.appState?.liveProvider else { return false }
        do {
            try await provider.contactsApi.blockContact(userId: peerUserId)
            return true
        } catch {
            print("[ChatContainer] block failed: \(error)")
            return false
        }
    }

    // MARK: - W441 Ephemeral timer

    /// Set the per-conversation ephemeral timer. `nil` or `0` disables it.
    /// Persists to the ConversationStore so the value survives across restarts.
    /// The next `sendMessage()` call will pick up the new value automatically.
    /// Set the per-conversation ephemeral timer and notify the peer.
    /// seconds = nil/0 = off, positive = TTL, -1 = view-once (Android parity).
    func setEphemeralTimer(_ seconds: Int?) {
        store.setEphemeralTimer(conversationId: conversationId, seconds: seconds)
        refreshFromStore()
        syncEphemeralTimerToPeer(seconds: seconds)
    }

    /// W447: resolve the effective per-message timer for an outbound
    /// attachment — the pre-send dialog's override wins over the
    /// conversation default when present and non-zero, same precedence
    /// as ``AttachmentTimerResolver`` on the receive side (and Desktop's
    /// `resolveAttachmentTimerSec`). Returns `(expiresAt, isViewOnce)`
    /// ready to stamp on the local echo `Message`, computed from `now`.
    private func resolveOutboundAttachmentTimer(
        overrideSeconds: Int?, now: Date
    ) -> (expiresAt: Date?, isViewOnce: Bool) {
        let effective = AttachmentTimerResolver.resolve(
            overrideSeconds: overrideSeconds,
            conversationDefault: viewModel.conversation.ephemeralTimerSeconds
        )
        let expiresAt: Date? = effective.flatMap { s in
            s > 0 ? now.addingTimeInterval(Double(s)) : nil
        }
        let isViewOnce = (effective ?? 0) == -1
        return (expiresAt, isViewOnce)
    }

    /// W90: clear the active-peer hint so inbound banners resume firing
    /// once the user navigates away. Called from
    /// `ChatDetailScreen.onDisappear`.
    func resignActive() {
        if appState?.activePeerUserId == peerUserId {
            appState?.activePeerUserId = nil
        }
    }

    /// W86: ship a `qa_ctl:1` t="delete" envelope to the peer + apply
    /// the tombstone locally so both sides see "Messaggio eliminato".
    /// Only own outbound messages can be deleted (we'd be spoofing
    /// otherwise — the peer's spoof check would reject it anyway).
    /// Idempotent — re-firing is a no-op once the row is tombstoned.
    func deleteMessage(_ message: Message) {
        HapticFeedback.destructiveAction()  // W114: heavy thud
        guard message.direction == .outgoing else {
            print("[ChatContainer] deleteMessage rejected: cannot delete peer's message")
            return
        }
        guard let cmid = message.clientMsgId, !cmid.isEmpty else {
            print("[ChatContainer] deleteMessage: row missing clientMsgId — pre-W86 message?")
            return
        }
        // 1. Apply locally first so the bubble flips immediately.
        store.applyDeleteByClientMsgId(cmid)
        refreshFromStore()
        // 2. Ship envelope.
        let envelope = ChatControlEnvelope.delete(
            target: cmid,
            ts: ChatControlEnvelope.nowTsSeconds()
        )
        emitControlEnvelope(envelope)
    }

    /// W326: delete-local. Tombstone the message in our local store
    /// without sending any envelope to the peer (their copy stays
    /// intact). Used by the "Elimina per te" action in the chat
    /// bubble action sheet — the user wants to hide it from their
    /// own view without affecting the conversation on the other side.
    ///
    /// Closes audit §2.1 (TODO_AUDIT.md).
    ///
    /// Idempotent — re-firing is a no-op once the row is tombstoned.
    func deleteMessageLocally(_ message: Message) {
        HapticFeedback.destructiveAction()  // W114: heavy thud
        guard let cmid = message.clientMsgId, !cmid.isEmpty else {
            print("[ChatContainer] deleteMessageLocally: missing clientMsgId")
            return
        }
        // Apply tombstone locally — no peer envelope.
        store.applyDeleteByClientMsgId(cmid)
        refreshFromStore()
    }

    /// W86: ship a `qa_ctl:1` t="edit" envelope to the peer + replace
    /// the body locally. Only own outbound text messages can be edited
    /// (peer's spoof check rejects edits of their own messages too).
    func editMessage(_ message: Message, newPlaintext: String) {
        let trimmed = newPlaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard message.direction == .outgoing else { return }
        guard let cmid = message.clientMsgId, !cmid.isEmpty else { return }
        // Cap body at the cross-platform limit (8 KiB).
        guard trimmed.utf8.count <= ChatControlEnvelope.editBodyCapBytes else {
            print("[ChatContainer] editMessage rejected: body > 8 KiB")
            return
        }
        // 1. Apply locally.
        store.applyEditByClientMsgId(cmid, newPlaintext: trimmed)
        refreshFromStore()
        // 2. Ship envelope.
        let envelope = ChatControlEnvelope.edit(
            target: cmid,
            newBody: trimmed,
            ts: ChatControlEnvelope.nowTsSeconds()
        )
        emitControlEnvelope(envelope)
    }

    /// W87: toggle a reaction on any message (own or peer's). Updates
    /// the local row immediately + emits the qa_ctl:1 reaction envelope
    /// to the peer. Reactions don't have a spoof check (the originator
    /// is always the envelope sender, by construction). Empty emoji
    /// or > 16 chars is rejected (Desktop hardening parity).
    func toggleReaction(_ message: Message, emoji: String) {
        HapticFeedback.reactionToggle()  // W114: selection click
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= ChatControlEnvelope.reactionEmojiCapChars else {
            print("[ChatContainer] toggleReaction rejected: emoji invalid")
            return
        }
        guard let cmid = message.clientMsgId, !cmid.isEmpty else {
            print("[ChatContainer] toggleReaction: row missing clientMsgId — pre-W86 message?")
            return
        }
        guard let myUserId = appState?.currentUserId, !myUserId.isEmpty else {
            print("[ChatContainer] toggleReaction: missing currentUserId")
            return
        }
        // 1. Apply locally first so the bubble flips immediately.
        _ = store.applyReactionToggleByClientMsgId(cmid, userId: myUserId, emoji: trimmed)
        refreshFromStore()
        // 2. Ship envelope.
        let envelope = ChatControlEnvelope.reaction(
            target: cmid,
            emoji: trimmed,
            ts: ChatControlEnvelope.nowTsSeconds()
        )
        emitControlEnvelope(envelope)
    }

    /// W86: shared envelope-emission tail for delete/edit/reaction.
    /// Encrypts the JSON envelope as the plaintext of a normal `msg_send`
    /// (server is unaware — sees ciphertext only). Best-effort
    /// fire-and-forget; failures log only.
    private func emitControlEnvelope(_ envelope: ChatControlEnvelope) {
        guard let sendService = self.sendService else {
            print("[ChatContainer] emitControlEnvelope: no sendService bound")
            return
        }
        let peerId = peerUserId
        let envelopeId = UUID()
        let json: String
        do {
            json = try envelope.toJsonString()
        } catch {
            print("[ChatContainer] envelope serialize failed: \(error)")
            return
        }
        Task { [peerId, json, envelopeId] in
            // The envelope rides as a normal chat message; the receiver's
            // handleIncomingMessage detects the qa_ctl marker and routes
            // it via handleControlEnvelope INSTEAD of appending a row.
            // We don't store the envelope locally either (would clutter
            // the chat with unrenderable JSON).
            let outcome = await sendService.sendEncrypted(
                messageId: envelopeId,
                peerUserId: peerId,
                plaintext: json
            )
            if case .failed(let reason) = outcome {
                print("[ChatContainer] envelope send failed: \(reason)")
            }
        }
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
        // W404: real gating on the read-receipts privacy flag. When
        // the user has disabled "Conferme di lettura" in Privacy / Chat
        // settings, we still mark the local conversation as read (badge
        // clears) but DON'T tell the peer. Their UI keeps showing ✓✓
        // grey instead of ✓✓ blue. Bookkeeping in `markRead()` runs
        // unconditionally — the gate is purely on the wire envelope.
        guard PrivacyGate.readReceiptsEnabled else { return }
        // Mesh-delivered messages have no server id, so the call below skips
        // them entirely and the blue ticks never arrived for exactly the
        // transport that has no server to ask. They are acknowledged back over
        // the same radio instead, under this same privacy gate.
        emitMeshReadReceipts()
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

    /// Acknowledge, over Bluetooth, the messages that arrived over Bluetooth.
    ///
    /// The node id is the peer's own, derived from their identity key the same
    /// way the radar derives it — not whatever a nearby advert claimed.
    private func emitMeshReadReceipts() {
        guard let appState = self.appState else { return }
        let meshInbound = store.loadMessages(conversationId: conversationId)
            .filter { $0.direction == .incoming && ($0.viaMesh ?? false) && $0.readAt == nil }
        guard !meshInbound.isEmpty else { return }
        let peerId = peerUserId
        guard let contact = appState.cachedContacts.first(where: { $0.userId == peerId }),
              let nodeHex = MeshFeature.nodeId(forContactPubkey: contact.pubkey)?.hex else { return }
        for msg in meshInbound {
            guard let cid = msg.clientMsgId else { continue }
            appState.sendMeshReceipt(
                toNodeHex: nodeHex, peerUserId: peerId,
                messageClientMsgId: cid, kind: MeshReceipt.kindRead
            )
            // Stamp readAt locally, or the filter above matches the same
            // messages again on the next chat open and the peer receives a
            // fresh read receipt for their whole mesh history every time the
            // screen appears.
            store.updateMessageStatus(
                id: msg.id, conversationId: conversationId, newStatus: msg.status,
                deliveredAt: msg.deliveredAt, readAt: Date()
            )
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
    ///
    /// - Parameter overrideTimerSeconds: W447 — per-attachment timer
    ///   chosen in the pre-send dialog. `nil` (default) means "no
    ///   override, use the conversation default" — identical behavior
    ///   to before this parameter existed. Threaded into the `qfile`
    ///   marker's `ex` field AND used to stamp this send's own local
    ///   echo `expiresAt`/`isViewOnce`, taking precedence over the
    ///   conversation default for this one message.
    /// - Parameter exportBlocked: export-permission choice from the
    ///   pre-send dialog. `false` (default) = export allowed. Stamped
    ///   onto the local echo `Message.exportBlocked` AND threaded through
    ///   to `ChatVoiceNoteSender.prepareMarkerJson` — unlike
    ///   `sendImage`/`sendFileAttachment`, THIS path can actually reach
    ///   the wire (`att.xp`) when `VoiceNote.attachAnnounce.enabled` is
    ///   on; the legacy qfile fallback still cannot carry it.
    func sendVoiceNote(_ recording: VoiceNoteRecorder.Recording, overrideTimerSeconds: Int? = nil, exportBlocked: Bool = false) {
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

        // W447: resolve this send's effective timer (override wins over
        // conversation default) and stamp the local echo the same way
        // sendMessage() does for text.
        let (ephExpiry, isViewOnce) = resolveOutboundAttachmentTimer(
            overrideSeconds: overrideTimerSeconds, now: Date()
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
            mediaMimeType: recording.mimeType,
            // W86: stamp clientMsgId so peer can target with edit/delete.
            clientMsgId: msgId.uuidString,
            expiresAt: ephExpiry,
            isViewOnce: isViewOnce ? true : nil,
            exportBlocked: exportBlocked ? true : nil
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

        Task { [weak self] in
            await ChatContainer.sendVoiceNoteAsync(
                weakContainer: Weak(self), recording: recording, peerId: peerId,
                convId: convId, msgId: msgId,
                sendService: sendService, appState: appState,
                overrideTimerSeconds: overrideTimerSeconds,
                exportBlocked: exportBlocked
            )
        }
    }

    /// Extracted body of the `sendVoiceNote` upload `Task`.
    ///
    /// Two things drove making this a `static` method taking an explicit
    /// `weakContainer:` parameter rather than an instance method reached
    /// via `self?.` at the call site:
    ///
    /// 1. **Preserves original weak-self semantics.** Before this change,
    ///    `sendService`/`appState` were captured *strongly* by the `Task`
    ///    (plain closure capture, not listed in `[weak self, ...]`), so
    ///    `sendEncrypted` always ran to completion even if the user had
    ///    already navigated away and `ChatContainer` (a `@StateObject` on
    ///    `ChatDetailScreen`) deallocated mid-upload — only the `self?.`
    ///    UI-update calls silently no-op'd. `weakContainer` is a `Weak<
    ///    ChatContainer>` **box** (see the file-top `Weak<T>` type), not a
    ///    plain `ChatContainer?` — a plain optional parameter would hold a
    ///    STRONG reference for the whole call (including every `await`
    ///    inside it), which is the opposite of the original behavior. The
    ///    box is captured by reference (zero refcount effect on
    ///    `ChatContainer`) and `.value` is re-read at each of the three
    ///    points below that touch `self`, so `ChatContainer` stays exactly
    ///    as free to deallocate mid-upload as it was on `main`. The
    ///    network call itself (`sendEncrypted`) never reads `weakContainer`
    ///    — it only closes over the strongly-captured `sendService`/
    ///    `appState`, so it always runs to completion regardless.
    /// 2. **SWIFT6_PATTERNS.md rule 5** (closure depth): the pre-existing
    ///    `do/catch` + `onProgress`/`MainActor.run` nesting was already at
    ///    the documented risk depth; wrapping it in one more inline
    ///    trailing closure (`BackgroundUploadTask.run { ... }`) risks the
    ///    "unable to type-check this expression in reasonable time"
    ///    failure this codebase has hit repeatedly. Moving the body to a
    ///    named method (regardless of static/instance) sidesteps that.
    private static func sendVoiceNoteAsync(
        weakContainer: Weak<ChatContainer>,
        recording: VoiceNoteRecorder.Recording,
        peerId: String,
        convId: UUID,
        msgId: UUID,
        sendService: ChatMessageSendService,
        appState: AppState,
        overrideTimerSeconds: Int? = nil,
        exportBlocked: Bool = false
    ) async {
        // W-BGUP: extend the process's execution window past the ~30s
        // the OS grants a freshly-backgrounded app, so a large voice
        // note isn't silently killed mid-upload if the user locks the
        // screen or switches apps. Covers the whole upload+seal+announce
        // sequence (prep + sendEncrypted), not just the raw TUS PATCH
        // loop — the send isn't meaningful until both finish. See
        // `BackgroundUploadTask` for the begin/end guarantees and the
        // cross-launch-resume scope note.
        await BackgroundUploadTask.run(name: "attachment-upload") {
            await ChatContainer.completeVoiceNoteSend(
                weakContainer: weakContainer, recording: recording, peerId: peerId,
                convId: convId, msgId: msgId,
                sendService: sendService, appState: appState,
                overrideTimerSeconds: overrideTimerSeconds,
                exportBlocked: exportBlocked
            )
        }
    }

    private static func completeVoiceNoteSend(
        weakContainer: Weak<ChatContainer>,
        recording: VoiceNoteRecorder.Recording,
        peerId: String,
        convId: UUID,
        msgId: UUID,
        sendService: ChatMessageSendService,
        appState: AppState,
        overrideTimerSeconds: Int? = nil,
        exportBlocked: Bool = false
    ) async {
        // SEC-WIREUNIFY (2026-08-03): voice notes now ship over the
        // cross-platform `qa_fa_announce:1` scheme (X25519-per-device
        // wrap + XChaCha20-Poly1305 chunks) instead of the iPhone-only
        // `qfile` marker — see `ChatFileAttachmentSender`. The optimistic
        // local bubble (msgId/convId, local media path) was already
        // created by the caller before this async continuation runs;
        // only the terminal status needs updating here. No TUS-resume
        // breadcrumb is written for new sends on this path (see the type
        // doc on `ChatFileAttachmentSender` — resume is a follow-up, not
        // a correctness requirement for the cross-platform fix).
        try? await Task.sleep(nanoseconds: 200_000_000)  // same flush window as before
        let bytes: Data
        do {
            bytes = try Data(contentsOf: recording.fileURL)
        } catch {
            print("[ChatContainer] voice note read failed: \(error)")
            await MainActor.run { weakContainer.value?.markFailed(messageId: msgId, reason: .generic) }
            return
        }
        let sender = ChatFileAttachmentSender(appState: appState)
        do {
            try await sender.send(
                data: bytes,
                mime: recording.mimeType,
                filename: "voicenote-\(recording.fileURL.deletingPathExtension().lastPathComponent).m4a",
                recipientUserId: peerId,
                ephemeralSpecSec: overrideTimerSeconds.map(Int64.init),
                exportAllowed: !exportBlocked
            )
        } catch let e as ChatFileAttachmentSender.SendError {
            print("[ChatContainer] voice note send failed: \(e.localizedDescription)")
            await MainActor.run {
                weakContainer.value?.markFailed(messageId: msgId, reason: .uploadFailure)
            }
            return
        } catch {
            print("[ChatContainer] voice note send failed: \(error)")
            await MainActor.run {
                weakContainer.value?.markFailed(messageId: msgId, reason: .generic)
            }
            return
        }
        await MainActor.run {
            guard let self = weakContainer.value else { return }
            self.clearUploadProgress(messageId: msgId)
            self.store.updateMessageStatus(
                id: msgId, conversationId: convId,
                newStatus: .delivered, deliveredAt: Date()
            )
            self.refreshFromStore()
        }
    }

    /// W446: record upload progress for an in-flight attachment send.
    /// Called from the `onProgress` closure passed to
    /// `ChatVoiceNoteSender` as TUS chunks complete. `bytesUploaded` /
    /// `totalBytes` come straight from `TusUploadClient` — guards against
    /// a zero `totalBytes` (small-file multipart path never calls this,
    /// but stay defensive) to avoid a NaN ratio.
    func updateUploadProgress(messageId: UUID, bytesUploaded: Int64, totalBytes: Int64) {
        guard totalBytes > 0 else { return }
        uploadProgress[messageId] = Double(bytesUploaded) / Double(totalBytes)
    }

    /// Clear the local-only progress entry once a send reaches a
    /// terminal state (sent/delivered/failed) so `messageRow` falls back
    /// to the normal status-derived delivery icon.
    func clearUploadProgress(messageId: UUID) {
        uploadProgress.removeValue(forKey: messageId)
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
        clearUploadProgress(messageId: messageId)
        refreshFromStore()
    }

    /// Resetta i flag di failure e ri-tenta la send pipeline.
    ///
    /// **W88**: branched on `mediaMimeType` so voice notes and images
    /// rebuild their pipeline from the local cache instead of falling
    /// through to text-send (which would lose the attachment). Three
    /// paths:
    ///
    ///   - **text**: composerText repopulated with the original plaintext;
    ///     the old failed row is removed and `sendMessage()` produces a
    ///     fresh bubble. (Old behaviour kept the failed row + spawned
    ///     a duplicate; cleaner UX is to replace.)
    ///   - **audio/* (voice note)**: the cached M4A still lives at
    ///     `Library/Caches/voicenotes/<oldMsgId>.m4a`. Reconstruct a
    ///     `VoiceNoteRecorder.Recording` and call `sendVoiceNote`.
    ///   - **image/* (photo)**: the cached JPEG lives at
    ///     `Library/Caches/images/<oldMsgId>.jpg`. Re-read the bytes
    ///     and call `sendImage`.
    ///
    /// In all three branches the OLD failed row is hard-removed so the
    /// chat doesn't show two bubbles for the same message.
    ///
    /// **W-TUSRESUME (2026-07-02)**: before falling into the audio/image
    /// tier-3 branches above (drop row, mint fresh msgId, full
    /// re-upload), both now first check for a persisted `TusResumeState`
    /// keyed by the failed message's `clientMsgId`:
    ///   - Found + `TusResumeStateStore.checkCorruption` passes → attempt
    ///     tier 1 (`resumeAttachmentIfPossible`), reusing the message's EXISTING
    ///     id (never minting a new one — from the user's view this is
    ///     "my stuck upload continued," not a new message appearing).
    ///     Wrapped in the same `Weak<ChatContainer>` +
    ///     `BackgroundUploadTask.run` protection as a fresh send.
    ///   - `TusError.uploadNotFound` (past the 24h server retention
    ///     window, or the record never existed) or any other resume
    ///     failure (tier-2 chunk-retries exhausted, corruption check
    ///     failed) → clear the stale `TusResumeState` entry and fall
    ///     through to the UNCHANGED tier-3 path below (drop+mint-fresh).
    ///   - No persisted state at all → today's behavior, nothing changes.
    func retryFailedMessage() {
        guard let id = failedMessageId,
              let msg = store.loadMessages(conversationId: conversationId)
                  .first(where: { $0.id == id })
        else { return }
        // Clear failure flags so the snackbar dismisses.
        failedMessageId = nil
        failureReason = nil

        let mime = msg.mediaMimeType ?? ""

        if mime.hasPrefix("audio/"),
           let path = msg.mediaLocalPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path),
           let durMs = msg.mediaDurationMs {
            // W-TUSRESUME: tier-1 resume attempt before the tier-3 drop
            // + fresh-send fallback below. `resumeAttachmentIfPossible` returns
            // `true` only when it actually kicked off a resume Task (in
            // which case IT owns the row — do not fall through); `false`
            // means "nothing to resume" or "resume state was stale and
            // has been cleared" — proceed to tier 3 exactly as before.
            if resumeAttachmentIfPossible(msg: msg, sourcePath: path) {
                return
            }
            // Voice-note retry: rebuild a Recording from the cache and
            // re-ship via sendVoiceNote.
            store.removeMessage(id: id, conversationId: conversationId)
            refreshFromStore()
            let rec = VoiceNoteRecorder.Recording(
                fileURL: URL(fileURLWithPath: path),
                durationMs: Int(durMs),
                mimeType: mime
            )
            sendVoiceNote(rec)
            // Old cache file has been re-persisted under the new msgId by
            // sendVoiceNote -> persistOutboundVoiceNote; best-effort reclaim
            // the orphaned old-path blob. Never propagate failures here:
            // the retry already succeeded.
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                } catch {
                    print("[ChatContainer] retryFailedMessage: cache cleanup failed for \(path): \(error)")
                }
            }
            return
        }
        if mime.hasPrefix("image/"),
           let path = msg.mediaLocalPath, !path.isEmpty,
           let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            // W-TUSRESUME: same tier-1 attempt as the audio branch above.
            if resumeAttachmentIfPossible(msg: msg, sourcePath: path) {
                return
            }
            // Image retry: re-read the JPEG and re-ship via sendImage.
            store.removeMessage(id: id, conversationId: conversationId)
            refreshFromStore()
            sendImage(bytes)
            // Old cache file has been re-persisted under the new msgId by
            // sendImage -> persistOutboundImage; best-effort reclaim the
            // orphaned old-path blob. Never propagate failures here: the
            // retry already succeeded.
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                } catch {
                    print("[ChatContainer] retryFailedMessage: cache cleanup failed for \(path): \(error)")
                }
            }
            return
        }
        // Text fallback: pop the body back into the composer and ship
        // via sendMessage. Hard-remove the old row so we don't end up
        // with two copies of the same line.
        store.removeMessage(id: id, conversationId: conversationId)
        refreshFromStore()
        composerText = msg.plaintext
        sendMessage()
    }

    /// W-TUSRESUME — checks for a persisted `TusResumeState` matching
    /// `msg.clientMsgId` and, if the source file at `sourcePath` passes
    /// the corruption check, kicks off a tier-1 resume attempt on a
    /// background `Task` and returns `true` (caller must NOT also run
    /// its tier-3 fallback — the resume Task owns the message row from
    /// here, including its own internal fallback to tier 3 on failure).
    ///
    /// Returns `false` — synchronously, no `Task` spawned — when there's
    /// nothing to resume (no persisted state) or the state is stale
    /// (corruption check failed, entry already cleared): the caller
    /// proceeds with its existing tier-3 drop+mint-fresh path unchanged.
    ///
    /// - Important: `msg.id` (the EXISTING message id) is threaded all
    ///   the way through — `resumeAttachmentIfPossible` never mints a new UUID.
    ///   This is what makes a successful resume invisible to the user as
    ///   anything other than "the stuck upload finished" rather than a
    ///   duplicate bubble.
    private func resumeAttachmentIfPossible(msg: Message, sourcePath: String) -> Bool {
        guard let clientMsgId = msg.clientMsgId,
              let state = TusResumeStateStore.load(clientMsgId: clientMsgId)
        else { return false }

        let check = TusResumeStateStore.checkCorruption(state: state, sourcePath: sourcePath)
        guard case .resumable = check else {
            if case .corrupted(let reason) = check {
                print("[ChatContainer] resumeAttachmentIfPossible: stale TusResumeState for \(clientMsgId): \(reason) — clearing, falling through to tier 3")
            }
            TusResumeStateStore.clear(clientMsgId: clientMsgId)
            return false
        }

        guard let sendService = self.sendService, let appState = self.appState else {
            // No backend wired (preview / unit test) — nothing sane to
            // resume against; let the caller's existing preview fallback
            // (inside sendVoiceNote/sendImage's tier-3 path) handle it.
            return false
        }

        let convId = conversationId
        let msgId = msg.id
        let peerId = peerUserId
        let mime = msg.mediaMimeType ?? ""

        Task { [weak self] in
            await ChatContainer.resumeAttachmentAsync(
                weakContainer: Weak(self), state: state, sourcePath: sourcePath,
                convId: convId, msgId: msgId, peerId: peerId, mime: mime,
                sendService: sendService, appState: appState
            )
        }
        return true
    }

    /// W-TUSRESUME — tier-1 resume `Task` body. Same `Weak<ChatContainer>`
    /// + `BackgroundUploadTask.run` protection as a fresh send (see
    /// `sendVoiceNoteAsync`/`sendImageAsync`) — a resumed upload can still
    /// be large enough to need the background-execution grace period,
    /// and the container can still deallocate mid-resume if the user
    /// navigates away.
    private static func resumeAttachmentAsync(
        weakContainer: Weak<ChatContainer>,
        state: TusResumeState,
        sourcePath: String,
        convId: UUID,
        msgId: UUID,
        peerId: String,
        mime: String,
        sendService: ChatMessageSendService,
        appState: AppState
    ) async {
        await BackgroundUploadTask.run(name: "attachment-upload-resume") {
            await ChatContainer.completeResumeAttachmentSend(
                weakContainer: weakContainer, state: state, sourcePath: sourcePath,
                convId: convId, msgId: msgId, peerId: peerId, mime: mime,
                sendService: sendService, appState: appState
            )
        }
    }

    private static func completeResumeAttachmentSend(
        weakContainer: Weak<ChatContainer>,
        state: TusResumeState,
        sourcePath: String,
        convId: UUID,
        msgId: UUID,
        peerId: String,
        mime: String,
        sendService: ChatMessageSendService,
        appState: AppState
    ) async {
        // Re-read the source bytes fresh (the corruption check already
        // confirmed size+hash match at the call site, but re-reading
        // here rather than threading `Data` through keeps this method's
        // failure modes identical to a fresh send's file-read step).
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)) else {
            print("[ChatContainer] completeResumeAttachmentSend: source unreadable at \(sourcePath) — clearing resume state, falling back to tier 3")
            TusResumeStateStore.clear(clientMsgId: state.clientMsgId)
            await MainActor.run {
                weakContainer.value?.fallBackToFreshSend(msgId: msgId, sourcePath: sourcePath, mime: mime, state: state)
            }
            return
        }

        let prep = ChatVoiceNoteSender(appState: appState)
        let markerJson: String
        do {
            markerJson = try await prep.resumeAttachmentMarkerJson(
                state: state,
                bytes: bytes,
                onProgress: { bytesUploaded, totalBytes in
                    // W446: see sendVoiceNote — hop to MainActor before
                    // touching @Published upload state.
                    Task { @MainActor in
                        weakContainer.value?.updateUploadProgress(
                            messageId: msgId,
                            bytesUploaded: bytesUploaded,
                            totalBytes: totalBytes
                        )
                    }
                }
            )
        } catch let tusError as TusUploadClient.TusError {
            // W-TUSRESUME: the specific "no longer resumable" signal —
            // whether `.uploadNotFound` (purged past 24h, or never
            // existed server-side) or any other TUS-layer failure after
            // tier-2's bounded per-chunk retries have already been
            // exhausted inside `resume()`. Either way: clear the stale
            // breadcrumb and fall through to tier 3 (fresh upload),
            // exactly as the product decision specifies. Never surfaces
            // as a user-facing failure on its own — tier 3 gets its own
            // chance to succeed or fail.
            print("[ChatContainer] completeResumeAttachmentSend: resume failed (\(tusError.localizedDescription)) — clearing resume state, falling back to tier 3")
            TusResumeStateStore.clear(clientMsgId: state.clientMsgId)
            await MainActor.run {
                weakContainer.value?.fallBackToFreshSend(msgId: msgId, sourcePath: sourcePath, mime: mime, state: state)
            }
            return
        } catch {
            // Any other failure (auth, crypto, token issuance, source
            // unreadable) — same graceful degradation: clear + fall back
            // to tier 3 rather than leaving the message stuck failed.
            print("[ChatContainer] completeResumeAttachmentSend: resume failed (\(error)) — clearing resume state, falling back to tier 3")
            TusResumeStateStore.clear(clientMsgId: state.clientMsgId)
            await MainActor.run {
                weakContainer.value?.fallBackToFreshSend(msgId: msgId, sourcePath: sourcePath, mime: mime, state: state)
            }
            return
        }

        // Resume succeeded — ship using the EXISTING msgId, same
        // seal/announce + status-update tail as a fresh send.
        let outcome = await sendService.sendEncrypted(
            messageId: msgId,
            peerUserId: peerId,
            plaintext: markerJson
        )
        await MainActor.run {
            guard let self = weakContainer.value else { return }
            self.clearUploadProgress(messageId: msgId)
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
                // Successful full completion — clear the breadcrumb.
                TusResumeStateStore.clear(clientMsgId: state.clientMsgId)
            case .sent:
                self.store.updateMessageStatus(
                    id: msgId, conversationId: convId,
                    newStatus: .delivered, deliveredAt: Date()
                )
                TusResumeStateStore.clear(clientMsgId: state.clientMsgId)
            case .failed(let reason):
                // The upload itself succeeded (we got a marker) but the
                // encrypted chat send failed — the underlying fileId is
                // now fully uploaded server-side, so there's nothing left
                // to resume; a subsequent retry would need a fresh
                // upload regardless. Clear rather than leaving a
                // breadcrumb that would only ever resume into
                // `uploadNotFound`-equivalent dead weight at best (the
                // fileId is complete, not partial).
                TusResumeStateStore.clear(clientMsgId: state.clientMsgId)
                self.markFailed(messageId: msgId, reason: reason)
            }
            self.refreshFromStore()
        }
    }

    /// W-TUSRESUME — shared tier-3 fallback invoked from the resume
    /// path's own failure handling (as opposed to `retryFailedMessage`'s
    /// initial dispatch, which never calls this — it takes the identical
    /// but separately-written drop+mint-fresh branches inline). Drops the
    /// still-present message row (the resume attempt never removed it —
    /// only the ORIGINAL tier-3 path in `retryFailedMessage` does that
    /// eagerly) and re-ships via the normal `sendVoiceNote`/`sendImage`
    /// entry points, mirroring `retryFailedMessage`'s own tier-3 branches
    /// exactly (mint-fresh, best-effort old-cache-file cleanup).
    private func fallBackToFreshSend(msgId: UUID, sourcePath: String, mime: String, state: TusResumeState) {
        guard store.loadMessages(conversationId: conversationId).contains(where: { $0.id == msgId }) else {
            // Row already gone (e.g. user deleted it while the resume
            // attempt was in flight) — nothing to fall back to.
            return
        }

        // Resolve what we're about to do BEFORE touching the row — if the
        // source vanished between the resume attempt starting and failing,
        // there's nothing to re-send, so leave the existing (still-failed
        // looking, pre-this-retry) row alone and just mark it failed again
        // rather than removing it out from under a subsequent no-op
        // `markFailed` call.
        if mime.hasPrefix("audio/"), FileManager.default.fileExists(atPath: sourcePath) {
            store.removeMessage(id: msgId, conversationId: conversationId)
            refreshFromStore()
            let rec = VoiceNoteRecorder.Recording(
                fileURL: URL(fileURLWithPath: sourcePath),
                durationMs: Int(state.durationMs ?? 0),
                mimeType: mime
            )
            sendVoiceNote(rec, overrideTimerSeconds: state.timerOverrideSeconds)
        } else if mime.hasPrefix("image/"),
                  let bytes = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)) {
            store.removeMessage(id: msgId, conversationId: conversationId)
            refreshFromStore()
            sendImage(bytes, overrideTimerSeconds: state.timerOverrideSeconds)
        } else {
            // Source vanished between the resume attempt starting and
            // failing — signal_not_kill: surface as a normal failed
            // state rather than silently dropping the message. The row
            // is left in place (never removed) so `markFailed` has a
            // real row to flip to `.failed`.
            markFailed(messageId: msgId, reason: .uploadFailure)
            return
        }

        // Best-effort reclaim of the orphaned old-path blob, mirroring
        // retryFailedMessage's tier-3 branches. Never propagate failures
        // here: the fresh send already kicked off.
        if FileManager.default.fileExists(atPath: sourcePath) {
            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: sourcePath))
            } catch {
                print("[ChatContainer] fallBackToFreshSend: cache cleanup failed for \(sourcePath): \(error)")
            }
        }
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
    ///
    /// - Parameter overrideTimerSeconds: W447 — per-attachment timer
    ///   chosen in the pre-send dialog. `nil` (default) means "no
    ///   override, use the conversation default" — identical behavior
    ///   to before this parameter existed.
    /// - Parameter exportBlocked: export-permission choice from the
    ///   pre-send dialog. `false` (default) = export allowed, stamped
    ///   onto the local echo `Message.exportBlocked` so the sender's own
    ///   bubble gates Save/Condividi consistently with the receiver.
    ///   Does NOT reach the wire for this send path — `sendImage` always
    ///   routes through the legacy qfile marker
    ///   (`ChatVoiceNoteSender.prepareAttachmentMarkerJson`), which is
    ///   explicitly not being extended with `xp` (see
    ///   `AttachAnnounceMeta/xp` doc) — only the local echo is affected.
    /// - Returns: W611 — `false` when the image was rejected before any
    ///   local echo was created (undecodable bytes, or over the 10MB
    ///   post-downscale cap); `true` once a `Message` row has been
    ///   appended and the send has been queued (or simulated, in the
    ///   preview/unit-test fallback). Callers (`ChatDetailScreen`'s
    ///   `performAttachmentSend`) use this to surface a visible snackbar
    ///   for the rejection instead of the previous print-only silent
    ///   drop — critical for a multi-select batch, where one bad photo
    ///   among several used to vanish with zero indication.
    @discardableResult
    func sendImage(_ rawImageData: Data, overrideTimerSeconds: Int? = nil, exportBlocked: Bool = false) -> Bool {
        let peerId = peerUserId
        let convId = conversationId
        let msgId = UUID()

        // Normalize: load → downscale → re-encode JPEG (no EXIF).
        guard let normalized = Self.normalizeImageForChat(rawImageData) else {
            print("[ChatContainer] sendImage normalization failed")
            return false
        }
        let jpeg = normalized.data
        guard jpeg.count <= 10 * 1024 * 1024 else {
            print("[ChatContainer] sendImage rejected: \(jpeg.count) bytes > 10MB cap")
            return false
        }

        // Persist the local copy first so the sender bubble shows the
        // image immediately while the upload is in flight.
        let localCachePath = Self.persistOutboundImage(jpeg: jpeg, msgId: msgId)

        // W447: resolve this send's effective timer (override wins over
        // conversation default) and stamp the local echo the same way
        // sendMessage() does for text.
        let (ephExpiry, isViewOnce) = resolveOutboundAttachmentTimer(
            overrideSeconds: overrideTimerSeconds, now: Date()
        )

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
            mediaMimeType: "image/jpeg",
            // W86: stamp clientMsgId so peer can target with edit/delete.
            clientMsgId: msgId.uuidString,
            expiresAt: ephExpiry,
            isViewOnce: isViewOnce ? true : nil,
            exportBlocked: exportBlocked ? true : nil
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
            return true
        }

        Task { [weak self] in
            await ChatContainer.sendImageAsync(
                weakContainer: Weak(self), jpeg: jpeg, peerId: peerId,
                convId: convId, msgId: msgId,
                overrideTimerSeconds: overrideTimerSeconds,
                sendService: sendService, appState: appState
            )
        }
        return true
    }

    /// Extracted body of the `sendImage` upload `Task` — same rationale
    /// as `sendVoiceNoteAsync` (weak-self semantics preserved via the
    /// `Weak<ChatContainer>` box + SWIFT6_PATTERNS.md rule 5 closure-depth
    /// avoidance).
    private static func sendImageAsync(
        weakContainer: Weak<ChatContainer>,
        jpeg: Data,
        peerId: String,
        convId: UUID,
        msgId: UUID,
        overrideTimerSeconds: Int? = nil,
        sendService: ChatMessageSendService,
        appState: AppState
    ) async {
        // W-BGUP: see sendVoiceNote — buys the process extra time so
        // an in-flight image upload survives brief backgrounding.
        await BackgroundUploadTask.run(name: "attachment-upload") {
            await ChatContainer.completeImageSend(
                weakContainer: weakContainer, jpeg: jpeg, peerId: peerId,
                convId: convId, msgId: msgId,
                overrideTimerSeconds: overrideTimerSeconds,
                sendService: sendService, appState: appState
            )
        }
    }

    private static func completeImageSend(
        weakContainer: Weak<ChatContainer>,
        jpeg: Data,
        peerId: String,
        convId: UUID,
        msgId: UUID,
        overrideTimerSeconds: Int? = nil,
        sendService: ChatMessageSendService,
        appState: AppState
    ) async {
        // SEC-WIREUNIFY (2026-08-03): see completeVoiceNoteSend's
        // identical comment — images now ship over `qa_fa_announce:1`.
        let sender = ChatFileAttachmentSender(appState: appState)
        do {
            try await sender.send(
                data: jpeg,
                mime: "image/jpeg",
                filename: "image-\(msgId.uuidString).jpg",
                recipientUserId: peerId,
                ephemeralSpecSec: overrideTimerSeconds.map(Int64.init)
            )
        } catch let e as ChatFileAttachmentSender.SendError {
            print("[ChatContainer] sendImage failed: \(e.localizedDescription)")
            await MainActor.run { weakContainer.value?.markFailed(messageId: msgId, reason: .uploadFailure) }
            return
        } catch {
            print("[ChatContainer] sendImage failed: \(error)")
            await MainActor.run { weakContainer.value?.markFailed(messageId: msgId, reason: .uploadFailure) }
            return
        }
        await MainActor.run {
            guard let self = weakContainer.value else { return }
            self.clearUploadProgress(messageId: msgId)
            self.store.updateMessageStatus(
                id: msgId, conversationId: convId,
                newStatus: .delivered, deliveredAt: Date()
            )
            self.refreshFromStore()
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

    // MARK: - W445: Forward message

    /// Forward a message to another conversation. Sends the message's
    /// plaintext to the target conversation via the normal send pipeline.
    /// The local store for the target conversation is updated so the
    /// forwarded message appears immediately in the target chat.
    func forwardMessage(_ message: Message, to targetConversationId: UUID) {
        // Find or bootstrap the target conversation's container and send.
        // We send directly via the send service to keep the implementation
        // self-contained — no need to spin up a full ChatContainer.
        let text = message.plaintext
        guard !text.isEmpty, let sendService = self.sendService else {
            print("[ChatContainer] forwardMessage: no sendService or empty plaintext")
            return
        }
        // Look up the peer for the target conversation.
        let convs = store.loadConversations()
        guard let targetConv = convs.first(where: { $0.id == targetConversationId }) else {
            print("[ChatContainer] forwardMessage: target conversation not found")
            return
        }
        let targetPeerId = targetConv.peerUserId
        let msgId = UUID()
        let local = Message(
            id: msgId,
            conversationId: targetConversationId,
            direction: .outgoing,
            plaintext: text,
            sentAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            status: .sending,
            clientMsgId: msgId.uuidString
        )
        store.appendMessage(local)
        store.recordNewMessage(
            conversationId: targetConversationId,
            lastMessagePreview: text,
            lastActivity: Date(),
            incrementUnread: false
        )
        Task { [targetPeerId, msgId, targetConversationId, text] in
            let outcome = await sendService.sendEncrypted(
                messageId: msgId,
                peerUserId: targetPeerId,
                plaintext: text
            )
            await MainActor.run {
                switch outcome {
                case .delivered(let serverMsgId):
                    self.store.setServerMessageId(
                        localId: msgId,
                        conversationId: targetConversationId,
                        serverMessageId: serverMsgId
                    )
                    self.store.updateMessageStatus(
                        id: msgId, conversationId: targetConversationId,
                        newStatus: .delivered, deliveredAt: Date()
                    )
                case .sent:
                    self.store.updateMessageStatus(
                        id: msgId, conversationId: targetConversationId,
                        newStatus: .delivered, deliveredAt: Date()
                    )
                case .failed(let reason):
                    print("[ChatContainer] forwardMessage send failed: \(reason)")
                    self.store.updateMessageStatus(
                        id: msgId, conversationId: targetConversationId,
                        newStatus: .failed
                    )
                }
                self.refreshFromStore()
            }
        }
    }

    // MARK: - W445: Generic file attachment

    /// Send a generic file attachment selected from UIDocumentPickerViewController.
    /// Reads the file data and sends via the existing qfile v3 upload pipeline
    /// (same path as voice notes and images).
    ///
    /// - Parameter overrideTimerSeconds: W447 — per-attachment timer
    ///   chosen in the pre-send dialog. `nil` (default) means "no
    ///   override, use the conversation default" — identical behavior
    ///   to before this parameter existed.
    /// - Parameter exportBlocked: export-permission choice from the
    ///   pre-send dialog. `false` (default) = export allowed, stamped
    ///   onto the local echo `Message.exportBlocked`. Same wire-reach
    ///   caveat as `sendImage` — this path also routes through the
    ///   legacy qfile marker, which never carries `xp`.
    func sendFileAttachment(url: URL, overrideTimerSeconds: Int? = nil, exportBlocked: Bool = false) {
        let peerId = peerUserId
        let convId = conversationId
        let msgId = UUID()
        let filename = url.lastPathComponent
        // Security-scoped access for files outside the app sandbox.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            print("[ChatContainer] sendFileAttachment: could not read \(filename)")
            return
        }
        let mime = Self.mimeType(for: url)
        let displayText: String = "📎 " + filename
        // W447: resolve this send's effective timer (override wins over
        // conversation default) and stamp the local echo the same way
        // sendMessage() does for text.
        let (ephExpiry, isViewOnce) = resolveOutboundAttachmentTimer(
            overrideSeconds: overrideTimerSeconds, now: Date()
        )
        let local = Message(
            id: msgId,
            conversationId: convId,
            direction: .outgoing,
            plaintext: displayText,
            sentAt: Date(),
            deliveredAt: nil,
            readAt: nil,
            status: .sending,
            clientMsgId: msgId.uuidString,
            expiresAt: ephExpiry,
            isViewOnce: isViewOnce ? true : nil,
            exportBlocked: exportBlocked ? true : nil
        )
        store.appendMessage(local)
        store.recordNewMessage(
            conversationId: convId,
            lastMessagePreview: displayText,
            lastActivity: Date(),
            incrementUnread: false
        )
        refreshFromStore()
        guard let sendService = self.sendService,
              let appState = self.appState else {
            // Preview / unit-test fallback.
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
        Task { [weak self] in
            await ChatContainer.sendFileAttachmentAsync(
                weakContainer: Weak(self), data: data, mime: mime, filename: filename,
                peerId: peerId, convId: convId, msgId: msgId,
                overrideTimerSeconds: overrideTimerSeconds,
                sendService: sendService, appState: appState
            )
        }
    }

    /// Extracted body of the `sendFileAttachment` upload `Task` — same
    /// rationale as `sendVoiceNoteAsync` (weak-self semantics preserved via
    /// the `Weak<ChatContainer>` box + SWIFT6_PATTERNS.md rule 5
    /// closure-depth avoidance). Files can be the largest attachments sent
    /// (up to the 10 MB app-level cap enforced elsewhere), making the
    /// background-execution grace period especially relevant here.
    private static func sendFileAttachmentAsync(
        weakContainer: Weak<ChatContainer>,
        data: Data,
        mime: String,
        filename: String,
        peerId: String,
        convId: UUID,
        msgId: UUID,
        overrideTimerSeconds: Int? = nil,
        sendService: ChatMessageSendService,
        appState: AppState
    ) async {
        // W-BGUP: see sendVoiceNote — buys the process extra time so an
        // in-flight file upload survives brief backgrounding instead of
        // being silently killed mid-chunk.
        await BackgroundUploadTask.run(name: "attachment-upload") {
            await ChatContainer.completeFileAttachmentSend(
                weakContainer: weakContainer, data: data, mime: mime, filename: filename,
                peerId: peerId, convId: convId, msgId: msgId,
                overrideTimerSeconds: overrideTimerSeconds,
                sendService: sendService, appState: appState
            )
        }
    }

    private static func completeFileAttachmentSend(
        weakContainer: Weak<ChatContainer>,
        data: Data,
        mime: String,
        filename: String,
        peerId: String,
        convId: UUID,
        msgId: UUID,
        overrideTimerSeconds: Int? = nil,
        sendService: ChatMessageSendService,
        appState: AppState
    ) async {
        // SEC-WIREUNIFY (2026-08-03): see completeVoiceNoteSend's
        // identical comment — generic files now ship over
        // `qa_fa_announce:1`.
        let sender = ChatFileAttachmentSender(appState: appState)
        do {
            try await sender.send(
                data: data,
                mime: mime,
                filename: filename,
                recipientUserId: peerId,
                ephemeralSpecSec: overrideTimerSeconds.map(Int64.init)
            )
        } catch let e as ChatFileAttachmentSender.SendError {
            print("[ChatContainer] sendFileAttachment failed: \(e.localizedDescription)")
            await MainActor.run { weakContainer.value?.markFailed(messageId: msgId, reason: .uploadFailure) }
            return
        } catch {
            print("[ChatContainer] sendFileAttachment failed: \(error)")
            await MainActor.run { weakContainer.value?.markFailed(messageId: msgId, reason: .uploadFailure) }
            return
        }
        await MainActor.run {
            guard let self = weakContainer.value else { return }
            self.clearUploadProgress(messageId: msgId)
            self.store.updateMessageStatus(
                id: msgId, conversationId: convId,
                newStatus: .delivered, deliveredAt: Date()
            )
            self.refreshFromStore()
        }
    }

    /// Infer MIME type from a file URL extension. Falls back to
    /// "application/octet-stream" for unknown extensions.
    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":   return "application/pdf"
        case "doc":   return "application/msword"
        case "docx":  return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":   return "application/vnd.ms-excel"
        case "xlsx":  return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":   return "application/vnd.ms-powerpoint"
        case "pptx":  return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "zip":   return "application/zip"
        case "txt":   return "text/plain"
        case "csv":   return "text/csv"
        case "png":   return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":   return "image/gif"
        case "mp4":   return "video/mp4"
        case "mov":   return "video/quicktime"
        case "mp3":   return "audio/mpeg"
        case "m4a":   return "audio/mp4"
        default:      return "application/octet-stream"
        }
    }

    func refreshFromStore() {
        let messages = store.loadMessages(conversationId: conversationId)
        let conv = store.loadConversations().first { $0.id == conversationId } ?? viewModel.conversation
        screenshotGrantedByPeer = conv.screenshotGrantedByPeer
        viewModel = ChatViewModel(
            conversation: conv,
            messages: messages,
            composerText: composerText,
            isPeerTyping: viewModel.isPeerTyping,
            isPeerOnline: viewModel.isPeerOnline
        )
    }

    // MARK: - View-once

    /// Called when the user taps to reveal a view-once message.
    func markViewOnceOpened(message: Message) {
        store.markViewOnceOpened(messageId: message.id, conversationId: conversationId)
        refreshFromStore()
    }

    // MARK: - Screenshot permission (Android wire: ss_req / ss_resp / ss_lock)

    /// Send a screenshot-permission REQUEST to the peer.
    /// Android: ChatControlEnvelope TYPE_SCREENSHOT_REQUEST = "ss_req"
    func requestScreenshotPermission() {
        sendControlEnvelope(
            payload: "{\"qa_ctl\":1,\"t\":\"ss_req\",\"ts\":\(Int64(Date().timeIntervalSince1970))}",
            preview: "📸 Richiesta autorizzazione screenshot"
        )
    }

    /// Approve an incoming screenshot-request from the peer.
    /// Android: ChatControlEnvelope TYPE_SCREENSHOT_RESPONSE = "ss_resp" + approved:true
    func grantScreenshotPermission() {
        sendControlEnvelope(
            payload: "{\"qa_ctl\":1,\"t\":\"ss_resp\",\"approved\":true,\"ts\":\(Int64(Date().timeIntervalSince1970))}",
            preview: "📸 Screenshot autorizzati"
        )
    }

    /// Re-lock screenshots in this conversation.
    /// Android: ChatControlEnvelope TYPE_SCREENSHOT_LOCK = "ss_lock"
    func revokeScreenshotPermission() {
        store.setScreenshotGranted(conversationId: conversationId, granted: false)
        sendControlEnvelope(
            payload: "{\"qa_ctl\":1,\"t\":\"ss_lock\",\"ts\":\(Int64(Date().timeIntervalSince1970))}",
            preview: "📸 Screenshot nuovamente bloccati"
        )
    }

    /// Handle an incoming screenshot-control envelope from the peer.
    /// Called by AppState when a message with qa_ctl ss_* type arrives.
    func handleScreenshotControl(type: String, approved: Bool?) {
        switch type {
        case "ss_resp":
            store.setScreenshotGranted(conversationId: conversationId, granted: approved == true)
            refreshFromStore()
        case "ss_lock":
            store.setScreenshotGranted(conversationId: conversationId, granted: false)
            refreshFromStore()
        default:
            break
        }
    }

    // MARK: - Ephemeral timer sync to peer
    // Android: ChatControlEnvelope TYPE_EPHEMERAL_TIMER = "ephemeral_timer", timer_sec field
    // timer_sec: -1 = view-once, 0 = off, positive = seconds

    /// Notify the peer of the new per-conversation ephemeral timer.
    /// Call after setEphemeralTimer() so both sides are in sync.
    func syncEphemeralTimerToPeer(seconds: Int?) {
        let timerSec = seconds ?? 0
        let payload: String = "{\"qa_ctl\":1,\"t\":\"ephemeral_timer\",\"timer_sec\":\(timerSec),\"ts\":\(Int64(Date().timeIntervalSince1970))}"
        let preview: String = timerSec == -1 ? "⏱ Messaggi: visualizza una volta"
            : timerSec == 0 ? "⏱ Messaggi a scomparsa: disattivati"
            : "⏱ Messaggi a scomparsa: \(timerSec)s"
        sendControlEnvelope(payload: payload, preview: preview)
    }

    // MARK: - Private helper

    private func sendControlEnvelope(payload: String, preview: String) {
        let reqId = UUID()
        let msg = Message(
            id: reqId, conversationId: conversationId,
            direction: .outgoing, plaintext: payload,
            sentAt: Date(), deliveredAt: nil, readAt: nil, status: .sending,
            clientMsgId: reqId.uuidString
        )
        store.appendMessage(msg)
        store.recordNewMessage(conversationId: conversationId,
                               lastMessagePreview: preview,
                               lastActivity: Date(), incrementUnread: false)
        refreshFromStore()
        if let sender = sendService {
            Task { [peerUserId = peerUserId, msgId = reqId, payload] in
                _ = await sender.sendEncrypted(messageId: msgId,
                                               peerUserId: peerUserId,
                                               plaintext: payload)
            }
        }
    }
}
