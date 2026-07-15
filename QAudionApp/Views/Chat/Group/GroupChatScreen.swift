import SwiftUI
import UIKit
import Combine
import PhotosUI                    // Fase 1B: group attachment picker
import UniformTypeIdentifiers      // Fase 1B: file mime resolution
import QAudionEngine   // W-GRPRING: GroupCallController (group-call entry point)

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
        }
        .onDisappear {
            if appState.activeGroupHex == groupHex { appState.activeGroupHex = nil }
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
                    onLeft: {
                        // W409: actually leave the group via AppState.
                        // Ships qa_grp:1 t:"member_left" envelope to all
                        // remaining members through the 1:1 ratchet, then
                        // tears down local registry + GroupChatService
                        // session for this groupId.
                        let gidHex = groupId.uuidString
                            .replacingOccurrences(of: "-", with: "")
                            .lowercased()
                        appState.leaveGroup(groupId: gidHex)
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
            // button (commit 5f87bc67): audio-only for now, invitees = the
            // group roster minus self.
            Button(action: handleStartGroupCall) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canStartGroupCall ? scheme.primary : scheme.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!canStartGroupCall)
            .accessibilityLabel("Chiama il gruppo")
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(scheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(scheme.outline.opacity(0.3)).frame(height: 0.5)
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if state.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(state.messages) { msg in
                            GroupMessageBubble(message: msg)
                                .id(msg.id)
                        }
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
                set: { state.composerText = $0 })
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

    /// The real roster (registry), never the stub fallback of
    /// `makeInfoState()` — inviting the placeholder `u-1`/`u-2` ids would
    /// create a call nobody can join.
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
    private func handleStartGroupCall() {
        let invitees = groupCallInvitees
        guard !invitees.isEmpty else {
            snackbar?.show(.init(text: "Nessun altro membro nel gruppo", severity: .info))
            return
        }
        let name = state.name
        let created = appState.groupCallController?.createCall(
            invitees: invitees,
            title: name,
            callType: "audio",              // video group call: follow-up (parity with Android)
            groupId: groupId.uuidString.lowercased(),  // dashed UUID == server wire id
            groupName: name)
        if created == nil {
            snackbar?.show(.init(text: "Chiamata di gruppo non disponibile ora", severity: .error))
        }
    }

    /// W-GRPMSG — reload the visible bubbles from the persistent
    /// GroupMessageStore. The store holds BOTH the sender's optimistic
    /// rows and decrypted inbound text, so this is the single source of
    /// truth (no more ephemeral @State appends).
    private func reloadMessagesFromStore() {
        let stored = GroupMessageStore.shared.messages(forGroupHex: groupHex)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        state.messages = stored.map { m in
            GroupMessageRowUi(
                id: m.id,
                text: m.text,
                // Fase 1B — resolve the raw sender UUID to a contact name so
                // group bubbles never label a peer with a bare UUID (mirrors
                // the 1:1 inbound path, AppState.persistIncomingPeerMessage).
                senderLabel: m.mine ? "Tu" : resolveMemberName(m.senderId),
                timestamp: f.string(from: m.ts),
                mine: m.mine,
                // Fase 1B — attachment fields (nil for a plain text row).
                attachmentKind: m.attachmentKind,
                mediaMime: m.mediaMime,
                mediaLocalPath: m.mediaLocalPath,
                fileName: m.fileName,
                byteLength: m.byteLength)
        }
        // Viewing the group == reading it: clear the unread badge shown in
        // the chat list (mirrors ChatContainer.markRead for 1:1).
        GroupMessageStore.shared.markRead(groupHex: groupHex)
    }

    /// Fase 1B — resolve a group member/sender `userId` to a human label.
    /// Fallback chain mirrors the 1:1 inbound path: cached contact display
    /// name → abbreviated id. NEVER returns a raw UUID.
    private func resolveMemberName(_ userId: String) -> String {
        if let name = appState.cachedContacts.first(where: { $0.userId == userId })?.displayName,
           !name.isEmpty {
            return name
        }
        return Self.shortLabel(userId)
    }

    private static func shortLabel(_ userId: String) -> String {
        if userId.count > 12 { return String(userId.prefix(8)) + "…" }
        return userId
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

    /// Load each picked photo as JPEG bytes and ship it as a group image
    /// attachment. Multi-select fans out one frame per image (mirrors the
    /// 1:1 composer). The picker selection is cleared so re-picking the
    /// same asset fires `onChange` again.
    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoPickerItems = []
        for item in items {
            Task { @MainActor in
                guard let raw = try? await item.loadTransferable(type: Data.self),
                      let img = UIImage(data: raw),
                      let jpeg = img.jpegData(compressionQuality: 0.85) else {
                    snackbar?.show(.init(text: "Immagine non leggibile", severity: .warning))
                    return
                }
                await sendAttachmentOverWire(
                    data: jpeg, mime: "image/jpeg", kind: GroupAttachmentEnvelope.kindImage,
                    filename: "IMG-\(Int(Date().timeIntervalSince1970)).jpg",
                    width: Int(img.size.width), height: Int(img.size.height))
            }
        }
    }

    /// Read the picked file (security-scoped) and ship it as a group file
    /// attachment with its resolved mime.
    private func handlePickedFile(_ result: Result<[URL], Swift.Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { @MainActor in
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
                filename: url.lastPathComponent, width: nil, height: nil)
        }
    }

    /// Encrypt+upload the blob, mint per-member capability tokens, seal the
    /// descriptor into the 0xE4 group payload, and ship ONE `group_msg_send`
    /// frame with `msg_type == 1`. The sender_key_init distribution runs
    /// first, exactly like the text path.
    @MainActor
    private func sendAttachmentOverWire(
        data: Data, mime: String, kind: String, filename: String,
        width: Int?, height: Int?, caption: String? = nil
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
                members: memberIds, selfId: selfId)
        } catch {
            snackbar?.show(.init(text: "Allegato non inviato — \(error.localizedDescription)",
                                 severity: .error, durationSeconds: 5))
            return
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
                ts: Date(),
                attachmentKind: prepared.kind,
                mediaMime: prepared.mime,
                fileName: prepared.filename,
                byteLength: prepared.byteLength,
                mediaLocalPath: prepared.localPath,
                descriptorJson: prepared.descriptorJson))

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
        appState.cachedContacts.map {
            ContactPickerRowUi(userId: $0.userId,
                               displayName: $0.displayName,
                               avatarUrl: $0.avatarUrl)
        }
    }

    private func makeInfoState() -> GroupInfoUiState {
        // W399 — read real membership from GroupRegistry. Falls back
        // to the legacy stub layout only if the group hasn't been
        // joined yet (e.g. invite not accepted, or registry corrupted).
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
                members: rows)
        }
        // Stub fallback — kept so a fresh group view doesn't crash
        // before the user accepts the invite (or AppState bootstrap
        // races the SwiftUI render).
        return GroupInfoUiState(
            name: state.name,
            epoch: 1,
            members: [
                GroupMemberRowUi(userId: selfId, displayName: "Tu",
                                 isAdmin: true, isSelf: true)
            ] + (1...max(0, state.memberCount - 1)).map { i in
                GroupMemberRowUi(
                    userId: "u-\(i)",
                    displayName: "Membro \(i)",
                    isAdmin: false,
                    isSelf: false
                )
            }
        )
    }
}

// MARK: - GroupMessageBubble

private struct GroupMessageBubble: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let message: GroupMessageRowUi

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
                    Text(message.timestamp)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
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

    /// Fase 1B — bubble body: an image/file attachment (reusing the exact
    /// 1:1 ``ImageBubbleContent`` / ``FileBubbleContent`` views) with an
    /// optional caption, or plain text when this row is not an attachment.
    @ViewBuilder
    private var messageBody: some View {
        switch message.attachmentKind {
        case GroupAttachmentEnvelope.kindImage?:
            ImageBubbleContent(
                messageId: UUID(uuidString: message.id) ?? UUID(),
                mediaLocalPath: message.mediaLocalPath)
            if !message.text.isEmpty {
                Text(message.text)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
            }
        case GroupAttachmentEnvelope.kindFile?:
            FileBubbleContent(
                messageId: UUID(uuidString: message.id) ?? UUID(),
                mediaLocalPath: message.mediaLocalPath,
                fileSizeBytes: message.byteLength)
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
