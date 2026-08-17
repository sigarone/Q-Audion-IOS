import SwiftUI
import PhotosUI
import QAudionEngine

/// W447: one row of the ephemeral-timer chooser. `seconds` uses the
/// same encoding as `Conversation.ephemeralTimerSeconds` /
/// `ChatContainer.setEphemeralTimer` (nil = off, -1 = view-once,
/// positive = TTL seconds). Shared by the conversation-level timer
/// dialog (topbar clock icon) AND the pre-send per-attachment picker
/// (W447) so both surfaces always offer the exact same choices.
struct EphemeralTimerOption: Identifiable {
    let id: String
    let label: String
    let seconds: Int?

    static let all: [EphemeralTimerOption] = [
        EphemeralTimerOption(id: "off", label: "Spento", seconds: nil),
        EphemeralTimerOption(id: "view_once", label: "Visualizza una volta", seconds: -1),
        EphemeralTimerOption(id: "30s", label: "30 secondi", seconds: 30),
        EphemeralTimerOption(id: "5m", label: "5 minuti", seconds: 5 * 60),
        EphemeralTimerOption(id: "1h", label: "1 ora", seconds: 60 * 60),
        EphemeralTimerOption(id: "1d", label: "1 giorno", seconds: 24 * 60 * 60),
        EphemeralTimerOption(id: "1w", label: "1 settimana", seconds: 7 * 24 * 60 * 60),
    ]
}

/// W447: a not-yet-sent attachment payload, captured at the moment the
/// user picks an attachment (photo, camera capture, pasted image, file,
/// or finished voice-note recording) so the pre-send timer dialog can
/// gate the actual `container.send*` call. Nothing is sent, no local
/// row created, no upload started until the user confirms a timer
/// choice in the dialog — cancel discards this value entirely.
enum PendingAttachmentSend {
    case image(Data)
    /// W91/W447: multi-select photo picker — one timer choice applies
    /// to the whole batch (asking once per photo would be unusable).
    case multiImage([Data])
    case file(URL)
    case voiceNote(VoiceNoteRecorder.Recording)
}

/// Chat detail (conversation) screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-chat/.../detail/ChatDetailScreen.kt`.
///
/// Layout (top → bottom):
///   1. **Top bar** — back chevron + 36pt avatar + display name + presence
///                    label + ephemeral timer + audio call + video call + ⋯
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
    /// W446: which media row (identified by message id) should act on
    /// the next `BubbleActionSheet` "Salva in Foto" / "Condividi"
    /// tap. `BubbleActionSheet` itself is media-agnostic — it only
    /// knows the target message's id — so `onSaveImage`/`onShareMedia`
    /// set this, and `messageRow(for:)` derives a per-row `Binding<Bool>`
    /// that flips true only for the matching id. This replaces the
    /// per-bubble inner `.contextMenu`s that used to own save/share
    /// directly (see `BubbleActionSheet`'s doc comment for why those
    /// conflicted with the outer long-press).
    @State private var mediaSaveRequestId: UUID? = nil
    @State private var mediaShareRequestId: UUID? = nil
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
    /// W145: pending message id for the "Elimina per tutti" confirm
    /// dialog. Non-nil → the dialog is up; tapping the destructive
    /// button fires container.deleteMessage and clears the state.
    @State private var pendingDeleteForAllId: UUID? = nil
    /// W147: confirm dialog gate for "Svuota cronologia". Uses Bool
    /// rather than UUID since the action is screen-scoped — there's
    /// only one history per chat detail view.
    @State private var showClearHistoryConfirm: Bool = false
    /// W445: Screenshot lock — local user preference. Toggled from
    /// PrivacySettingsScreen; read here to activate/deactivate on
    /// chat open/close. Persisted via AppStorage so it survives
    /// app restarts.
    @AppStorage("qaudion.chat.screenshot_lock_enabled") private var screenshotLockEnabled: Bool = true
    /// W445: Ephemeral timer picker.
    @State private var showingEphemeralPicker: Bool = false
    /// BLE-mesh offline chat fallback (branch claude/ble-mesh-cleanroom-spike).
    /// `meshRuntime` is `@ObservedObject` (not `@StateObject`) since it's a
    /// shared singleton, not owned by this screen — see `MeshRuntime.swift`.
    @State private var showingMeshSheet: Bool = false

    /// Whether THIS conversation's contact is on the mesh radar right now.
    ///
    /// Derived, never stored: their device is among the peers in range and the
    /// antenna is up. Resolving a peer to a contact goes through the same
    /// identity key the radar uses, so a contact with no authenticated key —
    /// never called, never synced — correctly reads as not-nearby rather than
    /// being guessed at.
    private var meshChatPeerIsNearby: Bool {
        guard meshRuntime.antennaMode != nil else { return false }
        let peerUserId = container.viewModel.conversation.peerUserId
        guard !peerUserId.isEmpty,
              let pubkey = ContactsStore().findPubkey(userId: peerUserId),
              let nodeHex = MeshFeature.nodeId(forContactPubkey: pubkey)?.hex
        else { return false }
        return meshRuntime.peers.contains { $0.nodeHex == nodeHex }
    }
    @ObservedObject private var meshRuntime = MeshRuntime.shared
    /// W445: Forward message state.
    @State private var showingForwardPicker: Bool = false
    @State private var forwardingMessage: Message? = nil
    /// W445: Document picker state.
    @State private var showingDocPicker: Bool = false
    /// W447: gate for the pre-send per-attachment timer picker. Non-nil
    /// → the confirmationDialog is up and holds the payload that will
    /// be sent once the user picks a timer (or discarded on cancel).
    /// Every attachment entry point (paste, camera, gallery multi-pick,
    /// document picker, voice-note finish) routes through this instead
    /// of calling `container.send*` directly.
    @State private var pendingAttachmentSend: PendingAttachmentSend? = nil

    // Stub values for the SessionStatusStrip until the engine wires them.
    private let stubConfidence: Double = 0.92
    private let stubPresenceLabel: String = "VOCE VERIFICATA"
    private let stubRekeyInSeconds: Int? = 252
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

    /// W-UUIDSWEEP-2: never trust a PERSISTED UUID-shaped conversation
    /// title at render — rows written before the write-site fixes carry the
    /// raw UUID; re-resolve through the central chain.
    private var resolvedPeerTitle: String {
        let stored = container.viewModel.conversation.peerDisplayName
        guard DisplayName.looksLikeUUID(stored) || stored.isEmpty else { return stored }
        if container.viewModel.conversation.kind == .group {
            return DisplayName.forGroup(id: container.viewModel.conversation.peerUserId, name: nil)
        }
        return DisplayName.forUser(container.viewModel.conversation.peerUserId,
                                   contacts: appState.cachedContacts)
    }

    /// W-CHATHEADERAVATARSTALE (2026-08-17) — mirrors `ChatListScreen
    /// .resolvedRowAvatarUrl` (2026-08-05 fix). The top bar built
    /// `QAudionAvatar` with no `imageURL` argument at all, so it always
    /// fell back to the initials placeholder regardless of what
    /// `ContactsStore`/`AvatarAnnounceCoordinator` had cached for this
    /// peer — the exact same class of bug the list row already had fixed,
    /// just never ported to this screen. Visible as: chat list shows the
    /// peer's real synced photo, tapping into the chat drops back to a
    /// plain initials circle. Group avatars are out of scope here (no
    /// single peer to key off) — same guard the list uses.
    private var resolvedPeerAvatarUrl: URL? {
        guard container.viewModel.conversation.kind != .group else { return nil }
        return appState.cachedContacts.first(where: {
            $0.userId == container.viewModel.conversation.peerUserId
        })?.avatarUrl
    }

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
            // W261: extract the MessageComposer construction itself into
            // a separate computed property. Even with all closures
            // extracted to methods, the 14-argument struct construction
            // was tripping the type-checker at the call site (line 102).
            // Computed properties have a clean type-check scope, isolated
            // from the surrounding ZStack/VStack ViewBuilder.
            // See CLAUDE.md §13.
            composerView
        }
        .background(scheme.background)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // W445: screenshot lock. Lock on appear when the user has enabled
        // the setting; always unlock on disappear so other screens aren't
        // affected. Extraction to methods keeps the closure bodies trivial
        // (CLAUDE.md §13).
        .onAppear(perform: handleScreenAppear)
        .onDisappear(perform: handleScreenDisappear)
        .onChange(of: container.screenshotGrantedByPeer) { _ in
            handleScreenAppear()
        }
        // W-SSREQ: live approve/deny dialog for an incoming ss_req, mirroring
        // Android's AlertDialog gated on state.incomingScreenshotRequest
        // (non-dismissable — the user must explicitly answer). Replaces the
        // old persisted "📸 Il contatto chiede..." chat bubble, which had no
        // interactive element at all (grantScreenshotPermission() had zero
        // UI callers) — the peer's request could never actually be granted.
        .alert("Richiesta screenshot", isPresented: Binding(
            get: { container.incomingScreenshotRequest },
            // No-op: SwiftUI calls this on every dismissal, including right
            // after a button action already flipped the flag via the
            // container. A deny-on-dismiss here would double-fire alongside
            // "Approva" (send approved:true, then immediately approved:false).
            set: { _ in }
        )) {
            Button("Rifiuta", role: .cancel) { container.denyScreenshotRequest() }
            Button("Approva") { container.grantScreenshotPermission() }
        } message: {
            Text("L'altro utente vuole abilitare gli screenshot in questa chat. Approvi?")
        }
        // W38: send-failure feedback. Quando il container marca un
        // messaggio fallito (engine pipeline wires `markFailed` su
        // crypto/network error), pushiamo una snackbar error con bottone
        // "Riprova" che chiama back nel container per ri-eseguire la
        // pipeline. La copy è derivata dal reason code (1:1 mapping
        // con Android `SendMessageUseCase.Outcome.Failed`).
        .onChange(of: container.failedMessageId) { newId in
            guard newId != nil, let reason = container.failureReason else { return }
            // W251: pre-bind reason.localizedDescription to a local. Multi-segment
            // string interpolation `\(obj.field)` inside a closure that builds a
            // SwiftUI struct literal trips Swift 6 / Xcode 26.4 type-checker
            // timeouts. See CLAUDE.md §13. Keep this pattern.
            let reasonText: String = reason.localizedDescription
            let snackbarText: String = "Messaggio non inviato — " + reasonText
            snackbar?.show(.init(
                text: snackbarText,
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
                        pendingAttachmentSend = .image(data)
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
                    pendingAttachmentSend = .image(data)
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
        // W259: extracted the multi-photo picker callback into methods.
        // Same pattern as W258 voice-note fix — inline closure body was
        // 4+ levels deep (closure → Task → for → if → MainActor.run with
        // struct literal) and the interpolation
        // `"\(failedCount) foto su \(total) non leggibili."` re-tripped
        // the type-checker once the W258 voice-note fix unblocked the
        // earlier compile path. See CLAUDE.md §13.
        .onChange(of: multiPickerItems) { newItems in
            handleMultiPhotoPicker(newItems)
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
                    // W145: don't fire the destructive action straight
                    // away — surface a confirm dialog. The actual delete
                    // runs from the dialog's destructive button below.
                    pendingDeleteForAllId = msgIdWrapper.id
                },
                onDeleteForMe: {
                    // W326: wired to ChatContainer.deleteMessageLocally
                    // via method extraction (defensive against the
                    // type-checker saga in this file). The closure
                    // body stays a single statement.
                    handleDeleteForMe(messageId: msgIdWrapper.id)
                },
                // W445: forward message. Find the target message and
                // open the forward picker sheet. The closure body stays
                // a single-statement guard to keep type-checker happy.
                onForward: { handleForward(messageId: msgIdWrapper.id) },
                // W446: media save/share — gated by mediaKind, routed
                // back to the specific row's ImageBubbleContent /
                // VoiceNoteBubbleContent via the id-scoped bindings
                // (see BubbleActionSheet's doc comment for why the
                // actions moved here from an inner .contextMenu).
                mediaKind: mediaKind(for: msgIdWrapper.id),
                onSaveImage: { mediaSaveRequestId = msgIdWrapper.id },
                onShareMedia: { mediaShareRequestId = msgIdWrapper.id },
                exportBlocked: mediaExportBlocked(for: msgIdWrapper.id),
                // W141: surface the sentAt so BubbleActionSheet can
                // hide the Modifica row past the 15-min edit window.
                sentAt: container.viewModel.messages
                    .first(where: { $0.id == msgIdWrapper.id })?.sentAt
            )
            // iOS 16.0 deployment target: `.medium` is the only detent
            // available; `.height(_:)` and `.presentationDragIndicator`
            // both require iOS 16.4+. The .medium detent gives roughly
            // half the screen, which is plenty for the 6-emoji row +
            // up to 4 action rows.
            .presentationDetents([.medium])
        }
        // W145: confirm before "delete for everyone". This is a
        // destructive action that ships a qa_ctl:1 t="delete" envelope
        // to the peer — easy to tap by accident, hard to undo.
        .confirmationDialog(
            "Eliminare il messaggio per tutti?",
            isPresented: Binding(
                get: { pendingDeleteForAllId != nil },
                set: { if !$0 { pendingDeleteForAllId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Elimina per tutti", role: .destructive) {
                guard let id = pendingDeleteForAllId,
                      let target = container.viewModel.messages
                        .first(where: { $0.id == id }) else {
                    pendingDeleteForAllId = nil
                    return
                }
                container.deleteMessage(target)
                snackbar?.show(.init(
                    text: "Messaggio eliminato per tutti.",
                    severity: .info,
                    durationSeconds: 2
                ))
                pendingDeleteForAllId = nil
            }
            Button("Annulla", role: .cancel) {
                pendingDeleteForAllId = nil
            }
        } message: {
            Text("Il destinatario non potrà più leggerlo. L'azione non può essere annullata.")
        }
        // W147: confirm before wiping the conversation history
        // locally. Server-side messages are unaffected (this only
        // clears the on-device cache), but rebuilding the view from
        // scratch loses any local-only metadata too — worth a tap.
        .confirmationDialog(
            "Svuotare la cronologia locale?",
            isPresented: $showClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Svuota", role: .destructive) {
                container.clearLocalHistory()
                snackbar?.show(.init(
                    text: "Cronologia locale cancellata.",
                    severity: .info,
                    durationSeconds: 2))
            }
            Button("Annulla", role: .cancel) { }
        } message: {
            Text("Tutti i messaggi e gli allegati di questa chat verranno rimossi solo da questo dispositivo.")
        }
        // W445: ephemeral timer chooser. ConfirmationDialog is the
        // lightest-weight picker on iOS — no custom UI needed.
        .confirmationDialog(
            "Messaggi efimeri",
            isPresented: $showingEphemeralPicker,
            titleVisibility: .visible
        ) {
            ForEach(EphemeralTimerOption.all) { option in
                Button(option.label) { container.setEphemeralTimer(option.seconds) }
            }
            Button("Annulla", role: .cancel) { }
        } message: {
            Text("I messaggi verranno eliminati automaticamente. \"Visualizza una volta\" li elimina appena aperti.")
        }
        // W447/W-XPTTL: pre-send per-attachment options — TTL/view-once
        // timer override PLUS the export-permission toggle, presented
        // together in one sheet (see AttachmentSendOptionsSheet's doc
        // comment for why a `.sheet` replaced the original bare
        // confirmationDialog — a live Toggle can't live inside a
        // confirmationDialog's button list). Intercepts the attach flow
        // (paperclip → photo/camera/paste/file/voice-note) right before
        // the send call fires. Confirm proceeds to send with the chosen
        // override; cancel/dismiss sends nothing (no row created, no
        // upload started) — `pendingAttachmentSend` is only cleared,
        // never executed, on the cancel path.
        .sheet(isPresented: Binding(
            get: { pendingAttachmentSend != nil },
            set: { presented in
                guard !presented else { return }
                // W447 fix (carried over from the confirmationDialog this
                // sheet replaced): this setter is SwiftUI's single
                // choke-point for EVERY dismissal — explicit cancel, swipe-
                // to-dismiss — it always writes `false` back through this
                // Binding. The confirm path already clears
                // `pendingAttachmentSend` itself before calling
                // performAttachmentSend, so by the time SwiftUI's own
                // dismissal reaches here it's already nil on that path and
                // there's nothing to clean up. On the cancel path it's
                // still holding the pending value, so this is where we
                // catch a cancelled `.voiceNote`: VoiceNoteRecorder.stop()
                // (see handleVoiceNoteFinish) already wrote the M4A to disk
                // before this sheet ever appeared, and cancelling here must
                // not orphan that temp file — mirror
                // VoiceNoteRecorder.cancel()'s exact best-effort idiom.
                if case .voiceNote(let recording) = pendingAttachmentSend {
                    try? FileManager.default.removeItem(at: recording.fileURL)
                }
                pendingAttachmentSend = nil
            }
        )) {
            AttachmentSendOptionsSheet(
                currentDefaultSeconds: container.viewModel.conversation.ephemeralTimerSeconds,
                onConfirm: { overrideSeconds, exportBlocked in
                    guard let pending = pendingAttachmentSend else { return }
                    pendingAttachmentSend = nil
                    performAttachmentSend(pending, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked)
                },
                onCancel: {
                    if case .voiceNote(let recording) = pendingAttachmentSend {
                        try? FileManager.default.removeItem(at: recording.fileURL)
                    }
                    pendingAttachmentSend = nil
                }
            )
            .presentationDetents([.medium])
        }
        // W445: forward message picker sheet.
        .sheet(isPresented: $showingForwardPicker) {
            if let msg = forwardingMessage {
                ForwardMessageSheet(message: msg) { targetConvId in
                    container.forwardMessage(msg, to: targetConvId)
                    forwardingMessage = nil
                    showingForwardPicker = false
                }
            }
        }
        // W445: document picker sheet.
        .sheet(isPresented: $showingDocPicker) {
            DocumentPicker { url in
                pendingAttachmentSend = .file(url)
                showingDocPicker = false
            }
        }
        // BLE-mesh offline chat sheet (branch claude/ble-mesh-cleanroom-spike).
        .sheet(isPresented: $showingMeshSheet) {
            MeshSheetView(
                runtime: meshRuntime,
                conversationId: container.viewModel.conversation.id.uuidString,
                chatPeerUserId: container.viewModel.conversation.peerUserId,
                onToast: handleMeshToast,
                onOpenConversation: handleMeshOpenConversation
            )
        }
    }

    // MARK: - BLE mesh sheet callbacks (branch claude/ble-mesh-cleanroom-spike)

    private func handleMeshToast(_ text: String) {
        snackbar?.show(.init(text: text, severity: .info))
    }

    /// Tapping a mesh peer that resolves to a DIFFERENT known contact than
    /// this chat's own navigates to that contact's chat instead — see
    /// `MeshSheetView.handlePeerTap`'s doc. Uses the SAME deep-link
    /// mechanism a notification tap uses (`pendingDeepLinkConversationId`,
    /// consumed by `ChatListScreen`'s `navigationDestination`), so this
    /// screen just resolves/creates the conversation and pops back to the
    /// list, where the existing deep-link plumbing takes over.
    private func handleMeshOpenConversation(peerUserId: String) {
        let conversationId = appState.resolveOrCreateConversationId(forPeerUserId: peerUserId)
        appState.pendingDeepLinkConversationId = conversationId
        dismiss()
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
                displayName: resolvedPeerTitle,
                imageURL: resolvedPeerAvatarUrl,
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
                Text(resolvedPeerTitle)
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

            // The PQC badge that sat here was `PqcBadge(active: true)` off a
            // compile-time constant — lit in every chat on every device
            // regardless of what key agreement actually happened. Deleted
            // rather than wired to a real source, because post-quantum key
            // agreement is unconditional in this app, so even a truthful
            // indicator would restate nothing.

            // W445: ephemeral timer button. Tap opens the timer chooser.
            // Accent color signals when a timer is active so the user knows
            // disappearing messages are on. (No confirmed filled SF Symbol
            // variant for "timer" to pair with it -- both branches of the
            // old ternary here referenced the same icon name, a no-op.)
            Button { showingEphemeralPicker = true } label: {
                let timerActive = (container.viewModel.conversation.ephemeralTimerSeconds ?? 0) > 0
                Image(systemName: "timer")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(timerActive ? extras.warning : scheme.onSurface.opacity(0.6))
                    .frame(width: 30, height: 36)
            }
            .accessibilityLabel("Imposta timer efimero")

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

            // BLE-mesh offline chat entry point (branch
            // claude/ble-mesh-cleanroom-spike) — gated on the same server
            // flag (`mesh_ble.enabled`) that hides it entirely when off,
            // same discipline as every other flag-gated affordance in this
            // app.
            //
            // It is lit in two cases now, not one: a mesh target is armed for
            // this conversation, OR this conversation's contact is simply on
            // the radar. The app already knew the second and said so nowhere
            // outside the sheet, so reaching someone over Bluetooth began by
            // opening a sheet to find out whether you could. The
            // accessibility label distinguishes them rather than naming an
            // icon. Matches the Android sibling.
            if MeshFeature.enabled {
                let conversationKey = container.viewModel.conversation.id.uuidString
                let armed = meshRuntime.activeTarget(for: conversationKey) != nil
                let peerNearby = meshChatPeerIsNearby
                Button { showingMeshSheet = true } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(armed || peerNearby ? extras.pqcAccent : scheme.onSurface)
                        .frame(width: 30, height: 36)
                }
                .accessibilityLabel(
                    armed ? "Mesh Bluetooth, invio via mesh attivo"
                          : (peerNearby ? "Mesh Bluetooth, questo contatto è raggiungibile qui vicino"
                                        : "Mesh Bluetooth")
                )
            }

            // W93: overflow menu — clear chat history + block / unblock
            // contact. The local-store wipe is immediate; block / unblock
            // hits ContactsApi.blockContact via the persistent backend.
            Menu {
                // Screenshot permission
                let ssGranted = container.screenshotGrantedByPeer
                if ssGranted == true {
                    Button {
                        container.revokeScreenshotPermission()
                        snackbar?.show(.init(text: "Autorizzazione screenshot revocata.",
                                             severity: .info))
                    } label: {
                        Label("Revoca screenshot", systemImage: "camera.badge.ellipsis")
                    }
                } else {
                    Button {
                        container.requestScreenshotPermission()
                        snackbar?.show(.init(text: "Richiesta screenshot inviata.",
                                             severity: .info))
                    } label: {
                        Label("Richiedi screenshot", systemImage: "camera")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    showClearHistoryConfirm = true
                } label: {
                    Label("Svuota cronologia", systemImage: "tray")
                }
                Button(role: .destructive) {
                    Task {
                        let ok = await container.toggleBlock()
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
        // W130: prioritize typing > online > static crypto label.
        // 'sta scrivendo…' overrides everything when isPeerTyping
        // is true (set by ChatContainer's chatTypingNotification
        // observer + auto-cleared 5s after the last is_typing=true).
        if container.viewModel.isPeerTyping {
            return "sta scrivendo…"
        }
        let peerId = container.viewModel.conversation.peerUserId
        if container.viewModel.isPeerOnline ||
           appState.presenceService.isOnline(peerId) {
            return "Online · cifrato E2E"
        }
        // W142: when offline, surface the most recent "last seen"
        // observation. Falls back to the static crypto label when the
        // peer has never been observed online on this device.
        if let lastSeen = LastSeenTracker.formatPresenceLabel(for: peerId) {
            return "\(lastSeen) · cifrato E2E"
        }
        return "Cifrato E2E · ML-KEM 1024"
    }

    // MARK: - Empty-state banner

    /// W143: educational banner shown only when the conversation has
    /// no messages yet. Lock-icon + short copy reassures the user the
    /// channel is end-to-end encrypted before they type the first
    /// message — same pattern as WhatsApp / iMessage.
    private var e2eEducationBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(extras.pqcAccent)
            Text("Cifratura end-to-end")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Text("I messaggi e le chiamate sono protetti con ML-KEM-1024 post-quantum. Nessun altro, nemmeno Q-Audion, può leggerli o ascoltarli.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.45))
        )
        .padding(.horizontal, 16)
        .padding(.top, 24)
    }

    // MARK: - Message list

    private var messageList: some View {
        // Group messages by day so we can interleave DayHeader rows.
        let grouped = groupedByDay(container.viewModel.messages)
        // Fase 2 — built once per render (not per row) so every
        // `ImageBubbleContent` shares the same in-display-order image
        // list and the fullscreen gallery can swipe across the whole
        // conversation. See `ImageGalleryItem`.
        let galleryItems = imageGalleryItems(container.viewModel.messages)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    // W143: empty-state E2E education banner. iMessage /
                    // WhatsApp pattern — the first time the user enters
                    // a conversation with no messages, surface the fact
                    // that messages are end-to-end encrypted. Renders
                    // ONLY when the message list is genuinely empty;
                    // disappears as soon as the first message lands.
                    if container.viewModel.messages.isEmpty {
                        e2eEducationBanner
                    }
                    ForEach(grouped, id: \.key) { day, msgs in
                        DayHeader(date: day)
                        ForEach(msgs) { msg in
                            messageRow(for: msg, galleryItems: galleryItems)
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
            // W260: preemptively flattened the scroll-to-bottom closures.
            // `if let last = container.viewModel.messages.last` is the same
            // antipattern as the lines we already fixed — optional chain
            // resolution inside a deeply-nested closure trips the
            // type-checker. Pre-binding `lastId` with guard let isolates
            // the optional unwrap from the `withAnimation` closure body.
            .onChange(of: container.viewModel.messages.count) { _ in
                guard let lastId = container.viewModel.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .onChange(of: container.viewModel.isPeerTyping) { typing in
                guard typing else { return }
                guard let lastId = container.viewModel.messages.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .onAppear {
                // W71: late-bind AppState so the send pipeline can encrypt
                // + ship via WS. Idempotent.
                container.attach(appState)
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
                // W137: flush any pending debounced draft save now,
                // because iOS may not give us another runloop tick
                // before the screen is fully torn down.
                container.flushDraftNow()
            }
        }
    }

    /// W127/W148/W149/W152: delegate to MarkdownLiteParser for
    /// monospaced code spans, bold/italic emphasis, and tappable URL
    /// detection. The heavy lifting lives in
    /// `Services/MarkdownLiteParser.swift` so this view file's
    /// type-checker job stays small.
    private static func attributedBody(_ raw: String, linkColor: Color) -> AttributedString {
        return MarkdownLiteParser.attributedBody(raw, linkColor: linkColor)
    }

    /// Fase 2 — every image message with a decrypted local cache path,
    /// in display order (self included), for the fullscreen gallery's
    /// swipe next/prev. See `ImageGalleryItem`.
    ///
    /// VERIFY FIX — must exclude every inbound view-once image, opened
    /// or not. `messageRow`'s `isVO && voOpened` branch (the
    /// "Visualizzato" tombstone) catches an ALREADY-opened view-once row
    /// too, before it ever reaches the `mime.hasPrefix("image/")`
    /// branch — so `ImageBubbleContent` is never rendered for a
    /// view-once inbound image at all, opened or not (only the sender's
    /// own outbound copy is exempt, per the `direction != .outgoing`
    /// guard below, mirroring `messageRow`'s `isVO`). The background
    /// download stamps `mediaLocalPath` as soon as the ciphertext
    /// decrypts — well before (and, for the 5s window, also shortly
    /// after) the recipient taps to reveal — so without this guard the
    /// image was still reachable by swiping the fullscreen gallery in
    /// from an unrelated photo, bypassing tap-to-reveal entirely and, on
    /// an already-viewed row, letting the recipient re-view a "single
    /// view" image for as long as `mediaLocalPath` lingers before
    /// `EphemeralMessageJanitor` sweeps it.
    private func imageGalleryItems(_ messages: [Message]) -> [ImageGalleryItem] {
        messages.compactMap { m in
            guard let mime = m.mediaMimeType, mime.hasPrefix("image/"),
                  let path = m.mediaLocalPath, !path.isEmpty else { return nil }
            let isVO = m.isViewOnce == true && m.direction != .outgoing
            guard !isVO else { return nil }
            return ImageGalleryItem(id: m.id, localPath: path)
        }
    }

    @ViewBuilder
    private func messageRow(for msg: Message, galleryItems: [ImageGalleryItem]) -> some View {
        let variant: MessageBubbleVariant = (msg.direction == .outgoing) ? .sent : .received
        let timeLabel = Self.timeFormatter.string(from: msg.sentAt)
        // W446: while an attachment upload is in flight, prefer the
        // local-only progress state over the status-derived icon. The
        // container removes the entry once the send reaches a terminal
        // state, so this only overrides `.sending` rows mid-upload.
        // Plain expression (not an if/else statement) — inside a
        // @ViewBuilder function body, a literal if/else is transformed by
        // the result-builder DSL and expects each branch to produce a
        // `View`; an assignment statement evaluates to `Void`, which the
        // transform then tries to conform to `View` and fails to compile
        // ("type '()' cannot conform to 'View'"). `.map`/`??` is a normal
        // expression, not a control-flow statement, so it's untouched by
        // the ViewBuilder transform.
        let delivery: MessageDelivery = container.uploadProgress[msg.id]
            .map { MessageDelivery.uploading(progress: $0) } ?? mapDelivery(msg.status)
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

        // View-once must only constrain the RECIPIENT's experience. The
        // sender's own outbound copy renders as a normal message and must
        // never enter the tap-to-reveal flow — that flow is what arms the
        // 5s deletion timer in ConversationStore.markViewOnceOpened, and
        // the sender should keep their own copy like any other message.
        let isVO = msg.isViewOnce == true && msg.direction != .outgoing
        let voOpened = msg.viewOnceOpened == true

        MessageBubble(
            variant: variant,
            timeLabel: timeLabel,
            delivery: variant == .sent ? delivery : nil,
            replyQuote: nil,
            reactions: reactionChips,
            onReact: { emoji in
                // Re-toggle: same path as BubbleActionSheet's emoji row
                // (ChatContainer.toggleReaction applies the local toggle
                // + emits the qa_ctl:1 envelope). A second tap on a chip
                // the local user already reacted with removes it.
                container.toggleReaction(msg, emoji: emoji)
            },
            viaMesh: msg.viaMesh == true
        ) {
            if isVO && !voOpened {
                // View-once: hidden until tapped. Show eye-slash pill.
                Button {
                    container.markViewOnceOpened(message: msg)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Tocca per visualizzare · una sola volta")
                            .qaudionStyle(type.labelSmall)
                    }
                    .foregroundStyle(extras.pqcAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            } else if isVO && voOpened {
                // Already opened — show tombstone.
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12))
                    Text("Visualizzato")
                        .qaudionStyle(type.labelSmall)
                }
                .foregroundStyle(scheme.onSurfaceVariant)
            } else if let mime = msg.mediaMimeType, mime.hasPrefix("audio/") {
                VoiceNoteBubbleContent(
                    player: VoiceNotePlayer.shared,
                    messageId: msg.id,
                    mediaLocalPath: msg.mediaLocalPath,
                    durationMs: msg.mediaDurationMs ?? 0,
                    shareRequest: mediaShareRequestBinding(for: msg.id)
                )
            } else if let mime = msg.mediaMimeType, mime.hasPrefix("image/") {
                ImageBubbleContent(
                    messageId: msg.id,
                    mediaLocalPath: msg.mediaLocalPath,
                    saveRequest: mediaSaveRequestBinding(for: msg.id),
                    shareRequest: mediaShareRequestBinding(for: msg.id),
                    galleryItems: galleryItems,
                    exportBlocked: msg.exportBlocked ?? false
                )
            } else if let mime = msg.mediaMimeType, !mime.isEmpty {
                // W446: generic file attachment (PDF, doc, archive, …) —
                // anything with a mime that isn't audio/image lands here
                // instead of falling through to plain text. Covers both
                // the downloading state (mediaLocalPath still nil, mime
                // already stamped from the qfile/attach_announce marker
                // — see AppState.handleIncomingMessage) and the ready
                // state once ChatVoiceNoteReceiver.fetch/fetchAttachAnnounce
                // populates the decrypted cache path.
                FileBubbleContent(
                    messageId: msg.id,
                    mediaLocalPath: msg.mediaLocalPath,
                    exportBlocked: msg.exportBlocked ?? false
                )
            } else if let dur = msg.mediaDurationMs, dur > 0 {
                VoiceNoteBubbleContent(
                    player: VoiceNotePlayer.shared,
                    messageId: msg.id,
                    mediaLocalPath: msg.mediaLocalPath,
                    durationMs: dur,
                    shareRequest: mediaShareRequestBinding(for: msg.id)
                )
            } else {
                Text(Self.attributedBody(msg.plaintext, linkColor: extras.success))
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(extras.success)
            }
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            actionTargetId = msg.id
        }
    }

    private var typingRow: some View {
        // W251: pre-bind the deep property chain to dodge type-checker timeouts.
        // See CLAUDE.md §13.
        let peerName: String = resolvedPeerTitle
        let typingText: String = peerName + " sta scrivendo…"
        return HStack(spacing: 8) {
            TypingIndicator()
            Text(typingText)
                .qaudionStyle(type.labelSmall)
                .italic()
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Voice-note callback methods (W258)
    //
    // Extracted from inline closures because the inline bodies were
    // 4-5 levels deep (closure → Task → do/catch with pattern matching)
    // and Swift 6 / Xcode 26.4 type-checker exhausted itself validating
    // EVERY statement inside — even simple function calls like
    // `container.markFailed(...)` started timing out at v1.0.256.
    //
    // Methods have a clean type-check scope, isolated from the
    // surrounding closure type constraints. See CLAUDE.md §13.

    private func handleVoiceNoteStart() {
        HapticFeedback.recordingStart()  // W114: light bump
        Task {
            await self.startVoiceNoteAsync()
        }
    }

    private func startVoiceNoteAsync() async {
        do {
            try await voiceNoteRecorder.start()
        } catch {
            // W258: simplified — any error from start() becomes a
            // generic failure. Previously we pattern-matched
            // RecorderError.permissionDenied separately, but it called
            // markFailed with the same .generic reason as the catch-all
            // branch. The pattern match was over-engineering and
            // contributed to the type-checker exhaustion.
            await MainActor.run {
                container.markFailed(messageId: UUID(), reason: .generic)
            }
        }
    }

    private func handleVoiceNoteFinish() {
        // W79: real upload+send pipeline. ChatContainer.sendVoiceNote
        // orchestrates the whole flow: read tmp M4A, encrypt+upload via
        // FileTransfer (HKDF-SHA256 + AES-256-GCM), mint a recipient
        // capability token, build a qfile v3 marker, and ship it as
        // the plaintext of a regular msg_send.
        // W447: route through the pre-send timer picker instead of
        // sending immediately — same gate as photo/camera/file.
        if let rec = voiceNoteRecorder.stop() {
            HapticFeedback.recordingStop()  // W114: medium bump
            pendingAttachmentSend = .voiceNote(rec)
        }
    }

    private func handleVoiceNoteCancel() {
        // W72: stop + delete tmp file.
        voiceNoteRecorder.cancel()
    }

    // MARK: - W326: delete-for-me handler
    //
    // Closes audit §2.1 — was a TODO(engine) no-op. The method-
    // extraction is defensive: the inline closure body would have
    // been:
    //
    //   if let m = container.viewModel.messages.first(where: { $0.id == id }) {
    //       container.deleteMessageLocally(m)
    //   }
    //   snackbar?.show(.init(text: "...", severity: .info, ...))
    //
    // That's enough closure depth + branching to risk the type-checker
    // saga (W221-W262). Method extraction keeps the closure trivial.

    private func handleDeleteForMe(messageId: UUID) {
        if let target = container.viewModel.messages.first(where: { $0.id == messageId }) {
            container.deleteMessageLocally(target)
        }
        snackbar?.show(.init(
            text: "Messaggio eliminato per te.",
            severity: .info,
            durationSeconds: 3
        ))
    }

    // MARK: - W445: screenshot lock handlers

    private func handleScreenAppear() {
        // Lock screenshots unless the peer has explicitly granted permission.
        let peerGranted = container.screenshotGrantedByPeer == true
        if screenshotLockEnabled && !peerGranted {
            ScreenshotLockService.lock()
        } else {
            ScreenshotLockService.unlock()
        }
    }

    private func handleScreenDisappear() {
        ScreenshotLockService.unlock()
    }

    // MARK: - W445: forward message handler

    private func handleForward(messageId: UUID) {
        guard let msg = container.viewModel.messages.first(where: { $0.id == messageId }) else {
            return
        }
        forwardingMessage = msg
        showingForwardPicker = true
    }

    // MARK: - Multi-photo picker callback methods (W259)
    //
    // Extracted from .onChange(of: multiPickerItems) for the same reason
    // as the voice-note callbacks (W258): inline closure body 4+ levels
    // deep was tripping the type-checker on the snackbar interpolation.
    // See CLAUDE.md §13.

    private func handleMultiPhotoPicker(_ newItems: [PhotosPickerItem]) {
        guard !newItems.isEmpty else { return }
        let items = newItems
        multiPickerItems = []
        Task { await self.processMultiPhotoPicker(items) }
    }

    private func processMultiPhotoPicker(_ items: [PhotosPickerItem]) async {
        // W91: load bytes for every picked item first — each one still
        // goes through the same EXIF-strip + 2048px + 10MB cap pipeline +
        // qfile marker once sent. W447: sending itself is deferred until
        // the user confirms a timer in the pre-send dialog (one dialog
        // for the whole batch, not one per photo).
        var loaded: [Data] = []
        var failures = 0
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                loaded.append(data)
            } else {
                failures += 1
            }
        }
        if failures > 0 {
            // W259: defer the interpolation to a static method so the
            // type-checker has a clean scope. Calling it via Self.
            // gives a fully-resolved single-overload symbol.
            let snackbarText: String = Self.photoFailureSnackbarText(
                failed: failures, total: items.count)
            await MainActor.run {
                snackbar?.show(.init(
                    text: snackbarText,
                    severity: .warning,
                    durationSeconds: 3))
            }
        }
        guard !loaded.isEmpty else { return }
        await MainActor.run { pendingAttachmentSend = .multiImage(loaded) }
    }

    private static func photoFailureSnackbarText(failed: Int, total: Int) -> String {
        // Single-statement static method — minimal context, single
        // overload. Type-checker resolves instantly even when callers
        // are deep inside closure stacks.
        return "\(failed) foto su \(total) non leggibili."
    }

    /// W611: stage-2 counterpart to `photoFailureSnackbarText` above.
    /// Stage 1 (`processMultiPhotoPicker`) catches items the system
    /// picker couldn't hand back as `Data` at all; this covers the
    /// later rejection inside `ChatContainer.sendImage` itself —
    /// undecodable bytes or over the 10MB post-downscale cap — which
    /// used to be a print-only silent drop with zero user feedback.
    private static func photoSendFailureSnackbarText(failed: Int, total: Int) -> String {
        if total == 1 {
            return "Invio foto non riuscito: formato non valido o file troppo grande."
        }
        return "\(failed) foto su \(total) non inviate: formato non valido o file troppo grandi."
    }

    // MARK: - W447: pre-send attachment timer dialog — dispatch

    /// Fires the actual `container.send*` call for a `PendingAttachmentSend`
    /// captured earlier, now that the user has confirmed the options in
    /// `AttachmentSendOptionsSheet`. `overrideSeconds` uses the same
    /// encoding as `EphemeralTimerOption.seconds` (nil = off/no-override,
    /// -1 = view-once, positive = TTL seconds) and is threaded straight
    /// through to `ChatContainer` so it lands in the envelope's `ex` field
    /// AND stamps the sender's own local echo `Message.expiresAt`.
    /// `exportBlocked` (`false` = allowed, the default) is threaded the
    /// same way for `Message.exportBlocked` / the envelope's `xp` field —
    /// see `ChatContainer.sendImage`/`sendFileAttachment`/`sendVoiceNote`
    /// doc comments for the per-attachment-type wire-reach caveat (the
    /// legacy qfile marker never carries `xp`; only the `attach_announce`
    /// path — voice notes when the feature flag is on — does).
    private func performAttachmentSend(_ pending: PendingAttachmentSend, overrideSeconds: Int?, exportBlocked: Bool) {
        switch pending {
        case .image(let data):
            // W611: sendImage now reports rejection (undecodable bytes /
            // over the 10MB cap) instead of silently print-and-returning
            // with zero local echo — surface it via the same snackbar
            // mechanism the stage-1 multi-picker failures already use.
            let sent = container.sendImage(data, overrideTimerSeconds: overrideSeconds, exportBlocked: exportBlocked)
            if !sent {
                snackbar?.show(.init(
                    text: Self.photoSendFailureSnackbarText(failed: 1, total: 1),
                    severity: .warning,
                    durationSeconds: 3))
            }
        case .multiImage(let items):
            var failed = 0
            for data in items {
                if !container.sendImage(data, overrideTimerSeconds: overrideSeconds, exportBlocked: exportBlocked) {
                    failed += 1
                }
            }
            if failed > 0 {
                snackbar?.show(.init(
                    text: Self.photoSendFailureSnackbarText(failed: failed, total: items.count),
                    severity: .warning,
                    durationSeconds: 3))
            }
        case .file(let url):
            container.sendFileAttachment(url: url, overrideTimerSeconds: overrideSeconds, exportBlocked: exportBlocked)
        case .voiceNote(let recording):
            container.sendVoiceNote(recording, overrideTimerSeconds: overrideSeconds, exportBlocked: exportBlocked)
        }
    }

    // MARK: - Composer view (W261)
    //
    // The MessageComposer struct construction has 14 arguments. Even
    // when every closure is method-extracted (W258/W259/W260), the
    // call site itself was tripping the type-checker — the inference
    // load of resolving all arguments simultaneously inside a
    // ZStack/VStack ViewBuilder context was just too much.
    //
    // Wrapping the construction in a `@ViewBuilder` computed property
    // gives it its own clean type-check scope. The body's ZStack now
    // sees a single `composerView` reference instead of an inline
    // 14-argument struct literal.

    @ViewBuilder
    private var composerView: some View {
        VStack(spacing: 0) {
            // BLE-mesh transport chip (branch claude/ble-mesh-cleanroom-spike)
            // — shown while a mesh peer is the active send target for this
            // conversation. Clearing it returns to the normal transport.
            if let target = meshRuntime.activeTarget(for: container.viewModel.conversation.id.uuidString) {
                MeshTransportChip(
                    peerName: target.displayName,
                    reachable: meshRuntime.antennaMode != nil
                        && meshRuntime.peers.contains { $0.nodeHex == target.nodeHex }
                ) {
                    meshRuntime.clearTarget(conversationId: container.viewModel.conversation.id.uuidString)
                }
            }
            // View-once indicator — shown when conversation timer is set to -1.
            // User disables it via the ⏱ timer button → set to "Spento".
            let convTimer = container.viewModel.conversation.ephemeralTimerSeconds ?? 0
            if convTimer == -1 {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(extras.pqcAccent)
                    Text("Modalità: visualizza una volta")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(extras.pqcAccent)
                    Spacer()
                    Button {
                        container.setEphemeralTimer(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(extras.pqcAccent.opacity(0.10))
            }
            MessageComposer(
            text: Binding(
                get: { container.composerText },
                set: handleComposerTextChange
            ),
            editingTarget: editingTarget,
            replyTarget: replyTarget,
            // W108: live elapsed-seconds counter for the recording
            // banner. Recorder publishes elapsedSeconds via a 0.25s
            // timer; passing through here is enough — SwiftUI binds
            // the @ObservedObject so the row updates automatically.
            recordingElapsedSeconds: voiceNoteRecorder.elapsedSeconds,
            onAttach: { showAttachmentChoice = true },
            // W445: file attachment callback — opens UIDocumentPickerViewController.
            onAttachFile: { showingDocPicker = true },
            onSend: handleSend,
            onCancelEdit: { editingTarget = nil },
            onCancelReply: { replyTarget = nil },
            // W258: voice-note callbacks extracted to methods to dodge
            // the type-checker exhaustion. See CLAUDE.md §13.
            onStartVoiceNote: handleVoiceNoteStart,
            onFinishVoiceNote: handleVoiceNoteFinish,
            onCancelVoiceNote: handleVoiceNoteCancel
        )
        }
    }

    // MARK: - Composer text-change callback (W260)

    private func handleComposerTextChange(_ newValue: String) {
        let wasEmpty = container.composerText.isEmpty
        container.composerText = newValue
        // W101: typing indicator emit. Empty→non-empty fires
        // `is_typing=true`; non-empty→empty fires `is_typing=false`
        // immediately. Steady-state typing rolls the 3s auto-stop timer.
        if !newValue.isEmpty {
            container.notifyComposerInput()
        } else if !wasEmpty {
            container.notifyComposerCleared()
        }
        // W137: persist the draft (debounced 0.5s) so the user doesn't
        // lose half-typed messages if iOS reaps the app in the background.
        container.scheduleDraftSave()
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

    /// W446: media kind of a message, used to gate `BubbleActionSheet`'s
    /// save/share rows. Mirrors the same mime/duration checks
    /// `messageRow(for:)` uses to pick `ImageBubbleContent` vs
    /// `VoiceNoteBubbleContent`.
    private func mediaKind(for id: UUID) -> BubbleActionSheet.MediaKind {
        guard let msg = container.viewModel.messages.first(where: { $0.id == id }) else {
            return .none
        }
        if let mime = msg.mediaMimeType, mime.hasPrefix("image/") {
            return .image
        }
        if let mime = msg.mediaMimeType, mime.hasPrefix("audio/") {
            return .voiceNote
        }
        if let dur = msg.mediaDurationMs, dur > 0 {
            return .voiceNote
        }
        return .none
    }

    /// Export-permission for a message's attachment, used to gate
    /// `BubbleActionSheet`'s save/share rows. `nil`/`false` on
    /// `Message.exportBlocked` = export allowed (unchanged behaviour).
    private func mediaExportBlocked(for id: UUID) -> Bool {
        container.viewModel.messages.first(where: { $0.id == id })?.exportBlocked ?? false
    }

    /// W446: id-scoped `Binding<Bool>` for `ImageBubbleContent.saveRequest`.
    /// Reads/writes `mediaSaveRequestId` but only exposes `true` to the
    /// row whose `msgId` currently matches — every other row in the
    /// `ForEach` sees `false`, so setting the flag never touches the
    /// wrong bubble.
    private func mediaSaveRequestBinding(for msgId: UUID) -> Binding<Bool> {
        Binding(
            get: { mediaSaveRequestId == msgId },
            set: { newValue in
                mediaSaveRequestId = newValue ? msgId : (mediaSaveRequestId == msgId ? nil : mediaSaveRequestId)
            }
        )
    }

    /// W446: id-scoped `Binding<Bool>` for `ImageBubbleContent.shareRequest`
    /// / `VoiceNoteBubbleContent.shareRequest`. Same pattern as
    /// `mediaSaveRequestBinding(for:)` above.
    private func mediaShareRequestBinding(for msgId: UUID) -> Binding<Bool> {
        Binding(
            get: { mediaShareRequestId == msgId },
            set: { newValue in
                mediaShareRequestId = newValue ? msgId : (mediaShareRequestId == msgId ? nil : mediaShareRequestId)
            }
        )
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

// MARK: - W445: Forward Message Sheet

/// Simple "Inoltra a…" conversation picker. Shows all stored conversations
/// except the current one, lets the user pick a destination, then calls
/// the onSelect callback with the target conversation id.
private struct ForwardMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let message: Message
    let onSelect: (UUID) -> Void

    @State private var conversations: [Conversation] = []
    /// W-UUIDSWEEP-2: rubrica snapshot for resolving persisted UUID-shaped
    /// titles (this sheet has no AppState in scope; one load at init).
    private let rubrica = ContactsStore().load()

    var body: some View {
        NavigationStack {
            List(conversations) { conv in
                Button {
                    onSelect(conv.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DisplayName.looksLikeUUID(conv.peerDisplayName) || conv.peerDisplayName.isEmpty
                            ? DisplayName.forUser(conv.peerUserId, contacts: rubrica)
                            : conv.peerDisplayName)
                            .foregroundStyle(scheme.onSurface)
                        if let preview = conv.lastMessagePreview, !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(scheme.onSurfaceVariant)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Inoltra a…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear { conversations = ConversationStore().loadConversations() }
        }
    }
}

// MARK: - W445: Document Picker (UIDocumentPickerViewController wrapper)

/// SwiftUI wrapper around UIDocumentPickerViewController for generic file
/// attachments. Parity with Android `onPickAttachment → OpenDocument(*/*)`
/// (see ChatDetailScreen.kt).
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
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
