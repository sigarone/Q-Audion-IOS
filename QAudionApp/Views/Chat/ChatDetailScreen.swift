import SwiftUI
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

    // MARK: - Local UI state (until engine exposes these fields)

    @State private var replyTarget: MessageComposer.ReplyTarget? = nil
    @State private var editingTarget: MessageComposer.EditingTarget? = nil
    @State private var actionTargetId: UUID? = nil

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
                    set: { container.composerText = $0 }
                ),
                editingTarget: editingTarget,
                replyTarget: replyTarget,
                onAttach: { /* TODO: attachment picker */ },
                onSend: handleSend,
                onCancelEdit: { editingTarget = nil },
                onCancelReply: { replyTarget = nil },
                onStartVoiceNote: { /* TODO: AVAudioRecorder start */ },
                onFinishVoiceNote: { /* TODO: AVAudioRecorder stop & send */ },
                onCancelVoiceNote: { /* TODO: AVAudioRecorder discard */ }
            )
        }
        .background(scheme.background)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: actionSheetBinding) { msgIdWrapper in
            BubbleActionSheet(
                isOwn: messageIsOwn(msgIdWrapper.id),
                isText: true,  // all messages are text in current model
                onReact: { _ in /* TODO: persist reaction */ },
                onEdit: { startEdit(messageId: msgIdWrapper.id) },
                onCopy: { copyMessage(messageId: msgIdWrapper.id) },
                onDeleteForAll: { /* TODO: delete-for-all RPC */ },
                onDeleteForMe: { /* TODO: delete-local */ }
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
                presenceDot: container.viewModel.isPeerOnline ? .online : .offline
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

            Button(action: { /* TODO: chat info menu */ }) {
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
                if let last = container.viewModel.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(for msg: Message) -> some View {
        let variant: MessageBubbleVariant = (msg.direction == .outgoing) ? .sent : .received
        let timeLabel = Self.timeFormatter.string(from: msg.sentAt)
        let delivery = mapDelivery(msg.status)

        MessageBubble(
            variant: variant,
            timeLabel: timeLabel,
            delivery: variant == .sent ? delivery : nil,
            replyQuote: nil,
            reactions: []
        ) {
            Text(msg.plaintext)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        // If we're editing, the engine has no edit RPC yet — treat it as
        // a no-op for the message list and just clear the local edit
        // banner. The composed text becomes a fresh outgoing message
        // (matches Android's stub behaviour today).
        if editingTarget != nil {
            editingTarget = nil
        }
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
