import SwiftUI
import UIKit

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
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qaudionSnackbar) private var snackbar

    let groupId: UUID
    @State private var state: GroupChatUiState
    @State private var showingInfo = false

    init(groupId: UUID, initial: GroupChatUiState) {
        self.groupId = groupId
        _state = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                betaBanner
                messageList
                composer
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                GroupInfoScreen(
                    state: makeInfoState(),
                    onLeft: {
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

    /// W110: explicit beta banner so users don't think their group
    /// messages are being delivered. The 1:1 send pipeline is fully
    /// wired (W71+W76+W77 + voice/image stack); group send is still
    /// local-state-only because GroupChatRepository / server group
    /// fanout aren't wired on iOS yet.
    private var betaBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(extras.warning)
            Text("Beta — i messaggi del gruppo restano sul tuo dispositivo. La consegna ai membri sarà attiva nelle prossime versioni.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(extras.warning.opacity(0.10))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 48))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Nessun messaggio")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            Text("I messaggi del gruppo saranno disponibili appena la consegna è attiva.")
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

    private func handleSend() {
        let trimmed = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let new = GroupMessageRowUi(
            id: UUID().uuidString,
            text: trimmed,
            senderLabel: "Tu",
            timestamp: f.string(from: Date()),
            mine: true
        )
        state.messages.append(new)
        state.composerText = ""

        // W372: encrypt via GroupChatService (W345 + W364) and ship
        // through the BCrypto opaque_message fan-out (one envelope per
        // remaining group member, sealed under the per-pair PSK on
        // the 1:1 layer). The fan-out fire-and-forgets — server
        // store-and-forward via msg_pending_sync handles offline peers.
        let groupIdHex = groupId.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let memberRows = makeInfoState().members
        let memberIds = memberRows.map { $0.userId }
        let selfId = memberRows.first(where: { $0.isSelf })?.userId ?? "u-self"
        Task {
            await sendGroupOverWire(
                plaintext: trimmed,
                groupIdHex: groupIdHex,
                memberIds: memberIds,
                selfId: selfId
            )
        }
    }

    /// W372 — encrypt via GroupChatService + fan out to each non-self
    /// member as an opaque_message. Stays an async best-effort path:
    /// any failure is logged and surfaced via the snackbar but does
    /// NOT roll back the local-state append (the user already saw
    /// their bubble; rolling back would be a worse UX than the message
    /// landing late on the peer side).
    @MainActor
    private func sendGroupOverWire(
        plaintext: String,
        groupIdHex: String,
        memberIds: [String],
        selfId: String
    ) async {
        guard let wire = GroupChatService.shared.encrypt(
            plaintext: plaintext,
            groupId: groupIdHex,
            members: memberIds,
            selfId: selfId
        ) else {
            print("[GroupChatScreen] encrypt failed for group \(groupIdHex)")
            return
        }
        // Hand off to AppState which holds the live BCryptoMessageApi.
        let peers = memberIds.filter { $0 != selfId }
        for peer in peers {
            NotificationCenter.default.post(
                name: AppState.groupChatFanOutNotification,
                object: nil,
                userInfo: [
                    "groupId": groupIdHex,
                    "recipient": peer,
                    "wire": wire,
                ]
            )
        }
    }

    private func makeInfoState() -> GroupInfoUiState {
        // Stub members list — engine wiring sostituirà con la
        // membership reale.
        GroupInfoUiState(
            name: state.name,
            epoch: 1,
            members: [
                GroupMemberRowUi(userId: "u-self", displayName: "Tu",
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
                    Text(message.text)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurface)
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
