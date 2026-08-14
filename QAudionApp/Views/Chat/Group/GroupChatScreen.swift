import SwiftUI
import UIKit
import Combine
import PhotosUI                    // Fase 1B: group attachment picker
import UniformTypeIdentifiers      // Fase 1B: file mime resolution
import QAudionEngine   // W-GRPRING: GroupCallController (group-call entry point)
import CryptoKit                    // VERIFY FIX: deterministicGalleryId(for:)

/// VERIFY FIX — a `GroupMessageRowUi.id` (String) is USUALLY a UUID
/// string (client_msg_id, minted via `UUID().uuidString` on send), but
/// `AppState.landIncomingGroupAttachment` falls back to the raw
/// `server_message_id` (`rowId = clientMsgId ?? serverMsgId`) when the
/// wire omits `client_msg_id` — not guaranteed to be UUID-formatted.
/// `imageGalleryItems` and `messageBody` each independently need to map
/// that same string id to a `UUID` (`ImageGalleryItem.id` /
/// `ImageBubbleContent.messageId`); a plain `UUID(uuidString:) ?? UUID()`
/// mints a *different* random UUID at each call site for a non-UUID
/// string, so the gallery's `items.firstIndex(where: { $0.id ==
/// messageId })` lookup (in `ImageBubbleContent`) would never match and
/// the fullscreen viewer would silently always open on page 0 instead of
/// the tapped image. This derives a stable UUID from the string's
/// SHA-256 digest so every call site converges on the identical value.
private func deterministicGalleryId(for raw: String) -> UUID {
    if let u = UUID(uuidString: raw) { return u }
    let digest = SHA256.hash(data: Data(raw.utf8))
    let bytes = Array(digest.prefix(16))
    return bytes.withUnsafeBufferPointer { buf in
        NSUUID(uuidBytes: buf.baseAddress!) as UUID
    }
}

/// Group chat detail. 1:1 port di Android
/// `qaudion-android-new/feature/feature-chat/.../group/GroupChatScreen.kt`.
///
/// Layout:
///   1. Top bar — back chevron + 36pt group icon + nome / "N membri"
///      (zona tappabile → GroupInfoScreen)
///   2. Messages LazyVStack — empty state quando state.messages è vuoto
///      altrimenti righe `GroupMessageBubble` con allineamento mine/peer
///   3. Composer bar — TextField "Messaggio cifrato…" + send button 40pt
///      con icona paperplane.fill primary
///
/// Engine wiring pending: oggi i messaggi sono ephemeral local @State
/// (nessun persistence). Quando l'engine espone group messaging, usiamo
/// gli stessi GroupMessageRowUi via `GroupChatRepository.observe(...)`.
struct GroupChatScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qaudionSnackbar) private var snackbar
    /// W409: needed to call AppState.leaveGroup from the
    /// GroupInfoScreen.onLeft callback.
    @EnvironmentObject private var appState: AppState

    let groupId: UUID
    @State private var state: GroupChatUiState
    @State private var showingInfo = false
    // Fase 1B — attachment composer. `showingAttachChoice` gates the
    // photo-vs-file confirmation dialog; the two pickers below drive the
    // GroupAttachmentSender send path.
    @State private var showingAttachChoice = false
    @State private var showingPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    /// W-XPTTL — pending group attachment awaiting the pre-send options
    /// choice (TTL/view-once + export-permission). Group attachments had
    /// NO pre-send dialog before this field — reuses the SAME
    /// `PendingAttachmentSend` enum + `AttachmentSendOptionsSheet` the
    /// 1:1 flow uses (`.voiceNote` is unreachable here — group has no
    /// voice-note send flow — but the enum is shared rather than forked).
    @State private var pendingGroupAttachmentSend: PendingAttachmentSend? = nil
    /// Fase 2 — userIds of OTHER members currently typing in this group
    /// (populated from `AppState.groupTypingNotification`, filtered to
    /// this screen's own `groupHex`). Mirrors the 1:1 `isPeerTyping` flag,
    /// generalized to a set since a group can have several concurrent
    /// typists.
    @State private var typingSenderIds: Set<String> = []

    init(groupId: UUID, initial: GroupChatUiState) {
        self.groupId = groupId
        _state = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                messageList
                composer
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // W-GRPMSG: load persisted history on open and refresh live when
        // AppState's group receive path lands a new message for THIS
        // group. Replaces the ephemeral-@State "Beta" behaviour.
        // Fase 1B — mark this group the "active" one so AppState suppresses
        // the inbound-group banner while it's on screen (mirrors the 1:1
        // `activePeerUserId` gate), and clear its unread badge on open.
        .onAppear {
            appState.activeGroupHex = groupHex
            reloadMessagesFromStore()
            // Fase 1B — re-kick the download for any inbound attachment row
            // whose descriptor is retained but whose blob never landed (a
            // prior download failed or the app was killed mid-download).
            // Mirrors the 1:1 path's re-attempt of un-downloaded media on open.
            appState.retryPendingGroupAttachmentDownloads(groupHex: groupHex)
            // GAP FIX — cold-recovery was previously wired ONLY into
            // fresh-device bootstrap. Opening a group chat you already
            // have locally now also GETs the current metadata_version and
            // applies it if newer (cheap no-op otherwise), so a rename/
            // avatar change made while this device was offline (missed
            // the live group_metadata_changed WS event) still lands.
            appState.refreshGroupMetadataFromServer(groupHex: groupHex)
            // Fase 2 — emit group_msg_read for every inbound message with a
            // server id, once per chat-open (mirrors the 1:1
            // container.emitReadReceipts() call in ChatDetailScreen.onAppear).
            appState.emitGroupReadReceipts(groupId: groupId.uuidString.lowercased())
        }
        .onDisappear {
            if appState.activeGroupHex == groupHex { appState.activeGroupHex = nil }
        }
        // Fase 2 — group typing indicator. Filtered to this screen's own
        // group; is_typing=false removes the sender, true adds it — no
        // client-side timeout fallback, same as the 1:1
        // chatTypingNotification consumer in ChatContainer.
        .onReceive(NotificationCenter.default.publisher(
            for: AppState.groupTypingNotification)) { note in
            guard let info = note.userInfo as? [String: Any],
                  (info["groupHex"] as? String) == groupHex,
                  let senderId = info["senderId"] as? String,
                  let isTyping = info["isTyping"] as? Bool else { return }
            if isTyping {
                typingSenderIds.insert(senderId)
            } else {
                typingSenderIds.remove(senderId)
            }
        }
        // Fase 1B — attachment pickers (parity with the 1:1 composer).
        .confirmationDialog("Aggiungi allegato",
                            isPresented: $showingAttachChoice,
                            titleVisibility: .visible) {
            Button {
                showingPhotoPicker = true
            } label: {
                Label("Galleria", systemImage: "photo.on.rectangle")
            }
            Button {
                showingFileImporter = true
            } label: {
                Label("File", systemImage: "doc")
            }
            Button("Annulla", role: .cancel) { }
        }
        .photosPicker(isPresented: $showingPhotoPicker,
                      selection: $photoPickerItems,
                      maxSelectionCount: 10,
                      matching: .images)
        .onChange(of: photoPickerItems) { newItems in
            handlePickedPhotos(newItems)
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            handlePickedFile(result)
        }
        // W-XPTTL — pre-send options for group attachments (group had NO
        // pre-send dialog before this field; see `pendingGroupAttachmentSend`
        // doc comment). Same sheet + cancel-cleanup pattern as the 1:1
        // flow in `ChatDetailScreen` (there's no voice-note temp file to
        // clean up here — group has no voice-note send path — so the
        // dismissal binding is simpler).
        .sheet(isPresented: Binding(
            get: { pendingGroupAttachmentSend != nil },
            set: { presented in if !presented { pendingGroupAttachmentSend = nil } }
        )) {
            AttachmentSendOptionsSheet(
                currentDefaultSeconds: nil,
                onConfirm: { overrideSeconds, exportBlocked in
                    guard let pending = pendingGroupAttachmentSend else { return }
                    pendingGroupAttachmentSend = nil
                    performGroupAttachmentSend(pending, overrideSeconds: overrideSeconds, exportBlocked: exportBlocked)
                },
                onCancel: { pendingGroupAttachmentSend = nil }
            )
            .presentationDetents([.medium])
        }
        .onReceive(NotificationCenter.default.publisher(
            for: GroupMessageStore.didChangeNotification)) { note in
            if (note.userInfo?["groupHex"] as? String) == groupHex {
                reloadMessagesFromStore()
            }
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                GroupInfoScreen(
                    state: makeInfoState(),
                    isSelfAdmin: selfIsAdmin,
                    addableContacts: addableContactRows,
                    onAddMembers: { ids in
                        appState.addGroupMembers(groupId: groupHex, newMembers: ids)
                    },
                    onRemoveMember: { uid in
                        appState.removeGroupMember(groupId: groupHex, member: uid)
                    },
                    onRename: { newName in
                        appState.updateGroupMetadata(groupId: groupHex, newName: newName, avatarData: nil)
                    },
                    onSetAvatar: { jpegData in
                        appState.updateGroupMetadata(groupId: groupHex, newName: nil, avatarData: jpegData)
                    },
                    onPromoteAdmin: { uid in
                        appState.promoteGroupAdmin(groupId: groupHex, member: uid)
                    },
                    onDemoteAdmin: { uid in
                        appState.demoteGroupAdmin(groupId: groupHex, member: uid)
                    },
                    onLeft: {
                        // W409: actually leave the group via AppState.
                        // Ships qa_grp:1 t:"member_left" envelope to all
                        // remaining members through the 1:1 ratchet, then
                        // tears down local registry + GroupChatService
                        // session for this groupId.
                        // W-GRPDEL: `leaveGroup` now also calls the server
                        // leave endpoint and tombstones the id, so the
                        // group can no longer be resurrected by the next
                        // reconcile.
                        appState.leaveGroup(groupId: groupHex)
                        showingInfo = false
                        dismiss()
                    },
                    onDelete: {
                        // W-GRPDEL: "Elimina chat" — server leave, full
                        // local purge (history + crypto state included),
                        // tombstone. Fail-open: the chat goes away even if
                        // the server call does not land.
                        appState.deleteGroupChat(groupId: groupHex)
                        showingInfo = false
                        dismiss()
                    }
                )
            }
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

            // Header tappabile → GroupInfoScreen
            // W320: long-press copia il groupId nella clipboard con
            // feedback snackbar — utile per tester che devono
            // riferirsi a un gruppo specifico nei bug report.
            Button(action: { showingInfo = true }) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(scheme.surfaceVariant)
                            .frame(width: 36, height: 36)
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(scheme.primary)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.name)
                            .qaudionStyle(type.titleSmall)
                            .foregroundStyle(scheme.onSurface)
                            .lineLimit(1)
                        Text("\(state.memberCount) membri")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .modifier(MonoCaption())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6)
                    .onEnded { _ in handleCopyGroupId() }
            )
            Spacer(minLength: 8)

            // W-GRPRING — start a GROUP CALL with this group's members.
            // Audit gap: there was no way to call the group you are in (the
            // only entry point was the contacts multi-select picker, which has
            // no group context). Mirrors Android's group-chat top-bar call
            // button (commit 5f87bc67), now split audio/video (W-GRPVIDEO) —
            // same two-button pattern as the 1:1 ChatDetailScreen's
            // startAudioCall/startVideoCall pair. Invitees = the group
            // roster minus self.
            Button(action: { handleStartGroupCall(video: false) }) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canStartGroupCall ? scheme.primary : scheme.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!canStartGroupCall)
            .accessibilityLabel("Chiama il gruppo (audio)")

            Button(action: { handleStartGroupCall(video: true) }) {
                Image(systemName: "video.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canStartGroupCall ? scheme.primary : scheme.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!canStartGroupCall)
            .accessibilityLabel("Videochiama il gruppo")
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(scheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(scheme.outline.opacity(0.3)).frame(height: 0.5)
        }
    }

    // MARK: - Message list

    /// Fase 2 — every image message with a decrypted local cache path,
    /// in display order (self included), for the fullscreen gallery's
    /// swipe next/prev. Mirrors `ChatDetailScreen.imageGalleryItems`;
    /// `id` uses the same `deterministicGalleryId(for:)` mapping
    /// `messageBody` applies per-row (a group row id is a String, not a
    /// UUID — see that helper's doc comment for why a plain
    /// `UUID(uuidString:) ?? UUID()` fallback is unsafe here).
    private var imageGalleryItems: [ImageGalleryItem] {
        state.messages.compactMap { m in
            guard m.attachmentKind == GroupAttachmentEnvelope.kindImage,
                  let path = m.mediaLocalPath, !path.isEmpty else { return nil }
            return ImageGalleryItem(id: deterministicGalleryId(for: m.id), localPath: path)
        }
    }

    private var messageList: some View {
        // Fase 2 — built once per render (not per row), same reasoning
        // as ChatDetailScreen.messageList.
        let galleryItems = imageGalleryItems
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if state.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(state.messages) { msg in
                            GroupMessageBubble(message: msg, galleryItems: galleryItems)
                                .id(msg.id)
                        }
                    }
                    if !typingSenderIds.isEmpty {
                        typingRow
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: state.messages.count) { _ in
                if let last = state.messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Fase 2 — mirrors `ChatDetailScreen.typingRow`. One or more members
    /// typing: "<name> sta scrivendo…" for exactly one, "<n> persone stanno
    /// scrivendo…" for more (a group has no single "peer name" slot to
    /// reuse the 1:1 phrasing for the multi-typist case).
    private var typingRow: some View {
        let names = typingSenderIds.map(resolveMemberName)
        let typingText: String = names.count == 1
            ? "\(names[0]) sta scrivendo…"
            : "\(names.count) persone stanno scrivendo…"
        return HStack(spacing: 8) {
            TypingIndicator()
            Text(typingText)
                .qaudionStyle(type.labelSmall)
                .italic()
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    /// W-GRPMSG: group id in the hex form GroupChatService /
    /// GroupMessageStore / GroupRegistry key on (dashes stripped,
    /// lowercase). The dashed lowercase UUID (`groupId.uuidString
    /// .lowercased()`) is the server wire id.
    private var groupHex: String {
        groupId.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 48))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Nessun messaggio")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Text("Scrivi il primo messaggio cifrato del gruppo.")
                .qaudionStyle(type.bodySmall)
                .italic()
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            // Fase 1B — attach button (parity with the 1:1 composer
            // paperclip). Opens the photo/file choice dialog.
            Button(action: { showingAttachChoice = true }) {
                Image(systemName: "paperclip")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Aggiungi allegato")

            TextField("",
                      text: composerBinding,
                      prompt: Text("Messaggio cifrato…")
                          .italic()
                          .foregroundColor(scheme.onSurfaceVariant),
                      axis: .vertical)
                .lineLimit(1...4)
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(scheme.primary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(scheme.surfaceVariant.opacity(0.45))
                )

            Button(action: handleSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(scheme.onPrimary)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(canSend
                                      ? scheme.primary
                                      : scheme.surfaceVariant)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(scheme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(scheme.outline.opacity(0.3)).frame(height: 0.5)
        }
    }

    private var canSend: Bool {
        !state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerBinding: Binding<String> {
        Binding(get: { state.composerText },
                set: { newValue in
                    // Fase 2 — typing-indicator emit, mirrors
                    // ChatDetailScreen.handleComposerTextChange: empty→non-empty
                    // fires is_typing=true, non-empty→empty fires is_typing=false
                    // immediately. Steady-state typing rolls the 3s auto-stop
                    // timer inside AppState.notifyGroupComposerInput. Same
                    // asymmetry as 1:1: tapping Send (handleSend, below) does
                    // NOT explicitly clear typing — the 3s timer does.
                    let wasEmpty = state.composerText.isEmpty
                    state.composerText = newValue
                    let gid = groupId.uuidString.lowercased()
                    if !newValue.isEmpty {
                        appState.notifyGroupComposerInput(groupId: gid)
                    } else if !wasEmpty {
                        appState.notifyGroupComposerCleared(groupId: gid)
                    }
                })
    }

    // MARK: - Handlers

    /// W320: long-press handler that copies the group UUID to the
    /// system pasteboard. Method-extracted to keep the gesture
    /// closure trivial (SWIFT6_PATTERNS rule 4 — no closure body
    /// deeper than `closure → Task → do/catch`).
    private func handleCopyGroupId() {
        let value: String = groupId.uuidString
        UIPasteboard.general.string = value
        let msg: String = Self.formatGroupIdCopiedMessage(prefix:
            String(value.prefix(8)))
        snackbar?.show(.init(text: msg, severity: .info))
    }

    /// W320: snackbar copy helper. Static so it has its own clean
    /// type-check scope and no `@ViewBuilder` constraints.
    private static func formatGroupIdCopiedMessage(prefix: String) -> String {
        return "ID gruppo copiato (" + prefix + "…)"
    }

    // MARK: - W-GRPRING: start a group call from the group chat

    /// The real roster (registry) — never `makeInfoState()`'s
    /// self-only loading state for a not-yet-populated registry, which
    /// would otherwise invite nobody.
    private var groupCallInvitees: [String] {
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else { return [] }
        let selfId = AppState.currentUserIdSnapshot ?? ""
        return entry.members.filter { $0 != selfId && !$0.isEmpty }
    }

    private var canStartGroupCall: Bool {
        !groupCallInvitees.isEmpty && appState.groupCallController != nil
    }

    /// Create the group call and let `ContentView`'s group-call cover present
    /// the live screen (it is driven off `groupCallControllerState`, which
    /// `createCall` moves to `.connecting`). Populates `call_type` + the group
    /// context on the `group_call_create` envelope — the server relays those
    /// verbatim to every invitee's `group_call_invite` AND to the wake-up push,
    /// which is what lets the callee render a correct incoming-group-call ring.
    ///
    /// W-GRPVIDEO: `video` threads all the way to `GroupCallController.
    /// createCall(callType:)` -> `LiveKitGroupCallRoom(video:)`, so a video
    /// group call actually publishes the camera once the SFU token resolves
    /// (this was audio-only, unconditionally, until this change).
    private func handleStartGroupCall(video: Bool) {
        let invitees = groupCallInvitees
        guard !invitees.isEmpty else {
            snackbar?.show(.init(text: "Nessun altro membro nel gruppo", severity: .info))
            return
        }
        let name = state.name
        let dashedGroupId = groupId.uuidString.lowercased()
        let created = appState.groupCallController?.createCall(
            invitees: invitees,
            title: name,
            callType: video ? "video" : "audio",
            groupId: dashedGroupId,  // dashed UUID == server wire id
            groupName: name)
        if created == nil {
            snackbar?.show(.init(text: "Chiamata di gruppo non disponibile ora", severity: .error))
        } else {
            // In-call chat panel — bind this call to its persisted group so
            // `GroupCallView`'s chat panel knows which group's messages/
            // roster to use (see `GroupCallViewModel.activeGroupId` kdoc).
            appState.groupCallViewModel?.bindGroupId(dashedGroupId)
        }
    }

    /// W-GRPMSG — reload the visible bubbles from the persistent
    private static let timeFormatterHHmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// GroupMessageStore. The store holds BOTH the sender's optimistic
    /// rows and decrypted inbound text, so this is the single source of
    /// truth (no more ephemeral @State appends).
    private func reloadMessagesFromStore() {
        let stored = GroupMessageStore.shared.messages(forGroupHex: groupHex)
        state.messages = stored.map { m in
            GroupMessageRowUi(
                id: m.id,
                text: m.text,
                // Fase 1B — resolve the raw sender UUID to a contact name so
                // group bubbles never label a peer with a bare UUID (mirrors
                // the 1:1 inbound path, AppState.persistIncomingPeerMessage).
                senderLabel: m.mine ? "Tu" : resolveMemberName(m.senderId),
                timestamp: Self.timeFormatterHHmm.string(from: m.ts),
                mine: m.mine,
                // Fase 1B — attachment fields (nil for a plain text row).
                attachmentKind: m.attachmentKind,
                mediaMime: m.mediaMime,
                mediaLocalPath: m.mediaLocalPath,
                fileName: m.fileName,
                byteLength: m.byteLength,
                delivery: deliveryStatus(for: m),
                exportBlocked: m.exportBlocked)
        }
        // Viewing the group == reading it: clear the unread badge shown in
        // the chat list (mirrors ChatContainer.markRead for 1:1).
        GroupMessageStore.shared.markRead(groupHex: groupHex)
    }

    /// Fase 2 — roster minus self, used as the ALL-members threshold for
    /// `deliveryStatus(for:)`. Separate from `groupCallInvitees` (identical
    /// filter, different concern) so the two call sites don't couple.
    private var otherGroupMemberIds: [String] {
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else { return [] }
        let selfId = AppState.currentUserIdSnapshot ?? ""
        return entry.members.filter { $0 != selfId && !$0.isEmpty }
    }

    /// Fase 2 — WhatsApp-style ALL-members threshold for a `mine` row's
    /// delivery tick: `.sending` before the server self-echo binds a
    /// `serverMessageId`; `.sent` (single check) until at least one other
    /// member acks; `.delivered` (double grey) once EVERY other member has
    /// delivered-or-read; `.read` (double blue) once EVERY other member has
    /// specifically read. A member's `read` receipt also counts toward the
    /// `delivered` threshold (reading implies the message reached the
    /// device) — covers the edge case where `group_msg_read` lands without
    /// a distinct prior `group_msg_delivered` for that member (both are
    /// independent best-effort sends, see groups_receipts.go). Always nil
    /// for an inbound (non-mine) row.
    private func deliveryStatus(for m: GroupMessageStore.Stored) -> MessageDelivery? {
        guard m.mine else { return nil }
        guard m.serverMessageId != nil else { return .sending }
        let others = otherGroupMemberIds
        guard !others.isEmpty else { return .sent }
        let othersSet = Set(others)
        let readBy = Set(m.readBy ?? [])
        if othersSet.isSubset(of: readBy) { return .read }
        let deliveredOrRead = Set(m.deliveredBy ?? []).union(readBy)
        if othersSet.isSubset(of: deliveredOrRead) { return .delivered }
        return .sent
    }

    /// Fase 1B — resolve a group member/sender `userId` to a human label.
    /// Fallback chain mirrors the 1:1 inbound path: cached contact display
    /// name → abbreviated id. NEVER returns a raw UUID.
    private func resolveMemberName(_ userId: String) -> String {
        // Central chain (DisplayName.swift): rubrica alias → server display
        // → "Utente a1b2c3d4…". Passes the cached snapshot so the per-bubble
        // render path stays free of UserDefaults decodes.
        return DisplayName.forUser(userId, contacts: appState.cachedContacts)
    }

    private func handleSend() {
        let trimmed = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.composerText = ""

        let memberRows = makeInfoState().members
        let memberIds = memberRows.map { $0.userId }
        let selfId = memberRows.first(where: { $0.isSelf })?.userId
            ?? (AppState.currentUserIdSnapshot ?? "u-self")

        // Optimistic, PERSISTENT local row (mirrors Android's PENDING
        // MessageEntity written before the network handoff). Keyed by
        // clientMsgId so the server self-echo binds to it instead of
        // duplicating. The store posts didChange → reloadMessagesFromStore.
        let clientMsgId = UUID().uuidString
        GroupMessageStore.shared.append(
            groupHex: groupHex,
            GroupMessageStore.Stored(
                id: clientMsgId,
                serverMessageId: nil,
                senderId: selfId,
                mine: true,
                text: trimmed,
                ts: Date()))

        Task {
            await sendGroupOverWire(
                plaintext: trimmed,
                memberIds: memberIds,
                selfId: selfId,
                clientMsgId: clientMsgId)
        }
    }

    /// W-GRPMSG — ship ONE `group_msg_send` frame for the group TEXT
    /// payload (server fans out to every member + echoes back to us),
    /// replacing the retired per-member `opaque_message` fan-out.
    ///
    /// The `qa_grp:1` sender_key_init distribution over the 1:1 ratchet
    /// is UNCHANGED and still runs first (shared with Android) so recv
    /// chains are installed before the ciphertext arrives.
    ///
    /// Best-effort: a failure is logged but does NOT roll back the
    /// optimistic store row (the user already saw their bubble).
    @MainActor
    private func sendGroupOverWire(
        plaintext: String,
        memberIds: [String],
        selfId: String,
        clientMsgId: String
    ) async {
        // KEEP — REAL sender_key_init distribution over the 1:1 ratchet.
        // Each envelope rides `groupSenderKeyCtlNotification` → AppState
        // wraps it under the per-pair PSK / v3 ratchet and ships as an
        // opaque_message; the recipient detects qa_grp:1 and installs our
        // send chain BEFORE the group ciphertext lands.
        let pendingInits = GroupChatService.shared.pendingInitsAfterBootstrap(
            groupId: groupHex, members: memberIds, selfId: selfId)
        for init_ in pendingInits {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: [
                    "recipient": init_.recipientId,
                    "envelopeJson": init_.envelopeJson,
                ]
            )
        }
        // Encrypt the 0xE4 group wire ONCE and hand it to AppState, which
        // holds the live WS. `groupEpoch` is stamped from the live
        // GroupState (mirrors Android's state.groupEpoch.toInt()).
        guard let sealed = GroupChatService.shared.encryptForWire(
            plaintext: plaintext,
            groupId: groupHex,
            members: memberIds,
            selfId: selfId
        ) else {
            print("[GroupChatScreen] encrypt failed for group \(groupHex)")
            return
        }
        NotificationCenter.default.post(
            name: AppState.groupMsgSendNotification,
            object: nil,
            userInfo: [
                "groupId": groupId.uuidString.lowercased(),  // dashed UUID (server wire)
                "wire": sealed.wire,
                "clientMsgId": clientMsgId,
                "groupEpoch": Int(sealed.groupEpoch),
            ]
        )
    }

    // MARK: - Fase 1B: attachment send

    /// Load each picked photo as JPEG bytes, THEN hand the whole batch to
    /// `pendingGroupAttachmentSend` for the pre-send options sheet — one
    /// dialog for the whole multi-select batch, mirroring 1:1's
    /// `processMultiPhotoPicker`. The picker selection is cleared so
    /// re-picking the same asset fires `onChange` again. Sending itself
    /// is deferred until the user confirms in `performGroupAttachmentSend`.
    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let picked = items
        photoPickerItems = []
        Task { await processPickedGroupPhotos(picked) }
    }

    private func processPickedGroupPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [Data] = []
        var failures = 0
        for item in items {
            if let raw = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: raw),
               let jpeg = img.jpegData(compressionQuality: 0.85) {
                loaded.append(jpeg)
            } else {
                failures += 1
            }
        }
        if failures > 0 {
            await MainActor.run {
                snackbar?.show(.init(
                    text: "\(failures) foto su \(items.count) non leggibili.",
                    severity: .warning, durationSeconds: 3))
            }
        }
        guard !loaded.isEmpty else { return }
        await MainActor.run { pendingGroupAttachmentSend = .multiImage(loaded) }
    }

    /// File picked — defer the actual read to `performGroupAttachmentSend`
    /// (after the pre-send options sheet is confirmed), mirroring 1:1's
    /// `DocumentPicker` call site (`pendingAttachmentSend = .file(url)`).
    private func handlePickedFile(_ result: Result<[URL], Swift.Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        pendingGroupAttachmentSend = .file(url)
    }

    /// Fires the actual group attachment send for a `PendingAttachmentSend`
    /// captured earlier, now that the user has confirmed the pre-send
    /// options. `.voiceNote` is unreachable — group has no voice-note
    /// send flow — kept only to satisfy the shared enum's exhaustiveness.
    private func performGroupAttachmentSend(_ pending: PendingAttachmentSend, overrideSeconds: Int?, exportBlocked: Bool) {
        switch pending {
        case .image(let data):
            let img = UIImage(data: data)
            Task {
                await sendAttachmentOverWire(
                    data: data, mime: "image/jpeg", kind: GroupAttachmentEnvelope.kindImage,
                    filename: "IMG-\(Int(Date().timeIntervalSince1970)).jpg",
                    width: img.map { Int($0.size.width) }, height: img.map { Int($0.size.height) },
                    timerOverrideSeconds: overrideSeconds, exportBlocked: exportBlocked)
            }
        case .multiImage(let items):
            for data in items {
                let img = UIImage(data: data)
                Task {
                    await sendAttachmentOverWire(
                        data: data, mime: "image/jpeg", kind: GroupAttachmentEnvelope.kindImage,
                        filename: "IMG-\(Int(Date().timeIntervalSince1970)).jpg",
                        width: img.map { Int($0.size.width) }, height: img.map { Int($0.size.height) },
                        timerOverrideSeconds: overrideSeconds, exportBlocked: exportBlocked)
                }
            }
        case .file(let url):
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    snackbar?.show(.init(text: "File non leggibile", severity: .warning))
                    return
                }
                let ext = url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                await sendAttachmentOverWire(
                    data: data, mime: mime, kind: GroupAttachmentEnvelope.kindFile,
                    filename: url.lastPathComponent, width: nil, height: nil,
                    timerOverrideSeconds: overrideSeconds, exportBlocked: exportBlocked)
            }
        case .voiceNote:
            break
        }
    }

    /// Encrypt+upload the blob, mint per-member capability tokens, seal the
    /// descriptor into the 0xE4 group payload, and ship ONE `group_msg_send`
    /// frame with `msg_type == 1`. The sender_key_init distribution runs
    /// first, exactly like the text path.
    ///
    /// - Parameter timerOverrideSeconds: W-XPTTL — per-attachment TTL/
    ///   view-once override chosen in the pre-send options sheet. `nil`
    ///   (default) preserves pre-existing behaviour for any caller that
    ///   hasn't migrated. Threaded to `GroupAttachmentSender.prepare` AND
    ///   used to stamp the sender's own local echo `expiresAt`/
    ///   `isViewOnce` via the SAME `AttachmentTimerResolver` the receive
    ///   path (`AppState.landIncomingGroupAttachment`) already uses,
    ///   `conversationDefault: nil` (group has no per-conversation
    ///   default).
    /// - Parameter exportBlocked: export-permission choice from the
    ///   pre-send options sheet. `false` (default) = export allowed.
    @MainActor
    private func sendAttachmentOverWire(
        data: Data, mime: String, kind: String, filename: String,
        width: Int?, height: Int?, caption: String? = nil,
        timerOverrideSeconds: Int? = nil, exportBlocked: Bool = false
    ) async {
        let memberRows = makeInfoState().members
        let memberIds = memberRows.map { $0.userId }
        let selfId = memberRows.first(where: { $0.isSelf })?.userId
            ?? (AppState.currentUserIdSnapshot ?? "u-self")

        let prepared: GroupAttachmentSender.Prepared
        do {
            prepared = try await GroupAttachmentSender(appState: appState).prepare(
                data: data, mime: mime, kind: kind, filename: filename,
                caption: caption, width: width, height: height,
                members: memberIds, selfId: selfId,
                timerOverrideSeconds: timerOverrideSeconds, exportBlocked: exportBlocked)
        } catch {
            snackbar?.show(.init(text: "Allegato non inviato — \(error.localizedDescription)",
                                 severity: .error, durationSeconds: 5))
            return
        }

        // Same resolver + stamping the RECEIVE path uses (see kdoc above) —
        // the sender's own optimistic row gets the identical expiresAt/
        // isViewOnce/exportBlocked treatment as an inbound row, so the
        // janitor sweeps a self-sent view-once/TTL row too and the
        // sender's own bubble gates Save/Condividi consistently.
        let now = Date()
        let effectiveTimerSecs = AttachmentTimerResolver.resolve(
            overrideSeconds: timerOverrideSeconds, conversationDefault: nil)
        let isViewOnce = (effectiveTimerSecs ?? 0) == -1
        let ephExpiry: Date? = effectiveTimerSecs.flatMap { s in
            s > 0 ? now.addingTimeInterval(Double(s)) : nil
        }

        // Optimistic PERSISTENT row (the sender already has the plaintext on
        // disk, so the bubble renders immediately). Keyed by clientMsgId so
        // the server self-echo binds instead of duplicating.
        let clientMsgId = UUID().uuidString
        GroupMessageStore.shared.append(
            groupHex: groupHex,
            GroupMessageStore.Stored(
                id: clientMsgId,
                serverMessageId: nil,
                senderId: selfId,
                mine: true,
                text: prepared.caption ?? "",
                ts: now,
                attachmentKind: prepared.kind,
                mediaMime: prepared.mime,
                fileName: prepared.filename,
                byteLength: prepared.byteLength,
                mediaLocalPath: prepared.localPath,
                descriptorJson: prepared.descriptorJson,
                expiresAt: ephExpiry,
                isViewOnce: isViewOnce ? true : nil,
                exportBlocked: exportBlocked ? true : nil))

        // sender_key_init distribution first (recv chains before ciphertext).
        let pendingInits = GroupChatService.shared.pendingInitsAfterBootstrap(
            groupId: groupHex, members: memberIds, selfId: selfId)
        for init_ in pendingInits {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: ["recipient": init_.recipientId,
                           "envelopeJson": init_.envelopeJson])
        }

        // Seal the descriptor JSON into the 0xE4 group wire and ship it with
        // msg_type == 1.
        guard let sealed = GroupChatService.shared.encryptForWire(
            plaintext: prepared.descriptorJson,
            groupId: groupHex, members: memberIds, selfId: selfId
        ) else {
            print("[GroupChatScreen] attachment encrypt failed for group \(groupHex)")
            return
        }
        NotificationCenter.default.post(
            name: AppState.groupMsgSendNotification,
            object: nil,
            userInfo: [
                "groupId": groupId.uuidString.lowercased(),
                "wire": sealed.wire,
                "clientMsgId": clientMsgId,
                "groupEpoch": Int(sealed.groupEpoch),
                "msgType": GroupAttachmentEnvelope.msgTypeAttachment,
            ])
    }

    /// Fase 1A — is the local user an admin of THIS group? Drives the
    /// add/remove affordances in GroupInfoScreen.
    private var selfIsAdmin: Bool {
        let selfId = AppState.currentUserIdSnapshot ?? ""
        guard !selfId.isEmpty,
              let entry = GroupRegistry.shared.entry(for: groupHex) else { return false }
        return entry.admins.contains(selfId)
    }

    /// Fase 1A — contacts eligible to add (whole address book; the sheet
    /// filters out those already in the roster). Same source as
    /// CreateGroupScreen.
    private var addableContactRows: [ContactPickerRowUi] {
        // W-ORPHANPEER — reachableContacts: "who can I add" is a reach
        // surface, so orphans are excluded here too.
        appState.reachableContacts.map {
            ContactPickerRowUi(userId: $0.userId,
                               displayName: $0.displayName,
                               avatarUrl: $0.avatarUrl)
        }
    }

    private func makeInfoState() -> GroupInfoUiState {
        // W399 — read real membership from GroupRegistry. Falls back to
        // a self-only loading state (see below) only if the group hasn't
        // been joined yet (e.g. invite not accepted, or registry corrupted).
        let groupIdHex = groupId.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let selfId = AppState.currentUserIdSnapshot ?? "u-self"
        if let entry = GroupRegistry.shared.entry(for: groupIdHex) {
            let rows = entry.members.map { uid in
                GroupMemberRowUi(
                    userId: uid,
                    // Fase 1B — resolve UUID → contact name (was raw `uid`).
                    displayName: uid == selfId ? "Tu" : resolveMemberName(uid),
                    isAdmin: entry.admins.contains(uid),
                    isSelf: uid == selfId)
            }
            return GroupInfoUiState(
                groupId: groupId,
                name: entry.name,
                epoch: Int(entry.epoch),
                members: rows,
                // Fase 1C — same "serverUrl + /api/v1/files/{fileId}"
                // convention `AvatarUploader` uses for the profile avatar.
                avatarUrl: entry.avatarRef.flatMap {
                    URL(string: "\(appState.serverUrl)/api/v1/files/\($0)")
                })
        }
        // Fase 2 — registry not populated yet (invite not accepted, or
        // AppState bootstrap races the SwiftUI render). Previously this
        // fabricated fake "Membro N" rows with placeholder `u-N` ids to
        // pad out to `state.memberCount` — those ids aren't real users:
        // besides rendering nonsense names, `handleSend`/
        // `sendAttachmentOverWire` resolve their wire recipients from
        // this same `members` list, so a fake id there would silently
        // address a message to nobody. Show a real loading/empty state
        // instead (surfaced via `error`, which `GroupInfoScreen` already
        // renders as a banner) — no fabricated members.
        return GroupInfoUiState(
            groupId: groupId,
            name: state.name,
            epoch: 1,
            members: [
                GroupMemberRowUi(userId: selfId, displayName: "Tu",
                                 isAdmin: true, isSelf: true)
            ],
            error: "Elenco membri non ancora disponibile — in attesa di sincronizzazione."
        )
    }
}

// MARK: - GroupMessageBubble

/// Internal (not `private`) so `GroupCallChatPanel` (the in-call chat
/// panel) can reuse this EXACT bubble rendering rather than duplicating it —
/// pure access-level change, no behavior change.
struct GroupMessageBubble: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let message: GroupMessageRowUi
    /// Fase 2 — see `ImageGalleryItem`; empty default keeps this struct
    /// constructible without callers threading the list through.
    var galleryItems: [ImageGalleryItem] = []

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.mine { Spacer(minLength: 40) }

            VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
                if !message.mine {
                    Text(message.senderLabel)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.leading, 14)
                }

                VStack(alignment: .leading, spacing: 4) {
                    messageBody
                    HStack(spacing: 4) {
                        if message.mine { Spacer(minLength: 0) }
                        Text(message.timestamp)
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                        // Fase 2 — delivery/read tick, mine rows only.
                        // Reuses the shared `MessageDelivery` type + the
                        // same 4 icon mappings as the 1:1
                        // `MessageBubble.deliveryIcon(_:)` footer.
                        if message.mine, let delivery = message.delivery {
                            groupDeliveryIcon(delivery)
                        }
                        if !message.mine { Spacer(minLength: 0) }
                    }
                    .frame(maxWidth: .infinity,
                           alignment: message.mine ? .trailing : .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: 280, alignment: .leading)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if !message.mine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity,
               alignment: message.mine ? .trailing : .leading)
    }

    /// Fase 2 — same 4 icon mappings as the 1:1 `MessageBubble.deliveryIcon`
    /// footer (`.uploading`/`.failed` are unreachable for a group row today
    /// — group sends have no upload-progress or hard-failure UI state yet
    /// — but the switch must be exhaustive over the shared `MessageDelivery`
    /// enum, so they fall back to the same icon as their nearest neighbor).
    @ViewBuilder
    private func groupDeliveryIcon(_ delivery: MessageDelivery) -> some View {
        switch delivery {
        case .sending, .uploading:
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.primary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.error)
        }
    }

    /// Fase 1B — bubble body: an image/file attachment (reusing the exact
    /// 1:1 ``ImageBubbleContent`` / ``FileBubbleContent`` views) with an
    /// optional caption, or plain text when this row is not an attachment.
    @ViewBuilder
    private var messageBody: some View {
        switch message.attachmentKind {
        case GroupAttachmentEnvelope.kindImage?:
            ImageBubbleContent(
                // VERIFY FIX — must match imageGalleryItems' id mapping
                // exactly (deterministicGalleryId, not a fresh random
                // UUID()) or ImageBubbleContent's startIndex lookup into
                // galleryItems silently fails whenever message.id isn't
                // already UUID-formatted.
                messageId: deterministicGalleryId(for: message.id),
                mediaLocalPath: message.mediaLocalPath,
                galleryItems: galleryItems,
                exportBlocked: message.exportBlocked ?? false)
            if !message.text.isEmpty {
                Text(message.text)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
            }
        case GroupAttachmentEnvelope.kindFile?:
            FileBubbleContent(
                messageId: UUID(uuidString: message.id) ?? UUID(),
                mediaLocalPath: message.mediaLocalPath,
                fileSizeBytes: message.byteLength,
                exportBlocked: message.exportBlocked ?? false)
            if !message.text.isEmpty {
                Text(message.text)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
            }
        default:
            Text(message.text)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        // @ViewBuilder consente rami if/else con tipi @Environment-aware
        // diversi senza richiedere `AnyView`. I due rami sono identici
        // in shape (RoundedRectangle 14pt) ma differiscono per fill +
        // border, perciò mantenere @ViewBuilder è la via Swift-idiomatic.
        if message.mine {
            RoundedRectangle(cornerRadius: 14)
                .fill(scheme.primary.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(scheme.primary.opacity(0.55), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(scheme.surfaceVariant.opacity(0.65))
        }
    }
}

private struct MonoCaption: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(.caption, design: .monospaced))
    }
}

#Preview("Empty") {
    GroupChatScreen(
        groupId: UUID(),
        initial: GroupChatUiState(
            name: "Famiglia",
            memberCount: 4,
            messages: []
        )
    )
    .qAudionTheme(dark: true)
}

#Preview("With messages") {
    GroupChatScreen(
        groupId: UUID(),
        initial: GroupChatUiState(
            name: "Q-Audion Team",
            memberCount: 6,
            messages: [
                GroupMessageRowUi(id: "m1", text: "Ciao a tutti!",
                                  senderLabel: "Mario", timestamp: "10:32",
                                  mine: false),
                GroupMessageRowUi(id: "m2", text: "Tutto a posto?",
                                  senderLabel: "Tu", timestamp: "10:33",
                                  mine: true),
                GroupMessageRowUi(id: "m3",
                                  text: "Sì, ci sentiamo dopo per la chiave.",
                                  senderLabel: "Anna", timestamp: "10:34",
                                  mine: false)
            ]
        )
    )
    .qAudionTheme(dark: true)
}
