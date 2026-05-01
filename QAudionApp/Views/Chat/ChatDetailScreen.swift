import SwiftUI
import PhotosUI
import QAudionEngine

/// Chat detail (conversation) screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-chat/.../detail/ChatDetailScreen.kt`.
///
/// Layout (top → bottom):
///   1. **Top bar** — back chevron + 36pt avatar + display name + presence
///                    label + `PqcBadge` + audio call + video call + ⋯
///   2. **SessionStatusStrip** — confidence dot, presence label, C=0.NN,
///                                MiniSpark, RE-KEY countdown.
///   3. **Message list** — `LazyVStack` with day headers, `MessageBubble`
///                          per item (Sent/Received/Admin), reactions,
///                          reply quote, voice notes, system banners.
///                          Below the last message, a `TypingIndicator`
///                          row + "{peer} sta scrivendo…" appears when
///                          `isPeerTyping == true`.
///   4. **Composer** — `MessageComposer` with edit / reply banners.
///
/// Data layer reuses the existing `ChatContainer` (no engine API change).
/// Fields not yet provided by the engine — `confidence`, `presenceLabel`,
/// `rekeyInSeconds`, `pqcActive`, `reactions`, `replyQuote`, `voiceNote`,
/// `editingTarget` — are local UI state for now and will be wired up in
/// follow-up waves once the engine surfaces them.
struct ChatDetailScreen: View {
    @StateObject private var container: ChatContainer
    @EnvironmentObject private var appState: AppState

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qaudionSnackbar) private var snackbar

    // MARK: - Local UI state (until engine exposes these fields)

    @State private var replyTarget: MessageComposer.ReplyTarget? = nil
    @State private var editingTarget: MessageComposer.EditingTarget? = nil
    @State private var actionTargetId: UUID? = nil
    /// W72: voice-note recorder. One instance per screen; the composer
    /// drives start/stop/cancel via the existing callbacks. The captured
    /// .m4a is appended to the local conversation as an attachment
    /// preview so the user sees the message land — full upload + send
    /// over WS is engine-side WT (file_attach envelope wiring).
    @StateObject private var voiceNoteRecorder = VoiceNoteRecorder()
    /// W59: PhotosPicker integration. `attachmentPickerItem` non-nil dopo
    /// la selezione utente; trigger snackbar feedback (engine wire per
    /// l'invio reale di image attachment è deferred — `ChatContainer
    /// .sendAttachment(image:)` non esiste ancora).
    @State private var showingPhotoPicker: Bool = false
    @State private var attachmentPickerItem: PhotosPickerItem? = nil
    /// W91: multi-select photo picker. Up to 10 photos at a time —
    /// PhotosPicker handles the system UI; iteration of the selection
    /// fans out to ChatContainer.sendImage one at a time so each
    /// upload + qfile marker is independent.
    @State private var multiPickerItems: [PhotosPickerItem] = []
    /// W85: confirmationDialog gate for the paperclip button. Tap →
    /// dialog with two options: "Galleria" (PhotosPicker) or "Camera"
    /// (UIImagePickerController via CameraPicker). Cleaner than two
    /// separate buttons in the composer row.
    @State private var showAttachmentChoice: Bool = false
    @State private var showCameraPicker: Bool = false

    // Stub values for the SessionStatusStrip until the engine wires them.
    private let stubConfidence: Double = 0.92
    private let stubPresenceLabel: String = "VOCE VERIFICATA"
    private let stubRekeyInSeconds: Int? = 252
    private let stubPqcActive: Bool = true
    private let stubSamples: [Float] = [0.84, 0.86, 0.89, 0.91, 0.92, 0.92, 0.93, 0.92]

    // MARK: - Init

    init(conversationId: UUID, peerUserId: String, peerDisplayName: String) {
        _container = StateObject(wrappedValue: ChatContainer(
            conversationId: conversationId,
            peerUserId: peerUserId,
            peerDisplayName: peerDisplayName
        ))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            SessionStatusStrip(
                confidence: stubConfidence,
                presence: stubPresenceLabel,
                recentSamples: stubSamples,
                rekeyInSeconds: stubRekeyInSeconds
            )
            messageList
            MessageComposer(
                text: Binding(
                    get: { container.composerText },
                    set: { newValue in
                        let wasEmpty = container.composerText.isEmpty
                        container.composerText = newValue
                        // W101: typing indicator emit. Empty→non-empty
                        // fires `is_typing=true`; non-empty→empty fires
                        // `is_typing=false` immediately. Steady-state
                        // typing rolls the 3s auto-stop timer.
                        if !newValue.isEmpty {
                            container.notifyComposerInput()
                        } else if !wasEmpty {
                            container.notifyComposerCleared()
                        }
                    }
                ),
                editingTarget: editingTarget,
                replyTarget: replyTarget,
                // W108: live elapsed-seconds counter for the recording
                // banner. Recorder publishes elapsedSeconds via a 0.25s
                // timer; passing through here is enough — SwiftUI binds
                // the @ObservedObject so the row updates automatically.
                recordingElapsedSeconds: voiceNoteRecorder.elapsedSeconds,
                onAttach: { showAttachmentChoice = true },
                onSend: handleSend,
                onCancelEdit: { editingTarget = nil },
                onCancelReply: { replyTarget = nil },
                onStartVoiceNote: {
                    // W72: real AVAudioRecorder start. Mic permission is
                    // requested inline; failures land in container's
                    // failure flag (.networkError fallback for "session
                    // failure" since mic-permission is a setup error,
                    // not a wire failure).
                    Task {
                        do {
                            try await voiceNoteRecorder.start()
                        } catch VoiceNoteRecorder.RecorderError.permissionDenied {
                            container.markFailed(messageId: UUID(), reason: .generic)
                        } catch {
                            print("[VoiceNote] start failed: \(error.localizedDescription)")
                        }
                    }
                },
                onFinishVoiceNote: {
                    // W79: real upload+send pipeline. ChatContainer.sendVoiceNote
                    // orchestrates the whole flow: read tmp M4A, encrypt+upload
                    // via FileTransfer (HKDF-SHA256 + AES-256-GCM), mint a
                    // recipient capability token, build a qfile v3 marker, and
                    // ship it as the plaintext of a regular msg_send. Local
                    // conversation row carries a friendly "🎤 Nota vocale (X.Ys)"
                    // placeholder so the user sees a recognizable bubble.
                    if let rec = voiceNoteRecorder.stop() {
                        print("[VoiceNote] captured \(rec.fileURL.lastPathComponent) duration \(rec.durationMs)ms (\(rec.mimeType))")
                        container.sendVoiceNote(rec)
                    }
                },
                onCancelVoiceNote: {
                    // W72: stop + delete tmp file.
                    voiceNoteRecorder.cancel()
                }
            )
        }
        .background(scheme.background)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // W38: send-failure feedback. Quando il container marca un
        // messaggio fallito (engine pipeline wires `markFailed` su
        // crypto/network error), pushiamo una snackbar error con bottone
        // "Riprova" che chiama back nel container per ri-eseguire la
        // pipeline. La copy è derivata dal reason code (1:1 mapping
        // con Android `SendMessageUseCase.Outcome.Failed`).
        .onChange(of: container.failedMessageId) { newId in
            guard newId != nil, let reason = container.failureReason else { return }
            snackbar?.show(.init(
                text: "Messaggio non inviato — \(reason.localizedDescription)",
                severity: .error,
                actionLabel: "Riprova",
                onAction: { container.retryFailedMessage() },
                durationSeconds: 6
            ))
        }
        // W59: PhotosPicker per image attachment. Usa il system out-of-
        // process picker (no NSPhotoLibraryUsageDescription required,
        // no permission prompt). Engine wire per encrypt+upload+send
        // resta deferred — sull'item picked, mostra snackbar info.
        // W85: pick library vs camera. Tapping the paperclip in the
        // composer fires `showAttachmentChoice = true` (set in
        // `onAttach`); the user then routes to either PhotosPicker
        // (system out-of-process picker, no NSPhotoLibraryUsageDescription
        // needed) or CameraPicker (UIImagePickerController, requires
        // NSCameraUsageDescription which is already declared).
        .confirmationDialog("Aggiungi allegato",
                            isPresented: $showAttachmentChoice,
                            titleVisibility: .visible) {
            Button {
                showCameraPicker = true
            } label: {
                Label("Scatta foto", systemImage: "camera")
            }
            Button {
                showingPhotoPicker = true
            } label: {
                Label("Galleria", systemImage: "photo.on.rectangle")
            }
            // W103: paste from clipboard. Only enabled when the
            // pasteboard has an image available — UIPasteboard.general
            // .hasImages is checked at button press time. If user
            // copied a screenshot or shared photo in another app,
            // this is the fastest way to drop it into the chat.
            if UIPasteboard.general.hasImages {
                Button {
                    if let img = UIPasteboard.general.image,
                       let data = img.jpegData(compressionQuality: 1.0) {
                        container.sendImage(data)
                    } else {
                        snackbar?.show(.init(
                            text: "Nessuna immagine valida negli appunti.",
                            severity: .warning, durationSeconds: 3))
                    }
                } label: {
                    Label("Incolla immagine", systemImage: "doc.on.clipboard")
                }
            }
            Button("Annulla", role: .cancel) { }
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraPicker(
                onCapture: { data in
                    container.sendImage(data)
                    showCameraPicker = false
                },
                onCancel: {
                    showCameraPicker = false
                }
            )
            .ignoresSafeArea()
        }
        // W91: multi-select photo picker (up to 10). When the user
        // selects multiple, we fan out one ChatContainer.sendImage per
        // item so each upload + qfile marker is independent and the
        // chat shows N bubbles.
        .photosPicker(isPresented: $showingPhotoPicker,
                      selection: $multiPickerItems,
                      maxSelectionCount: 10,
                      matching: .images)
        .onChange(of: multiPickerItems) { newItems in
            // W91: fan out one sendImage per picked item. Each one
            // goes through the same EXIF-strip + 2048px + 10MB cap
            // pipeline + qfile marker. Sequential await rather than
            // parallel TaskGroup keeps the WS msg_send order stable
            // (chat shows them in selection order, not random).
            guard !newItems.isEmpty else { return }
            let items = newItems
            multiPickerItems = []
            Task {
                var failures = 0
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run { container.sendImage(data) }
                    } else {
                        failures += 1
                    }
                }
                if failures > 0 {
                    await MainActor.run {
                        snackbar?.show(.init(
                            text: "\(failures) foto su \(items.count) non leggibili.",
                            severity: .warning,
                            durationSeconds: 3))
                    }
                }
            }
        }
        .sheet(item: actionSheetBinding) { msgIdWrapper in
            BubbleActionSheet(
                isOwn: messageIsOwn(msgIdWrapper.id),
                isText: true,  // all messages are text in current model
                onReact: { emoji in
                    // W87: toggle a qa_ctl:1 reaction. ChatContainer
                    // applies the local toggle immediately + emits the
                    // envelope to the peer. Toggle semantics — second
                    // tap with the same emoji removes the reaction.
                    if let target = container.viewModel.messages
                        .first(where: { $0.id == msgIdWrapper.id }) {
                        container.toggleReaction(target, emoji: emoji)
                    }
                },
                onEdit: { startEdit(messageId: msgIdWrapper.id) },
                onCopy: {
                    copyMessage(messageId: msgIdWrapper.id)
                    snackbar?.show(.init(
                        text: "Testo copiato negli appunti.",
                        severity: .info,
                        durationSeconds: 2
                    ))
                },
                onDeleteForAll: {
                    // W86: ship a qa_ctl:1 t="delete" envelope. Container
                    // applies the local tombstone immediately + sends the
                    // envelope to the peer. Spoof check on the receiver
                    // ensures only the original sender can delete.
                    if let target = container.viewModel.messages
                        .first(where: { $0.id == msgIdWrapper.id }) {
                        container.deleteMessage(target)
                        snackbar?.show(.init(
                            text: "Messaggio eliminato per tutti.",
                            severity: .info,
                            durationSeconds: 2
                        ))
                    }
                },
                onDeleteForMe: {
                    // TODO(engine): delete-local da ConversationStore.
                    snackbar?.show(.init(
                        text: "Messaggio eliminato per te.",
                        severity: .info,
                        durationSeconds: 3
                    ))
                }
            )
            // iOS 16.0 deployment target: `.medium` is the only detent
            // available; `.height(_:)` and `.presentationDragIndicator`
            // both require iOS 16.4+. The .medium detent gives roughly
            // half the screen, which is plenty for the 6-emoji row +
            // up to 4 action rows.
            .presentationDetents([.medium])
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Indietro")

            QAudionAvatar(
                displayName: container.viewModel.conversation.peerDisplayName,
                kind: container.viewModel.conversation.kind == .group ? .group : .person,
                size: 36,
                // W72: prefer live presence from engine, fall back to model.
                presenceDot: appState.presenceService.isOnline(
                    container.viewModel.conversation.peerUserId
                ) ? .online :
                  (appState.presenceService.status(for: container.viewModel.conversation.peerUserId) == .offline
                   ? .offline
                   : (container.viewModel.isPeerOnline ? .online : .offline))
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(container.viewModel.conversation.peerDisplayName)
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                Text(presenceLine)
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.0)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            PqcBadge(active: stubPqcActive)

            Button(action: startAudioCall) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 36, height: 36)
            }
            .disabled(container.viewModel.conversation.kind == .group)
            .accessibilityLabel("Chiamata audio")

            Button(action: startVideoCall) {
                Image(systemName: "video.fill")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 36, height: 36)
            }
            .disabled(container.viewModel.conversation.kind == .group)
            .accessibilityLabel("Chiamata video")

            // W93: overflow menu — clear chat history + block / unblock
            // contact. The local-store wipe is immediate; block / unblock
            // hits ContactsApi.blockContact via the persistent backend.
            Menu {
                Button(role: .destructive) {
                    container.clearLocalHistory()
                    snackbar?.show(.init(
                        text: "Cronologia locale cancellata.",
                        severity: .info,
                        durationSeconds: 2))
                } label: {
                    Label("Svuota cronologia", systemImage: "tray")
                }
                Button(role: .destructive) {
                    Task {
                        let ok = await container.toggleBlock(appState: appState)
                        await MainActor.run {
                            snackbar?.show(.init(
                                text: ok ? "Contatto bloccato." : "Operazione fallita.",
                                severity: ok ? .info : .error,
                                durationSeconds: 2))
                        }
                    }
                } label: {
                    Label("Blocca contatto", systemImage: "hand.raised.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 32, height: 36)
            }
            .accessibilityLabel("Altro")
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(scheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(scheme.outline.opacity(0.3))
                .frame(height: 0.5)
        }
    }

    private var presenceLine: String {
        if container.viewModel.isPeerOnline { return "Online · cifrato E2E" }
        return "Cifrato E2E · ML-KEM 1024"
    }

    // MARK: - Message list

    private var messageList: some View {
        // Group messages by day so we can interleave DayHeader rows.
        let grouped = groupedByDay(container.viewModel.messages)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(grouped, id: \.key) { day, msgs in
                        DayHeader(date: day)
                        ForEach(msgs) { msg in
                            messageRow(for: msg)
                                .id(msg.id)
                        }
                    }
                    if container.viewModel.isPeerTyping {
                        typingRow
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: container.viewModel.messages.count) { _ in
                if let last = container.viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: container.viewModel.isPeerTyping) { typing in
                if typing, let last = container.viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                // W71: late-bind AppState so the send pipeline can encrypt
                // + ship via WS. Idempotent.
                container.attach(appState: appState)
                // W83: clear the unread badge as soon as the user is
                // looking at this conversation. Receipts handler still
                // increments unread for messages arriving while the
                // chat is closed; this only resets the count on open.
                container.markRead()
                // W84: emit msg_read to the peer so their UI flips
                // ✓✓ → ✓✓ blue. Once per chat-open (not on every
                // refresh) to keep WS chatter bounded.
                container.emitReadReceipts()
                if let last = container.viewModel.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onDisappear {
                // W90: stop suppressing local-notification banners
                // for this peer once the chat detail screen unmounts.
                container.resignActive()
            }
        }
    }

    @ViewBuilder
    private func messageRow(for msg: Message) -> some View {
        let variant: MessageBubbleVariant = (msg.direction == .outgoing) ? .sent : .received
        let timeLabel = Self.timeFormatter.string(from: msg.sentAt)
        let delivery = mapDelivery(msg.status)
        // W87: build reactions strip from Message.reactions (emoji →
        // [userId]). `highlighted = true` when the local user is among
        // the userIds — lets the chip render with the local accent so
        // they can see "I reacted with 👍".
        let myUserId = appState.currentUserId ?? ""
        let reactionChips: [MessageReaction] = (msg.reactions ?? [:])
            .filter { !$0.value.isEmpty }
            .sorted { $0.value.count > $1.value.count }
            .map { (emoji, users) in
                MessageReaction(
                    id: emoji,
                    emoji: emoji,
                    count: users.count,
                    highlighted: !myUserId.isEmpty && users.contains(myUserId)
                )
            }

        MessageBubble(
            variant: variant,
            timeLabel: timeLabel,
            delivery: variant == .sent ? delivery : nil,
            replyQuote: nil,
            reactions: reactionChips
        ) {
            // W81/W82: route bubble UI by media MIME type so voice
            // notes get the play/pause player and image attachments
            // get the inline preview + tap-to-fullscreen.
            if let mime = msg.mediaMimeType, mime.hasPrefix("audio/") {
                VoiceNoteBubbleContent(
                    player: VoiceNotePlayer.shared,
                    messageId: msg.id,
                    mediaLocalPath: msg.mediaLocalPath,
                    durationMs: msg.mediaDurationMs ?? 0
                )
            } else if let mime = msg.mediaMimeType, mime.hasPrefix("image/") {
                ImageBubbleContent(
                    messageId: msg.id,
                    mediaLocalPath: msg.mediaLocalPath
                )
            } else if let dur = msg.mediaDurationMs, dur > 0 {
                // Legacy fallback: pre-W82 voice notes lack mediaMimeType
                // but carry duration. Render via voice player.
                VoiceNoteBubbleContent(
                    player: VoiceNotePlayer.shared,
                    messageId: msg.id,
                    mediaLocalPath: msg.mediaLocalPath,
                    durationMs: dur
                )
            } else {
                Text(msg.plaintext)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            actionTargetId = msg.id
        }
    }

    private var typingRow: some View {
        HStack(spacing: 8) {
            TypingIndicator()
            Text("\(container.viewModel.conversation.peerDisplayName) sta scrivendo…")
                .qaudionStyle(type.labelSmall)
                .italic()
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func handleSend() {
        // W86: if editing, ship a qa_ctl:1 edit envelope to the peer
        // instead of creating a new message. ChatContainer.editMessage
        // applies the local replacement + emits the envelope. The
        // composer text is consumed; we clear it manually since
        // sendMessage isn't called.
        if let target = editingTarget,
           let targetUUID = UUID(uuidString: target.messageId),
           let original = container.viewModel.messages.first(where: { $0.id == targetUUID }) {
            container.editMessage(original, newPlaintext: container.composerText)
            container.composerText = ""
            editingTarget = nil
            replyTarget = nil
            return
        }
        editingTarget = nil
        let replyHandled = (replyTarget != nil)
        replyTarget = nil
        container.sendMessage()
        // replyHandled is reserved for a future `sendMessage(replyTo:)`
        // overload on `ChatContainer`.
        _ = replyHandled
    }

    private func startEdit(messageId: UUID) {
        guard let msg = container.viewModel.messages.first(where: { $0.id == messageId }) else { return }
        editingTarget = .init(messageId: msg.id.uuidString, previewText: msg.plaintext)
        container.composerText = msg.plaintext
    }

    private func copyMessage(messageId: UUID) {
        guard let msg = container.viewModel.messages.first(where: { $0.id == messageId }) else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = msg.plaintext
        #endif
    }

    private func messageIsOwn(_ id: UUID) -> Bool {
        container.viewModel.messages.first(where: { $0.id == id })?.direction == .outgoing
    }

    private func startAudioCall() {
        guard container.viewModel.conversation.kind != .group else { return }
        let peerId = container.viewModel.conversation.peerUserId
        Task { await appState.startCall(contactId: peerId, video: false) }
    }

    private func startVideoCall() {
        guard container.viewModel.conversation.kind != .group else { return }
        let peerId = container.viewModel.conversation.peerUserId
        Task { await appState.startCall(contactId: peerId, video: true) }
    }

    private func mapDelivery(_ status: Message.Status) -> MessageDelivery {
        switch status {
        case .sending:   return .sending
        case .sent:      return .sent
        case .delivered: return .delivered
        case .read:      return .read
        case .failed:    return .failed
        }
    }

    /// Group messages by calendar day, ordered ascending, preserving
    /// inter-day chronological order.
    private func groupedByDay(_ messages: [Message]) -> [(key: Date, value: [Message])] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: messages) { msg in
            cal.startOfDay(for: msg.sentAt)
        }
        return buckets.keys.sorted().map { ($0, buckets[$0]!) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - sheet item plumbing

    /// `Item`-binding helper so `.sheet(item:)` can drive the action sheet
    /// from a UUID. We wrap the optional UUID in an `Identifiable` shim
    /// because raw UUID is `Hashable` but not `Identifiable`.
    private var actionSheetBinding: Binding<MessageIdRef?> {
        Binding(
            get: { actionTargetId.map(MessageIdRef.init(id:)) },
            set: { newValue in actionTargetId = newValue?.id }
        )
    }
}

private struct MessageIdRef: Identifiable {
    let id: UUID
}

#Preview {
    NavigationStack {
        ChatDetailScreen(
            conversationId: UUID(),
            peerUserId: "user-mario",
            peerDisplayName: "Mario Rossi"
        )
    }
    .environmentObject(AppState())
    .qAudionTheme(dark: true)
}
