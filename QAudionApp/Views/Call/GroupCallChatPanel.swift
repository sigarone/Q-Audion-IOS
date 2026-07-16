import SwiftUI
import UIKit
import PhotosUI                    // parity w/ GroupChatScreen's picker
import UniformTypeIdentifiers      // file mime resolution
import CryptoKit                    // deterministicId(for:) — gallery id mapping
import QAudionEngine

/// In-call chat + attachments panel for GROUP calls — same "icon toggle ->
/// dismissible sheet" interaction `GroupSecuritySheet` ships (see
/// `GroupCallView.groupTrustBar`'s shield button / the new `showChatPanel`
/// toggle in the control row), reused verbatim for this new "chat" icon so
/// closing/minimizing it returns full attention to the video/participant
/// view WITHOUT losing the call — never a permanently-covering overlay.
///
/// REUSES the already-shipped group-chat pipeline end to end, does not
/// reinvent any of it:
///  - **text send** — the identical sequence `GroupChatScreen.
///    sendGroupOverWire` posts: `GroupChatService.shared.
///    pendingInitsAfterBootstrap` (sender_key_init fan-out over the 1:1
///    ratchet) then `.encryptForWire` (the 0xE4 seal), then the SAME two
///    `NotificationCenter` names (`AppState.groupSenderKeyCtlNotification`,
///    `AppState.groupMsgSendNotification`) `AppState.wireGroupChatFanOut`
///    already listens on and ships over the live WS as `group_msg_send`.
///    `GroupChatScreen` is a plain SwiftUI `View` struct with no
///    container/ViewModel to hang a shared method on (same reasoning
///    `AppState.notifyGroupComposerInput`'s own kdoc gives for ITS
///    placement), so this orchestration is duplicated here rather than
///    extracted — every call inside is to the SAME underlying services,
///    not a new implementation; zero new crypto.
///  - **attachment send** — `GroupAttachmentSender` (already a standalone
///    `@MainActor` class with zero View coupling — see its own header
///    comment) followed by the SAME seal+post sequence as the text path
///    (mirrors `GroupChatScreen.sendAttachmentOverWire`).
///  - **persistence + receive** — `GroupMessageStore`, written to by
///    `AppState`'s WS `group_msg_receive` handler REGARDLESS of which
///    screen is on top (verified: `handleIncomingGroupMessage` is reached
///    via a handler registered once on the WS client at login, not gated
///    on any active-screen check — only the local notification BANNER is
///    suppressed while a screen is "active", via `AppState.activeGroupHex`,
///    which this panel also sets/clears on appear/disappear, exactly like
///    `GroupChatScreen`). So a message sent or received while this panel is
///    CLOSED still lands here on next open, and the unread badge on the
///    toggle icon (`GroupCallView.chatUnreadCount`) is driven off the SAME
///    `GroupMessageStore.unreadCount(forGroupHex:)` the chat-list screen
///    (`ChatListScreen`) already uses — not a new unread concept.
///  - **bubble rendering** — reuses `GroupMessageBubble` verbatim (changed
///    from `private` to internal in `GroupChatScreen.swift` for exactly
///    this reuse — no rendering logic duplicated) plus the shared
///    `ImageBubbleContent`/`FileBubbleContent` components every other
///    bubble surface in the app already uses.
///
/// **Disabled state**: `groupIdDashed` is `""` for an ad-hoc group call
/// started from the contact picker with no persisted group behind it (see
/// `BCryptoGroupCallManager.IncomingGroupInvite.groupId` kdoc — already
/// documented as "empty for an ad-hoc call"). There is no `GroupRegistry`
/// roster / `GroupChatService` crypto state to encrypt a message against in
/// that case, so the panel shows an explanatory placeholder and sends
/// nothing, rather than silently failing every send attempt.
///
/// Deliberately NOT ported here (kept minimal for this pass): the group
/// typing indicator and the group-info sheet — neither was asked for on
/// this surface, and both would add real state-management surface for a
/// panel whose job is text+attachments in ONE view.
struct GroupCallChatPanel: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar
    @EnvironmentObject private var appState: AppState

    /// Dashed-UUID server wire id for the persisted group this call is
    /// bound to (see `GroupCallViewModel.activeGroupId` kdoc for how/when
    /// it's set). `""` == ad-hoc call, see the type doc comment above.
    let groupIdDashed: String
    let onDismiss: () -> Void

    @State private var messages: [GroupMessageRowUi] = []
    @State private var composerText: String = ""
    @State private var showingAttachChoice = false
    @State private var showingPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false

    /// Hex form (dashes stripped, lowercase) — the key space
    /// `GroupMessageStore`/`GroupRegistry`/`GroupChatService` all use.
    private var groupHex: String {
        groupIdDashed.isEmpty ? "" : groupIdDashed.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private var groupDisplayName: String {
        GroupRegistry.shared.entry(for: groupHex)?.name ?? "Chat di gruppo"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if groupHex.isEmpty {
                    unavailableState
                } else {
                    messageList
                    composer
                }
            }
            .background(scheme.background.ignoresSafeArea())
            .navigationTitle(groupHex.isEmpty ? "Chat" : groupDisplayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { onDismiss() }
                }
            }
        }
        // Mirrors GroupChatScreen.onAppear: mark this group "active" so
        // AppState suppresses the inbound-group notification banner while
        // the panel is open, load persisted history, re-kick any stalled
        // attachment download, and emit read receipts for inbound rows.
        .onAppear {
            guard !groupHex.isEmpty else { return }
            appState.activeGroupHex = groupHex
            reloadMessages()
            appState.retryPendingGroupAttachmentDownloads(groupHex: groupHex)
            appState.emitGroupReadReceipts(groupId: groupIdDashed)
        }
        .onDisappear {
            if appState.activeGroupHex == groupHex { appState.activeGroupHex = nil }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: GroupMessageStore.didChangeNotification)) { note in
            guard (note.userInfo?["groupHex"] as? String) == groupHex else { return }
            reloadMessages()
        }
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
    }

    // MARK: - Message list

    /// Same `deterministicGalleryId` mapping `GroupChatScreen` uses (a row
    /// id is usually a UUID string, but falls back to the raw
    /// `server_message_id` when the wire omits `client_msg_id` — see that
    /// file's `deterministicGalleryId(for:)` kdoc for the full reasoning).
    /// Duplicated (not shared) since that helper is `private` to
    /// `GroupChatScreen.swift` and this is pure id-derivation, not crypto.
    private static func deterministicGalleryId(for raw: String) -> UUID {
        if let u = UUID(uuidString: raw) { return u }
        let digest = SHA256.hash(data: Data(raw.utf8))
        let bytes = Array(digest.prefix(16))
        return bytes.withUnsafeBufferPointer { buf in
            NSUUID(uuidBytes: buf.baseAddress!) as UUID
        }
    }

    private var imageGalleryItems: [ImageGalleryItem] {
        messages.compactMap { m in
            guard m.attachmentKind == GroupAttachmentEnvelope.kindImage,
                  let path = m.mediaLocalPath, !path.isEmpty else { return nil }
            return ImageGalleryItem(id: Self.deterministicGalleryId(for: m.id), localPath: path)
        }
    }

    private var messageList: some View {
        let galleryItems = imageGalleryItems
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages) { msg in
                            GroupMessageBubble(message: msg, galleryItems: galleryItems)
                                .id(msg.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
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
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
    }

    /// Ad-hoc-call placeholder — see the type doc comment's "Disabled
    /// state" section.
    private var unavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.slash")
                .font(.system(size: 40))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Chat non disponibile")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Text("Questa chiamata non è collegata a un gruppo salvato: non c'è una chat cifrata a cui inviare messaggi.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            Button(action: { showingAttachChoice = true }) {
                Image(systemName: "paperclip")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Aggiungi allegato")

            TextField("",
                      text: $composerText,
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
                        Circle().fill(canSend ? scheme.primary : scheme.surfaceVariant)
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
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Load / render helpers (mirrors GroupChatScreen's identical methods)

    private func reloadMessages() {
        let stored = GroupMessageStore.shared.messages(forGroupHex: groupHex)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        messages = stored.map { m in
            GroupMessageRowUi(
                id: m.id,
                text: m.text,
                senderLabel: m.mine ? "Tu" : resolveMemberName(m.senderId),
                timestamp: f.string(from: m.ts),
                mine: m.mine,
                attachmentKind: m.attachmentKind,
                mediaMime: m.mediaMime,
                mediaLocalPath: m.mediaLocalPath,
                fileName: m.fileName,
                byteLength: m.byteLength,
                delivery: deliveryStatus(for: m))
        }
        // Viewing the panel == reading it, same as GroupChatScreen — also
        // clears the unread badge on the call-screen toggle icon (that
        // badge reads the same `unreadCount(forGroupHex:)` this marks).
        GroupMessageStore.shared.markRead(groupHex: groupHex)
    }

    private var memberIds: [String] {
        GroupRegistry.shared.entry(for: groupHex)?.members ?? []
    }

    private var otherGroupMemberIds: [String] {
        let selfId = AppState.currentUserIdSnapshot ?? ""
        return memberIds.filter { $0 != selfId && !$0.isEmpty }
    }

    /// Same WhatsApp-style ALL-members delivery threshold as
    /// `GroupChatScreen.deliveryStatus(for:)` — see that method's kdoc.
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

    private func resolveMemberName(_ userId: String) -> String {
        if let name = appState.cachedContacts.first(where: { $0.userId == userId })?.displayName,
           !name.isEmpty {
            return name
        }
        return userId.count > 12 ? String(userId.prefix(8)) + "…" : userId
    }

    // MARK: - Send: text (reuses GroupChatService + AppState's fan-out — see type doc)

    private func handleSend() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !groupHex.isEmpty else { return }
        composerText = ""

        let members = memberIds
        let selfId = AppState.currentUserIdSnapshot ?? "u-self"
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
            await sendTextOverWire(plaintext: trimmed, members: members, selfId: selfId, clientMsgId: clientMsgId)
        }
    }

    @MainActor
    private func sendTextOverWire(plaintext: String, members: [String], selfId: String, clientMsgId: String) async {
        let pendingInits = GroupChatService.shared.pendingInitsAfterBootstrap(
            groupId: groupHex, members: members, selfId: selfId)
        for init_ in pendingInits {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: ["recipient": init_.recipientId, "envelopeJson": init_.envelopeJson])
        }
        guard let sealed = GroupChatService.shared.encryptForWire(
            plaintext: plaintext, groupId: groupHex, members: members, selfId: selfId
        ) else {
            print("[GroupCallChatPanel] encrypt failed for group \(groupHex)")
            snackbar?.show(.init(text: "Messaggio non inviato", severity: .error))
            return
        }
        NotificationCenter.default.post(
            name: AppState.groupMsgSendNotification,
            object: nil,
            userInfo: [
                "groupId": groupIdDashed,
                "wire": sealed.wire,
                "clientMsgId": clientMsgId,
                "groupEpoch": Int(sealed.groupEpoch),
            ])
    }

    // MARK: - Send: attachments (reuses GroupAttachmentSender — see type doc)

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !groupHex.isEmpty else { return }
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

    private func handlePickedFile(_ result: Result<[URL], Swift.Error>) {
        guard case .success(let urls) = result, let url = urls.first, !groupHex.isEmpty else { return }
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

    @MainActor
    private func sendAttachmentOverWire(
        data: Data, mime: String, kind: String, filename: String, width: Int?, height: Int?
    ) async {
        let members = memberIds
        let selfId = AppState.currentUserIdSnapshot ?? "u-self"

        let prepared: GroupAttachmentSender.Prepared
        do {
            prepared = try await GroupAttachmentSender(appState: appState).prepare(
                data: data, mime: mime, kind: kind, filename: filename,
                caption: nil, width: width, height: height,
                members: members, selfId: selfId)
        } catch {
            snackbar?.show(.init(text: "Allegato non inviato — \(error.localizedDescription)",
                                 severity: .error, durationSeconds: 5))
            return
        }

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

        let pendingInits = GroupChatService.shared.pendingInitsAfterBootstrap(
            groupId: groupHex, members: members, selfId: selfId)
        for init_ in pendingInits {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: ["recipient": init_.recipientId, "envelopeJson": init_.envelopeJson])
        }

        guard let sealed = GroupChatService.shared.encryptForWire(
            plaintext: prepared.descriptorJson,
            groupId: groupHex, members: members, selfId: selfId
        ) else {
            print("[GroupCallChatPanel] attachment encrypt failed for group \(groupHex)")
            return
        }
        NotificationCenter.default.post(
            name: AppState.groupMsgSendNotification,
            object: nil,
            userInfo: [
                "groupId": groupIdDashed,
                "wire": sealed.wire,
                "clientMsgId": clientMsgId,
                "groupEpoch": Int(sealed.groupEpoch),
                "msgType": GroupAttachmentEnvelope.msgTypeAttachment,
            ])
    }
}
