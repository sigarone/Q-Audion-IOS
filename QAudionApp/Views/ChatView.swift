import SwiftUI
import QAudionEngine

struct ChatView: View {

    @StateObject private var container: ChatContainer
    @EnvironmentObject private var appState: AppState

    // MARK: - Inits

    /// Primary init: UUID-based conversation (W11.A ConversationStore path).
    init(conversationId: UUID, peerUserId: String, peerDisplayName: String) {
        _container = StateObject(wrappedValue: ChatContainer(
            conversationId: conversationId,
            peerUserId: peerUserId,
            peerDisplayName: peerDisplayName
        ))
    }

    /// Back-compat init for existing callers that pass a String id (e.g. ConversationListView).
    /// Converts the string to a UUID — uses it directly if it's a valid UUID string,
    /// otherwise derives a deterministic UUID via a simple name hash so the
    /// conversation persists across app launches with the same contactId.
    init(conversationId: String, contactName: String) {
        let uuid = UUID(uuidString: conversationId) ?? ChatView.deterministicUUID(from: conversationId)
        _container = StateObject(wrappedValue: ChatContainer(
            conversationId: uuid,
            peerUserId: conversationId,
            peerDisplayName: contactName
        ))
    }

    /// Zero-arg convenience for SwiftUI previews; uses the mock conversation.
    init() {
        let mockConv = ChatViewModel.mock.conversation
        _container = StateObject(wrappedValue: ChatContainer(
            conversationId: mockConv.id,
            peerUserId: mockConv.peerUserId,
            peerDisplayName: mockConv.peerDisplayName
        ))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            encryptionBanner
            messagesList
            composer
        }
        .background(Color(white: 0.06))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if container.viewModel.conversation.kind == .group,
                   let participants = container.viewModel.participants {
                    VStack(spacing: 1) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Text(container.viewModel.conversation.peerDisplayName)
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        Text("\(participants.count) members")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(container.viewModel.conversation.peerDisplayName)
                            .font(.headline)
                            .foregroundStyle(.white)
                        if container.viewModel.isPeerOnline {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                        }
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    // Initiate a voice call to the conversation peer. Group
                    // conversations skip this entry: group calling lives on
                    // a separate header surface (GroupCallView).
                    let peer = container.viewModel.conversation
                    guard peer.kind != .group else { return }
                    Task {
                        await appState.startCall(
                            contactId: peer.peerUserId,
                            video: false
                        )
                    }
                } label: {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(.cyan)
                }
                .disabled(container.viewModel.conversation.kind == .group)
            }
        }
    }

    // MARK: - Subviews

    private var encryptionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.caption2)
            Text("End-to-end encrypted")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundStyle(.green.opacity(0.8))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.08))
    }

    private var messagesList: some View {
        let isGroup = container.viewModel.conversation.kind == .group
        let participants = container.viewModel.participants
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(container.viewModel.messages) { msg in
                        MessageBubbleView(
                            message: msg,
                            isGroup: isGroup,
                            senderName: participants?.first(where: { $0.userId == msg.senderUserId })?.displayName
                        )
                        .id(msg.id)
                    }
                    if container.viewModel.isPeerTyping {
                        typingIndicator
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: container.viewModel.messages.count) { _ in
                // Single-param form for iOS 16 compat.
                if let last = container.viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = container.viewModel.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var typingIndicator: some View {
        HStack {
            Text("\(container.viewModel.conversation.peerDisplayName) is typing…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $container.composerText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.14))
                .cornerRadius(20)
                .foregroundStyle(.white)

            Button(action: container.sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        container.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? .gray : .cyan
                    )
            }
            .disabled(container.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.10))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Helpers

    /// Derives a deterministic UUID from an arbitrary string via a simple FNV-1a hash.
    /// The result is stable across launches for the same input.
    private static func deterministicUUID(from string: String) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        // Build 16 bytes: 8 bytes from hash, 8 bytes from bit-complement (for spread).
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8((hash >> (i * 8)) & 0xFF)
        }
        let comp = ~hash
        for i in 0..<8 {
            bytes[8 + i] = UInt8((comp >> (i * 8)) & 0xFF)
        }
        // Force version 4, variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2],  bytes[3],
            bytes[4], bytes[5], bytes[6],  bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

#Preview {
    // Preview needs an AppState in the environment because the toolbar
    // phone button calls appState.startCall.
    NavigationStack { ChatView() }
        .environmentObject(AppState())
}
