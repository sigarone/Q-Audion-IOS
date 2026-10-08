import SwiftUI
import QAudionEngine

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
        /// A file (document) failed to send; the sentence that says why is `ChatContainer.failureDetail`.
        case fileTransfer    = "file_transfer"
        case generic         = "send_error"
        /// 2026-09-19 service-message root fix — a SERVICE payload has no
        /// CONTROL session to be sealed on. Typed so the caller can hold it
        /// (`ServiceSendCoordinator`) instead of ever falling back to the CHAT
        /// ladder. Never shown to the user: service sends have no UI.
        case noControlSession = "no_control_session"

        // W-L10N-BATCH1 (2026-09-08) — this drives a plain-String error
        // banner (not a SwiftUI Text literal at the display site), so it
        // needs an explicit lookup here at the point of construction.
        var localizedDescription: String {
            switch self {
            case .pskMissing:
                return String(localized: "chat.send_error.psk_missing", defaultValue: "Errore di cifratura. Contatto non verificato.", comment: "Message-send failure banner — recipient's key isn't verified")
            case .cryptoFailure:
                return String(localized: "chat.send_error.crypto_failure", defaultValue: "Errore crittografico. Riprova.", comment: "Message-send failure banner — generic crypto failure")
            case .networkError:
                return String(localized: "chat.send_error.network_error", defaultValue: "Errore di rete. Controlla la connessione.", comment: "Message-send failure banner — network error")
            case .notAuthenticated:
                return String(localized: "chat.send_error.not_authenticated", defaultValue: "Sessione scaduta. Effettua di nuovo l'accesso.", comment: "Message-send failure banner — session expired")
            case .uploadFailure:
                return String(localized: "chat.send_error.upload_failure", defaultValue: "Caricamento allegato fallito. Riprova.", comment: "Message-send failure banner — attachment upload failed")
            case .fileTransfer:
                return String(localized: "chat.send_error.file_transfer", defaultValue: "Invio del file non riuscito. Riprova.", comment: "Message-send failure banner — a file could not be sent")
            case .generic, .noControlSession:
                return String(localized: "chat.send_error.generic", defaultValue: "Invio fallito. Riprova più tardi.", comment: "Message-send failure banner — generic send failure")
            }
        }
    }

    @Published private(set) var viewModel: ChatViewModel
    @Published var composerText: String = ""

    @Published private(set) var failedMessageId: UUID? = nil
    @Published private(set) var failureReason: SendFailureReason? = nil
    /// The sentence that says WHY a file failed (`FileV2FailureText`), shown instead of the generic text of `failureReason`; nil for
    /// every other failure.
    @Published private(set) var failureDetail: String? = nil
    /// A one-line notice for the screen to show once (a snackbar), then clear with `clearTransientNotice()`.
    @Published private(set) var transientNotice: String? = nil
    /// What it takes to send a failed file again: the picked file (the app does not keep a copy; a row that outlives the app
    /// cannot be retried, the user attaches the file again) and the choices made in the pre-send dialog.
    private struct FileV2RetrySource {
        let url: URL
        let overrideTimerSeconds: Int?
        let exportBlocked: Bool
    }
    private var fileV2Retry: [UUID: FileV2RetrySource] = [:]
    /// When true, the NEXT message sent will be flagged as view-once.
    /// Mirrors conversation.screenshotGrantedByPeer for reactive UI.
    @Published private(set) var screenshotGrantedByPeer: Bool? = nil
    /// True while the peer's ss_req is awaiting a live approve/deny answer.
    /// Transient, in-memory only — matches Android's incomingScreenshotRequest
    /// StateFlow (never DB-persisted, never a chat message).
    @Published private(set) var incomingScreenshotRequest: Bool = false
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
            // W-CHATHEADERSTALE (2026-08-17) — `peerDisplayName` is written
            // ONCE, the first time this conversation row is created, and
            // this init used to keep that value forever regardless of what
            // fresh name the caller just passed in. The chat LIST resolves
            // the peer's name live on every render (DisplayName.forUser
            // against the current rubrica); this stored row does not — so a
            // peer who renamed themselves kept showing their OLD name in
            // the chat header while the list right above it already showed
            // the new one (confirmed live 2026-08-17: contact/avatar sync
            // now works, but the in-chat header lagged behind it). The
            // caller's `peerDisplayName` argument is exactly as fresh as
            // what the list row just rendered (ChatListScreen passes
            // `item.peerDisplayName` straight through), so trust it over
            // the stored value whenever it looks like a real name and
            // actually differs — same trust bar `resolvedPeerTitle` below
            // already applies to the stored value at render time.
            if !peerDisplayName.isEmpty,
               !DisplayName.looksLikeUUID(peerDisplayName),
               !DisplayName.isPlaceholderName(peerDisplayName),
               peerDisplayName != e.peerDisplayName {
                let refreshed = Conversation(
                    id: e.id,
                    peerUserId: e.peerUserId,
                    peerDisplayName: peerDisplayName,
                    lastMessagePreview: e.lastMessagePreview,
                    lastActivity: e.lastActivity,
                    unreadCount: e.unreadCount,
                    pinned: e.pinned,
                    kind: e.kind,
                    muted: e.muted,
                    ephemeralTimerSeconds: e.ephemeralTimerSeconds,
                    screenshotGrantedByPeer: e.screenshotGrantedByPeer
                )
                store.upsertConversation(refreshed)
                conv = refreshed
            } else {
                conv = e
            }
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

        // File transfer v2: a file that is still "sending" and that no send of this process owns belongs to an upload the system
        // ended (the app was closed or killed while it ran). It will never finish: show it as failed rather than waiting for ever.
        for stale in store.loadMessages(conversationId: conversationId)
        where FileV2ChatBody.isPending(mime: stale.mediaMimeType) && stale.status == .sending
            && !FileV2OutboundRunner.isInFlight(stale.id) {
            store.updateMessageStatus(id: stale.id, conversationId: conversationId, newStatus: .failed)
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
            // W-MSGOUTBOX (2026-09-01) — a row the outbox drainer gave up
            // on (`ChatOutboxDrain.fail`) arrives here with its id and
            // reason, so the SAME "Riprova" snackbar the live path raises
            // through `markFailed` shows for it. Extracted outside the Task
            // for the same Sendable-capture reason as `peerMatch`.
            let outboxFailedId: UUID? = {
                guard let info = note.userInfo as? [String: Any],
                      let idText = info[ChatOutboxDrain.failedMessageIdKey] as? String else { return nil }
                return UUID(uuidString: idText)
            }()
            let outboxFailureReason: SendFailureReason? = {
                guard let info = note.userInfo as? [String: Any],
                      let raw = info[ChatOutboxDrain.failureReasonKey] as? String else { return nil }
                return SendFailureReason(rawValue: raw)
            }()
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // W83: while the user is looking at this conversation,
                // any inbound message bumped unreadCount on the row.
                // Auto-clear so the badge stays at zero until the user
                // navigates away.
                self.store.markConversationRead(id: self.conversationId)
                self.refreshFromStore()
                if let failedId = outboxFailedId, let reason = outboxFailureReason {
                    self.failedMessageId = failedId
                    self.failureReason = reason
                }
            }
        }
        center.addObserver(forName: AppState.screenshotRequestNotification,
                           object: nil, queue: .main) { note in
            guard let info = note.userInfo as? [String: Any],
                  let from = info["peerUserId"] as? String,
                  from == peerId else { return }
            Task { @MainActor [weak self] in
                self?.incomingScreenshotRequest = true
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
        // WIRE_SPEC 12.7.1: text the user supplies that begins like a file message is refused as an ordinary message; only the
        // file builders of the engine produce such a body.
        guard FileV2ChatBody.isUserTextAllowed(text) else {
            transientNotice = String(localized: "file_v2.text_refused", defaultValue: "Questo testo non può essere inviato come messaggio.", comment: "Shown when the typed text begins like an internal file message and is refused.")
            return
        }

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
           let target = resolveMeshRoute() {
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
            // W-MSGOUTBOX (2026-09-01) — claim the row for this live attempt
            // so `ChatOutboxDrain` (kicked by any WS re-auth in the meantime)
            // never seals and sends the same message a second time while
            // this Task is still in flight. Released in the MainActor tail.
            ChatOutboxDrain.shared.beginLiveSend(clientMsgId: msg.id.uuidString)
            Task { [conversationId, peerUserId, msgId = msg.id, wireText] in
                let outcome = await sender.sendEncryptedDurable(
                    messageId: msgId,
                    conversationId: conversationId,
                    peerUserId: peerUserId,
                    plaintext: wireText
                )
                await MainActor.run {
                    ChatOutboxDrain.shared.endLiveSend(clientMsgId: msgId.uuidString)
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
                    case .queued:
                        // W-MSGOUTBOX — transport failure: a retry entry
                        // (bookkeeping only, no sealed bytes) is in
                        // `chat_outbox`, the row stays `.sending` (clock icon)
                        // and the drainer owns it from here — it re-seals the
                        // row's text at transmit time, re-sends with the same
                        // client_msg_id and only flips to `.failed` past
                        // `OutboxRetryPolicy`'s caps.
                        ChatOutboxDrain.shared.kick(reason: "live-send-queued")
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
                // I8 FIX: encodeAsJsonString()'s `encrypted_payload` field is
                // the raw plaintext bytes in this pre-attach preview stub (no
                // sendService yet) — printing the JSON leaked message content
                // + the full recipient id. Log only a structural summary.
                print("[Chat] would send envelope (no sendService attached): recipient=\(peerUserId.prefix(8))… bytes=\(envelopeJson.utf8.count)")
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
    /// Decide whether this message takes the mesh, and to which device.
    ///
    /// A target armed on the radar still wins outright — picking a device by
    /// hand is a deliberate act and outranks a stored preference in both
    /// directions. Otherwise the contact's own preference decides, which is
    /// what makes "Preferisci Bluetooth" mean anything: before this, a message
    /// went over the mesh only if the user had gone into the sheet and armed a
    /// device, so the default preference could never route a single message.
    ///
    /// Reachable means a live link, not a device a scan happened to see: the
    /// transport writes over links that already exist and never dials one on
    /// demand.
    private func resolveMeshRoute() -> MeshTargetSelection? {
        if let armed = MeshRuntime.shared.activeTarget(for: conversationId.uuidString) {
            return armed
        }
        guard MeshFeature.enabled else { return nil }
        guard let contact = appState?.cachedContacts.first(where: { $0.userId == peerUserId }) else { return nil }
        let nodeHexes = MeshFeature.nodeHexes(forContact: contact)
        guard !nodeHexes.isEmpty else { return nil }
        let preference = MeshRoutingPreferenceStore().preference(for: peerUserId)
        let reachablePeer = MeshRuntime.shared.peers.first { nodeHexes.contains($0.nodeHex) && $0.connected }
        switch meshRoutingDecision(
            preference: preference, armedMeshTarget: false, peerReachableOverMesh: reachablePeer != nil
        ) {
        case .sendOverMesh, .queueForMesh:
            // queueForMesh only arises from "solo Bluetooth": that choice asks
            // for the message to go out over mesh even when the peer isn't
            // reachable right now. sendViaMesh below still attempts an
            // immediate write, but a failed one no longer ends the story —
            // finishMeshSend hands it to MeshOutboxStore, which
            // MeshOutboxDrain retries once the peer is back in range (or
            // gives up past MeshOutboxStore.maxAgeMs). See
            // docs/ble-mesh/IOS_BLE_MESH_DESIGN.md §6.
            //
            // W-MESHUNKNOWN-IOS: prefer the hex a peer is actually
            // advertising right now (a source may have gone stale); fall
            // back to any known hex when none is currently reachable, same
            // as the original single-source behavior for the queued case.
            let targetHex = reachablePeer?.nodeHex ?? nodeHexes.first!
            return MeshTargetSelection(nodeHex: targetHex, displayName: contact.displayName)
        case .sendOverNetwork:
            return nil
        }
    }

    private func sendViaMesh(
        sender: ChatMessageSendService,
        target: MeshTargetSelection,
        messageId: UUID,
        wireText: String
    ) {
        Task { [weak self, conversationId, peerUserId, target, messageId, wireText] in
            guard let self else { return }
            guard let selfId = self.appState?.currentUserId else {
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
                senderNodeHex: MeshRuntime.shared.localNodeIdHex,
                recipientNodeHex: target.nodeHex
            )
            let envelopeText = String(data: envelope.encode(), encoding: .utf8) ?? ""
            // Seal against the public header this packet will travel in, so a
            // relay that re-addresses it produces something undecryptable
            // rather than something misattributed. Android has always sealed
            // mesh traffic this way; on the legacy v2 path this side rebuilt
            // its own AAD instead, and the two could not open each other.
            let aad = await MainActor.run { () -> Data in
                meshPacketAad(
                    version: MeshPacket.wireVersion,
                    typeWireCode: MeshPacketType.data.rawValue,
                    senderId: (try? MeshNodeId(hex: MeshRuntime.shared.localNodeIdHex)) ?? MeshNodeId.broadcast,
                    recipientId: (try? MeshNodeId(hex: target.nodeHex)) ?? MeshNodeId.broadcast
                )
            }
            let outcome = await sender.encryptForWire(
                messageId: messageId, peerUserId: peerUserId, plaintext: envelopeText,
                aadOverride: aad
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
        guard appState?.currentUserId != nil else {
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
            let shellBytes = shell.encode()
            // Built up front, not just on failure: if the immediate write
            // fails, this is exactly the entry MeshOutboxStore needs to
            // retry later — no re-deriving it from a failure callback that
            // only has `delivered: Bool` to work with.
            let pending = MeshPendingSend(
                messageId: messageId.uuidString,
                conversationId: conversationId.uuidString,
                peerUserId: peerUserId,
                targetNodeHex: target.nodeHex,
                sealedShellB64: shellBytes.base64EncodedString(),
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                attempts: 0
            )
            MeshRuntime.shared.sendData(toNodeHex: target.nodeHex, payload: shellBytes) { [weak self] delivered in
                self?.finishMeshSend(delivered: delivered, conversationId: conversationId, messageId: messageId, pending: pending)
            }
        }
    }

    private func finishMeshSend(delivered: Bool, conversationId: UUID, messageId: UUID, pending: MeshPendingSend) {
        if delivered {
            // R4 — mark the row as having gone over the mesh, so the sender's
            // own transcript distinguishes it from a normal network message.
            // The flag, its column and its rendering all existed; nothing on
            // the SEND side ever set it, so the glyph only ever appeared on
            // received messages — while MessageBubble's accessibility label
            // already read "Inviato via mesh Bluetooth", describing a case that
            // could not occur.
            // .sent, not .delivered: the radio accepted the write, which says
            // the bytes left this phone and nothing about whether the other one
            // stored them. The second tick now has its own evidence — the
            // peer's MeshReceipt — and claiming it here would make that receipt
            // decorative.
            store.updateMessageStatus(
                id: messageId, conversationId: conversationId,
                newStatus: .sent, deliveredAt: nil,
                viaMesh: true
            )
        } else {
            // Not a terminal failure: an unreachable/busy target is exactly
            // what MeshOutboxStore exists for. The message stays `.sending`
            // (its status at creation) until MeshOutboxDrain either lands it
            // (`.sent`) or gives up past MeshOutboxStore.maxAgeMs (`.failed`)
            // — see IOS_BLE_MESH_DESIGN.md §6 for the gap this closes.
            MeshOutboxStore.shared.enqueue(pending)
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
        // Delete only this conversation's Message rows from the GRDB
        // store (the UI's real source of truth) — keeps the Conversation
        // row so the chat stays in the list. See `deleteConversation` for
        // the full-conversation counterpart.
        store.deleteMessages(conversationId: conversationId)
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
        // A file message is not text (it cannot be edited), and an edit cannot turn text into one (WIRE_SPEC 12.7.1).
        guard FileV2ChatBody.classify(text: message.plaintext) == .text, FileV2ChatBody.isUserTextAllowed(trimmed) else { return }
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
    /// Encrypts the JSON envelope on the CONTROL channel as the plaintext of
    /// a `msg_send` (server is unaware — sees ciphertext only). Fire-and-
    /// forget; held and retried by `ServiceSendCoordinator` when it cannot go
    /// now, failures log only.
    private func emitControlEnvelope(_ envelope: ChatControlEnvelope) {
        guard let sendService = self.sendService else {
            print("[ChatContainer] emitControlEnvelope: no sendService bound")
            return
        }
        let peerId = peerUserId
        let json: String
        do {
            json = try envelope.toJsonString()
        } catch {
            print("[ChatContainer] envelope serialize failed: \(error)")
            return
        }
        Task { [peerId, json] in
            // 2026-09-19 service-message root fix — a delete/edit/reaction
            // envelope is SERVICE traffic: it rides the CONTROL channel only,
            // is held (bounded queue, flushed in order once a CONTROL session
            // exists) when it cannot go now, and is never sealed on the chat
            // ladder. The receiver consumes it on the 0xE6 path; it never
            // becomes a row. We don't store the envelope locally either.
            _ = await sendService.sendService(
                peerUserId: peerId,
                plaintext: json,
                label: "chat_ctl",
                delivery: .hold
            )
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
              let nodeHex = MeshFeature.nodeHexes(forContact: contact).first else { return }
        var readStamps: [ConversationStore.MessageStatusUpdate] = []
        for msg in meshInbound {
            guard let cid = msg.clientMsgId else { continue }
            appState.sendMeshReceipt(
                toNodeHex: nodeHex, peerUserId: peerId,
                messageClientMsgId: cid, kind: MeshReceipt.kindRead
            )
            // Stamp readAt locally, or the filter above matches the same
            // messages again on the next chat open and the peer receives a
            // fresh read receipt for their whole mesh history every time the
            // screen appears. Collected and written in ONE transaction below
            // instead of one write per message.
            readStamps.append(ConversationStore.MessageStatusUpdate(
                id: msg.id, newStatus: msg.status,
                deliveredAt: msg.deliveredAt, readAt: Date()
            ))
        }
        store.updateMessageStatuses(readStamps)
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
    /// Branched on what the failed row is:
    ///
    ///   - **a file transfer v2 file** (a document, an image, a voice note, a video): one that failed before it had a descriptor is sent
    ///     again from its source (`retryFileV2Send`); one whose descriptor could not be sent sends the same descriptor again, the upload
    ///     is still on the server (`resendFileV2Descriptor`);
    ///   - **an image or a voice note of an older build** (a row with an `image/*` or `audio/*` type and its cached copy): sent again as
    ///     a v2 file from that copy;
    ///   - **text**: composerText repopulated with the original plaintext; the old failed row is removed and `sendMessage()` produces a
    ///     fresh bubble.
    ///
    /// In every branch the OLD failed row is hard-removed (or, for a descriptor, reused) so the chat doesn't show two bubbles for
    /// the same message.
    func retryFailedMessage() {
        guard let id = failedMessageId,
              let msg = store.loadMessages(conversationId: conversationId)
                  .first(where: { $0.id == id })
        else { return }
        // Clear failure flags so the snackbar dismisses.
        failedMessageId = nil
        failureReason = nil
        failureDetail = nil

        // File transfer v2: a file that failed before it had a descriptor starts again from its source; one that failed
        // after (the descriptor could not be sent) sends the same descriptor again, the upload is still on the server.
        if FileV2ChatBody.isPending(mime: msg.mediaMimeType) {
            retryFileV2Send(msg)
            return
        }
        if msg.direction == .outgoing, case .file = FileV2ChatBody.classify(text: msg.plaintext) {
            resendFileV2Descriptor(msg)
            return
        }

        let mime = msg.mediaMimeType ?? ""

        if mime.hasPrefix("audio/") || mime.hasPrefix("image/"),
           let path = msg.mediaLocalPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            // A row of an older build: the cached copy is sent again, as a v2 file.
            store.removeMessage(id: id, conversationId: conversationId)
            refreshFromStore()
            let kind = mime.hasPrefix("audio/") ? "voice" : "image"
            let url = URL(fileURLWithPath: path)
            let durationMs = msg.mediaDurationMs
            let exportBlocked = msg.exportBlocked ?? false
            Task { [weak self] in
                await self?.resendPreparedFile(kind: kind, url: url, durationMs: durationMs, key: UUID(), exportBlocked: exportBlocked)
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
        failureDetail = nil
    }

    func clearTransientNotice() {
        transientNotice = nil
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
        // A forwarded file is a NEW file (WIRE_SPEC 12.2: a key is never reused), which this version does not do: never forward the
        // descriptor itself, it carries the key of the original.
        guard FileV2ChatBody.classify(text: text) == .text, !FileV2ChatBody.isPending(mime: message.mediaMimeType) else {
            transientNotice = String(localized: "file_v2.forward_unavailable", defaultValue: "Gli allegati non si possono inoltrare in questa versione.", comment: "Shown when the user tries to forward a file message.")
            return
        }
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

    // MARK: - Files (file transfer v2): documents, images, voice notes, videos

    /// Sends a document picked with the document picker in this 1:1 chat, in the file transfer v2 format (WIRE_SPEC section 12):
    /// AES-256-GCM chunks uploaded to the server in parts, and the key, the header and the download token travelling in the
    /// descriptor that is the body of an ordinary end-to-end encrypted chat message. The file is streamed from disk (its size is
    /// not held in memory), up to 5 GiB.
    ///
    /// Nothing is shown or created when the file cannot be sent at all (empty, unreadable, above 5 GiB, or no encrypted channel
    /// to the contact yet): the failure is returned and the caller tells the user. Otherwise a row with the file's name appears at
    /// once, its bubble shows the upload progress, and when the descriptor has been handed to the chat the row IS that message
    /// (the outbox re-sends it like any text); if anything fails the row turns to the failed state with the reason and a retry.
    ///
    /// - Parameter overrideTimerSeconds: per-attachment timer chosen in the pre-send dialog (`nil` = the conversation default;
    ///   -1 view once, N seconds); it becomes the descriptor's `ex`.
    /// - Parameter exportBlocked: export-permission choice from the pre-send dialog; `true` becomes the descriptor's `xp: 0`.
    /// - Returns: `nil` when the send started; the failure that says why it did not otherwise.
    @discardableResult
    func sendFileAttachment(url: URL, overrideTimerSeconds: Int? = nil, exportBlocked: Bool = false) -> FileV2Failure? {
        // Security-scoped access for files outside the app sandbox, held for the whole send (the pipeline reads the file again for
        // every part) and released when it ends.
        let scoped = url.startAccessingSecurityScopedResource()
        let scopedURL: URL? = scoped ? url : nil
        if case .failure(let failure) = FileV2AppServices.sendableSize(of: url) {
            scopedURL?.stopAccessingSecurityScopedResource()
            return failure
        }
        // A picture picked as a file is still a picture: it is sent as an image, from a copy without its location and device data
        // (never as the file the user picked, which holds them). The copy is the app's own, so the picked file is not needed after it.
        if FileV2ImageCleaner.isPicture(at: url) {
            defer { scopedURL?.stopAccessingSecurityScopedResource() }
            return sendPickedPicture(url: url, overrideTimerSeconds: overrideTimerSeconds, exportBlocked: exportBlocked)
        }
        // The name that is shown is cut to one safe line; the descriptor carries the picked name (the engine cuts it to 255 bytes).
        let pickedName = url.lastPathComponent
        let prepared = FileV2MediaPreparer.Prepared(
            kind: .file, sourceURL: url, name: pickedName, mimeType: FileV2AppServices.mimeType(for: url), media: nil,
            preview: nil, thumbnailURL: nil, durationMs: nil)
        let displayText = FileV2ChatBody.glyph + FileV2LocalName.sanitised(pickedName)
        let msgId = UUID()
        let started = startMediaSend(prepared, msgId: msgId, displayText: displayText, overrideTimerSeconds: overrideTimerSeconds,
                                     exportBlocked: exportBlocked, keepsLocalCopy: false, scoped: scopedURL)
        if started == nil {
            fileV2Retry[msgId] = FileV2RetrySource(url: url, overrideTimerSeconds: overrideTimerSeconds, exportBlocked: exportBlocked)
        }
        return started
    }

    /// A picture picked as a file, sent as a v2 image from its cleaned copy (`FileV2MediaPreparer.prepareImage(fileURL:...)`): no
    /// location, no device data, the picked file is only read. A picture that cannot be cleaned is refused with `imageNotCleanable`:
    /// it is never sent as the picked file. A failure to start the send is told by `startPreparedMedia`.
    private func sendPickedPicture(url: URL, overrideTimerSeconds: Int?, exportBlocked: Bool) -> FileV2Failure? {
        let msgId = UUID()
        let prepared: FileV2MediaPreparer.Prepared
        do {
            prepared = try FileV2MediaPreparer.prepareImage(fileURL: url, key: msgId.uuidString, pickedName: url.lastPathComponent)
        } catch {
            let refusal = error as? FileV2MediaPreparer.PrepareError
            RTLog.warn("chat", "filev2 picked picture refused code=\(refusal?.code ?? "unknown")")
            return refusal?.failure ?? FileV2Failure(.unreadable)
        }
        _ = startPreparedMedia(prepared, msgId: msgId, overrideTimerSeconds: overrideTimerSeconds, exportBlocked: exportBlocked)
        return nil
    }

    /// Sends a photo (any format the device decodes) in this 1:1 chat as a v2 image from a CLEANED COPY (no location, no device data:
    /// `FileV2ImageCleaner`), within 2048 px and 10 MB, with a thumbnail and a tiny preview. Nothing is created when the bytes are not
    /// a picture that can be cleaned or the result is above 10 MB, or when the chat cannot seal a message for the contact yet.
    /// - Returns: `false` when the image was rejected before any local echo was created; `true` once a row was appended and the
    ///   send started.
    @discardableResult
    func sendImage(_ rawImageData: Data, overrideTimerSeconds: Int? = nil, exportBlocked: Bool = false) -> Bool {
        let msgId = UUID()
        let prepared: FileV2MediaPreparer.Prepared
        do {
            prepared = try FileV2MediaPreparer.prepareImage(rawData: rawImageData, key: msgId.uuidString)
        } catch {
            RTLog.warn("chat", "filev2 image prepare failed code=\((error as? FileV2MediaPreparer.PrepareError)?.code ?? "unknown")")
            return false
        }
        return startPreparedMedia(prepared, msgId: msgId, overrideTimerSeconds: overrideTimerSeconds, exportBlocked: exportBlocked)
    }

    /// Sends a recorded voice note in this 1:1 chat as a v2 voice file with its duration.
    func sendVoiceNote(_ recording: VoiceNoteRecorder.Recording, overrideTimerSeconds: Int? = nil, exportBlocked: Bool = false) {
        let msgId = UUID()
        let prepared: FileV2MediaPreparer.Prepared
        do {
            prepared = try FileV2MediaPreparer.prepareVoice(recording: recording, key: msgId.uuidString)
        } catch {
            transientNotice = FileV2FailureText.message(for: FileV2Failure(.unreadable))
            return
        }
        // The temporary recording is not needed any more: the row keeps its own copy.
        try? FileManager.default.removeItem(at: recording.fileURL)
        _ = startPreparedMedia(prepared, msgId: msgId, overrideTimerSeconds: overrideTimerSeconds, exportBlocked: exportBlocked)
    }

    /// Sends a video file (a copy the app owns, for instance the one the picker handed over) in this 1:1 chat as a v2 video with a
    /// thumbnail, its dimensions and its duration. A video is never fetched without a tap by the receiver, so it cannot be sent as
    /// "view once". The file is moved into the app's caches directory.
    /// - Returns: `nil` when the send started; the failure that says why it did not otherwise.
    @discardableResult
    func sendVideo(url: URL, overrideTimerSeconds: Int? = nil, exportBlocked: Bool = false) async -> FileV2Failure? {
        if case .failure(let failure) = FileV2AppServices.sendableSize(of: url) {
            try? FileManager.default.removeItem(at: url)
            return failure
        }
        // Refused before the file is moved: a video is fetched on a tap, so it cannot be "view once".
        let effectiveTimer = AttachmentTimerResolver.resolve(
            overrideSeconds: overrideTimerSeconds,
            conversationDefault: viewModel.conversation.ephemeralTimerSeconds)
        if effectiveTimer == -1 {
            try? FileManager.default.removeItem(at: url)
            return FileV2Failure(.viewOnceUnsupported)
        }
        let msgId = UUID()
        let prepared: FileV2MediaPreparer.Prepared
        do {
            prepared = try await FileV2MediaPreparer.prepareVideo(sourceURL: url, key: msgId.uuidString)
        } catch {
            return FileV2Failure(.unreadable)
        }
        let failure = startMediaSend(prepared, msgId: msgId, displayText: FileV2ChatBody.kindLabelText(.video),
                                     overrideTimerSeconds: overrideTimerSeconds, exportBlocked: exportBlocked,
                                     keepsLocalCopy: true, scoped: nil)
        if failure != nil { discardPrepared(msgId: msgId) }
        return failure
    }

    /// What a send that did not start leaves behind in the row's directory of the caches directory: the thumbnail and, for a video, the
    /// copy of the file. (The copy of an image or a voice note is kept: it is also what a retry sends again.)
    private func discardPrepared(msgId: UUID) {
        try? FileManager.default.removeItem(
            at: FileV2LocalFiles.directory(base: FileV2DownloadCenter.cachesBase, rowKey: msgId.uuidString))
    }

    /// The common tail of an image or a voice note: the row, the progress and the run. A failure to start is told to the user.
    private func startPreparedMedia(_ prepared: FileV2MediaPreparer.Prepared, msgId: UUID, overrideTimerSeconds: Int?,
                                    exportBlocked: Bool, discardsOnFailure: Bool = true) -> Bool {
        let label: String
        switch prepared.kind {
        case .voice: label = FileV2ChatBody.kindLabelText(.voice)
        case .video: label = FileV2ChatBody.kindLabelText(.video)
        default: label = FileV2ChatBody.kindLabelText(.image)
        }
        if let failure = startMediaSend(prepared, msgId: msgId, displayText: label, overrideTimerSeconds: overrideTimerSeconds,
                                        exportBlocked: exportBlocked, keepsLocalCopy: true, scoped: nil) {
            transientNotice = FileV2FailureText.message(for: failure)
            // A retry keeps what it was asked to send again (the copy of a video lives in the row's directory).
            if discardsOnFailure { discardPrepared(msgId: msgId) }
            return false
        }
        return true
    }

    /// Starts the send of a prepared file: refuses what cannot be sent (a document or a video as "view once", a contact the chat cannot
    /// seal a message for), shows the row, and runs the upload in the background. The row shows `displayText` until the descriptor
    /// exists; `keepsLocalCopy` records the file the sender's own bubble shows in the row (`mediaLocalPath`).
    /// - Returns: `nil` when the send started; the failure that says why it did not otherwise.
    private func startMediaSend(_ prepared: FileV2MediaPreparer.Prepared, msgId: UUID, displayText: String,
                                overrideTimerSeconds: Int?, exportBlocked: Bool, keepsLocalCopy: Bool,
                                scoped: URL?) -> FileV2Failure? {
        guard let sendService = self.sendService, let appState = self.appState else {
            // Preview / unit-test fallback: no backend to send with.
            scoped?.stopAccessingSecurityScopedResource()
            return nil
        }
        // "View once" (-1) would remove the receiver's row seconds after the reveal tap, before a document or a video (which the
        // receiver fetches on a tap) could download: refused, not broken. An image and a voice note are fetched on arrival.
        let effectiveTimer = AttachmentTimerResolver.resolve(
            overrideSeconds: overrideTimerSeconds,
            conversationDefault: viewModel.conversation.ephemeralTimerSeconds)
        let kind = prepared.kind
        if effectiveTimer == -1 && (kind == .file || kind == .video) {
            scoped?.stopAccessingSecurityScopedResource()
            return FileV2Failure(.viewOnceUnsupported)
        }
        // The descriptor is a TEXT message: if the channel cannot seal one for this contact now, nothing is uploaded for it.
        guard sendService.canSendText(peerUserId: peerUserId) else {
            scoped?.stopAccessingSecurityScopedResource()
            return FileV2Failure(.noSecureChannel)
        }

        let peerId = peerUserId
        let convId = conversationId
        // W447: resolve this send's effective timer (override wins over conversation default) and stamp the local echo.
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
            mediaLocalPath: keepsLocalCopy ? prepared.sourceURL.path : nil,
            mediaDurationMs: prepared.durationMs,
            mediaMimeType: FileV2ChatBody.pendingMime(kind: kind.rawValue),
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
        uploadProgress[msgId] = 0
        refreshFromStore()
        if prepared.thumbnailURL != nil { FileV2DownloadCenter.shared.markThumbnailReady(msgId.uuidString) }

        // The descriptor's own timer: the pre-send choice, else the conversation default (N seconds, nothing when 0).
        let timerValue: Int64? = effectiveTimer.flatMap { (seconds: Int) -> Int64? in seconds == 0 ? nil : Int64(seconds) }
        let context = FileV2OutboundRunner.Context(
            messageId: msgId, conversationId: convId, peerUserId: peerId, displayText: displayText,
            pendingMime: FileV2ChatBody.pendingMime(kind: kind.rawValue), kind: kind, sourceURL: prepared.sourceURL,
            name: prepared.name, mimeType: prepared.mimeType, media: prepared.media, preview: prepared.preview,
            thumbnailURL: prepared.thumbnailURL, ex: timerValue, xp: exportBlocked ? 0 : nil)
        Task { [weak self] in
            await BackgroundUploadTask.run(name: "file-v2-upload") {
                let failure = await FileV2OutboundRunner.run(
                    context, sendService: sendService, appState: appState,
                    onProgress: { done, total in
                        self?.updateUploadProgress(messageId: msgId, bytesUploaded: done, totalBytes: total)
                    })
                scoped?.stopAccessingSecurityScopedResource()
                if failure != nil {
                    // Recorded in the store even when the screen is gone, so the row never stays "sending" for ever.
                    ConversationStore().updateMessageStatus(id: msgId, conversationId: convId, newStatus: .failed)
                }
                self?.finishFileV2Send(messageId: msgId, failure: failure)
            }
        }
        return nil
    }

    /// The end of a file send, on the main actor: clears the progress and, on a failure, shows why and offers the retry.
    private func finishFileV2Send(messageId: UUID, failure: FileV2Failure?) {
        clearUploadProgress(messageId: messageId)
        guard let failure else {
            fileV2Retry.removeValue(forKey: messageId)
            refreshFromStore()
            return
        }
        RTLog.warn("chat", "filev2 send failed code=\(failure.code)")
        failureDetail = FileV2FailureText.message(for: failure)
        markFailed(messageId: messageId, reason: .fileTransfer)
    }

    /// "Riprova" on a file that failed before it had a descriptor: the row goes, and the file is sent again as a new message. A
    /// document is sent again from the picked file (the app keeps no copy: if it was closed in between, the user attaches the file
    /// again); an image, a voice note and a video are sent again from the copy the row keeps in the caches directory.
    private func retryFileV2Send(_ msg: Message) {
        let kind = FileV2ChatBody.pendingKind(mime: msg.mediaMimeType)
        let localPath = msg.mediaLocalPath
        let durationMs = msg.mediaDurationMs
        let exportBlocked = msg.exportBlocked ?? false
        store.removeMessage(id: msg.id, conversationId: conversationId)
        let source = fileV2Retry.removeValue(forKey: msg.id)
        refreshFromStore()
        let goneText = String(localized: "file_v2.retry_source_gone", defaultValue: "Il file non è più disponibile: allegalo di nuovo.", comment: "Shown when a failed file cannot be retried because the app no longer has the picked file.")
        if kind == "file" {
            guard let source else {
                transientNotice = goneText
                return
            }
            if let failure = sendFileAttachment(url: source.url, overrideTimerSeconds: source.overrideTimerSeconds,
                                                exportBlocked: source.exportBlocked) {
                transientNotice = FileV2FailureText.message(for: failure)
            }
            return
        }
        guard let localPath, FileManager.default.fileExists(atPath: localPath) else {
            transientNotice = goneText
            return
        }
        let url = URL(fileURLWithPath: localPath)
        // The row never had a descriptor, so nothing was announced under its id: the new row takes it, and the copy of the file and
        // the thumbnail stay where the row's other files are.
        let rowId = msg.id
        Task { [weak self] in
            await self?.resendPreparedFile(kind: kind, url: url, durationMs: durationMs, key: rowId, exportBlocked: exportBlocked)
        }
    }

    /// The retry of an image, a voice note or a video from its copy in the caches directory: the pieces (dimensions, preview,
    /// thumbnail) are made again and a new row is sent.
    private func resendPreparedFile(kind: String, url: URL, durationMs: Int64?, key: UUID, exportBlocked: Bool) async {
        let prepared: FileV2MediaPreparer.Prepared
        do {
            switch kind {
            case "voice":
                prepared = FileV2MediaPreparer.describeVoice(fileURL: url, durationMs: durationMs ?? 0, mimeType: "audio/mp4")
            case "video":
                prepared = try await FileV2MediaPreparer.describeVideo(fileURL: url, key: key.uuidString)
            default:
                prepared = try FileV2MediaPreparer.describeImage(fileURL: url, key: key.uuidString)
            }
        } catch {
            transientNotice = FileV2FailureText.message(for: FileV2Failure(.unreadable))
            return
        }
        _ = startPreparedMedia(prepared, msgId: key, overrideTimerSeconds: nil, exportBlocked: exportBlocked,
                               discardsOnFailure: false)
    }

    /// "Riprova" on a file whose descriptor could not be sent: the same message again (same row, same id), the file is still on
    /// the server. It goes through the durable text send, exactly like any text.
    private func resendFileV2Descriptor(_ msg: Message) {
        guard let sendService = self.sendService else { return }
        let convId = conversationId
        let peerId = peerUserId
        let msgId = msg.id
        let body = msg.plaintext
        store.updateMessageStatus(id: msgId, conversationId: convId, newStatus: .sending)
        refreshFromStore()
        ChatOutboxDrain.shared.beginLiveSend(clientMsgId: msgId.uuidString)
        Task { [weak self] in
            let outcome = await sendService.sendEncryptedDurable(
                messageId: msgId, conversationId: convId, peerUserId: peerId, plaintext: body)
            ChatOutboxDrain.shared.endLiveSend(clientMsgId: msgId.uuidString)
            let store = ConversationStore()
            switch outcome {
            case .delivered(let serverMessageId):
                store.setServerMessageId(localId: msgId, conversationId: convId, serverMessageId: serverMessageId)
                store.updateMessageStatus(id: msgId, conversationId: convId, newStatus: .delivered, deliveredAt: Date())
            case .queued:
                ChatOutboxDrain.shared.kick(reason: "file-v2-resend")
            case .failed(let reason):
                store.updateMessageStatus(id: msgId, conversationId: convId, newStatus: .failed)
                self?.markFailed(messageId: msgId, reason: reason)
            }
            self?.refreshFromStore()
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
            payload: "{\"qa_ctl\":1,\"t\":\"ss_req\",\"ts\":\(Int64(Date().timeIntervalSince1970))}"
        )
    }

    /// Approve an incoming screenshot-request from the peer. Mutual
    /// unlock (Android: "Request peer to mutually unlock screenshots for
    /// this session") — approving lifts the lock on THIS device too, not
    /// just the requester's, matching ChatDetailViewModel.onApproveScreenshotRequest
    /// (`screenshotBlocked = false` set locally, in addition to the wire ss_resp).
    func grantScreenshotPermission() {
        store.setScreenshotGranted(conversationId: conversationId, granted: true)
        incomingScreenshotRequest = false
        sendControlEnvelope(
            payload: "{\"qa_ctl\":1,\"t\":\"ss_resp\",\"approved\":true,\"ts\":\(Int64(Date().timeIntervalSince1970))}"
        )
        refreshFromStore()
    }

    /// Deny an incoming screenshot-request from the peer.
    /// Android: ChatDetailViewModel.onDenyScreenshotRequest.
    func denyScreenshotRequest() {
        incomingScreenshotRequest = false
        sendControlEnvelope(
            payload: "{\"qa_ctl\":1,\"t\":\"ss_resp\",\"approved\":false,\"ts\":\(Int64(Date().timeIntervalSince1970))}"
        )
    }

    /// Re-lock screenshots in this conversation.
    /// Android: ChatControlEnvelope TYPE_SCREENSHOT_LOCK = "ss_lock"
    func revokeScreenshotPermission() {
        store.setScreenshotGranted(conversationId: conversationId, granted: false)
        sendControlEnvelope(
            payload: "{\"qa_ctl\":1,\"t\":\"ss_lock\",\"ts\":\(Int64(Date().timeIntervalSince1970))}"
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
        sendControlEnvelope(payload: payload)
    }

    // MARK: - Private helper

    /// Ship a `qa_ctl:1` conversation-level control envelope (ss_req /
    /// ss_resp / ss_lock / ephemeral_timer) over the wire only.
    /// Android parity fix (2026-08-13): `SendMessageUseCase.sendScreenshotRequest`
    /// /`sendScreenshotResponse`/`sendEphemeralTimerControl` call `shipControl`
    /// directly — never `messageDao` — so nothing is persisted locally and no
    /// row ever appears in the sender's own chat history. This used to
    /// `store.appendMessage` the RAW JSON payload as an outgoing message row,
    /// which the bubble list rendered verbatim (no qa_ctl filtering on the
    /// outgoing path) — a garbled "{"qa_ctl":1,...}" bubble that persisted
    /// forever in the sender's own chat, exactly the "manda un messaggio
    /// cifrato sulla chat e rimane lì" the user reported.
    private func sendControlEnvelope(payload: String) {
        guard let sender = sendService else { return }
        Task { [peerUserId = peerUserId] in
            // 2026-09-19 service-message root fix — screenshot-lock and
            // ephemeral-timer envelopes are SERVICE traffic: CONTROL only,
            // held until a CONTROL session exists, never on the chat ladder.
            _ = await sender.sendService(peerUserId: peerUserId,
                                         plaintext: payload,
                                         label: "conv_ctl",
                                         delivery: .hold)
        }
    }
}
