import SwiftUI
import QAudionEngine

struct ConversationListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var showCompose = false
    @State private var newContactId = ""

    private var filteredConversations: [Conversation] {
        if searchText.isEmpty { return appState.conversations }
        return appState.conversations.filter {
            $0.contactName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                if filteredConversations.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredConversations) { conversation in
                        NavigationLink {
                            ChatView(
                                conversationId: conversation.id,
                                contactName: conversation.contactName
                            )
                        } label: {
                            conversationRow(conversation)
                        }
                        .listRowBackground(Color(white: 0.10))
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search conversations")
            .listStyle(.plain)

            // MARK: - Compose Button
            Button {
                showCompose = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                    .shadow(color: .cyan.opacity(0.3), radius: 8, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
        }
        .navigationTitle("Messages")
        .alert("New Message", isPresented: $showCompose) {
            TextField("Contact ID", text: $newContactId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { newContactId = "" }
            Button("Start Chat") {
                guard !newContactId.isEmpty else { return }
                appState.createConversation(contactId: newContactId)
                newContactId = ""
            }
        } message: {
            Text("Enter the contact ID to start an encrypted conversation.")
        }
    }

    // MARK: - Conversation Row

    private func conversationRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(avatarColor(for: conversation.contactName))
                    .frame(width: 48, height: 48)
                Text(String(conversation.contactName.prefix(1)).uppercased())
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.contactName)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    if conversation.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Text(conversation.lastMessageTime, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                HStack {
                    Text(conversation.lastMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.cyan))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "message.badge.filled.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No conversations")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Tap the compose button to start chatting")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 40)
            Spacer()
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Helpers

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .cyan, .purple, .orange, .pink, .green, .indigo, .teal]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}
