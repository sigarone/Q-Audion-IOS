import SwiftUI
import QAudionEngine

struct ConversationListView: View {
    @StateObject private var container = ConversationListContainer()
    @State private var searchText: String = ""
    @State private var showingNewConversation = false

    var body: some View {
        Group {
            if container.viewModel.items.isEmpty && container.searchText.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        .searchable(text: $searchText, prompt: "Search conversations")
        .onChange(of: searchText) { _, newValue in
            container.setSearchQuery(newValue)
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingNewConversation = true }) {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .refreshable { container.loadFromStore() }
        .sheet(isPresented: $showingNewConversation) {
            NavigationStack {
                ContactsListView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingNewConversation = false }
                        }
                    }
            }
        }
    }

    private var conversationList: some View {
        List {
            ForEach(container.viewModel.filteredItems, id: \.conversationId) { item in
                NavigationLink(destination: chatDestination(for: item)) {
                    conversationRow(item)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        container.deleteConversation(conversationId: item.conversationId)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        container.togglePinned(conversationId: item.conversationId)
                    } label: {
                        Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin")
                    }
                    .tint(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func chatDestination(for item: ConversationListViewModel.Item) -> some View {
        ChatView(
            conversationId: item.conversationId,
            peerUserId: item.peerUserId,
            peerDisplayName: item.peerDisplayName
        )
    }

    private func conversationRow(_ item: ConversationListViewModel.Item) -> some View {
        HStack(spacing: 12) {
            avatar(for: item)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(item.peerDisplayName)
                        .font(.body.weight(.semibold))
                    if item.kind == .group {
                        Image(systemName: "person.3.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.lastActivity, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let preview = item.lastMessagePreview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if item.unreadCount > 0 {
                Text("\(item.unreadCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func avatar(for item: ConversationListViewModel.Item) -> some View {
        let gradient: LinearGradient = {
            if item.kind == .group {
                return LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                return LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }()
        return Circle()
            .fill(gradient)
            .frame(width: 44, height: 44)
            .overlay(
                Group {
                    if item.kind == .group {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.white)
                    } else {
                        Text(initials(item.peerDisplayName))
                            .font(.body.bold())
                            .foregroundStyle(.white)
                    }
                }
            )
    }

    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ")
        return String(words.prefix(2).compactMap { $0.first }).uppercased()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No conversations yet")
                .font(.title3.bold())
            Text("Tap the compose button in the top-right to start a chat with a contact.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

#Preview {
    NavigationStack { ConversationListView() }
}
