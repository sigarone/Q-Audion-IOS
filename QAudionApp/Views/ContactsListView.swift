import SwiftUI
import QAudionEngine

@MainActor
final class ContactsListContainer: ObservableObject {
    @Published var viewModel: ContactsListViewModel

    init(initial: ContactsListViewModel = .mock) {
        self.viewModel = initial
    }

    func setSearchQuery(_ query: String) {
        viewModel = ContactsListViewModel(items: viewModel.items, searchQuery: query)
    }

    func refresh() {
        // Future: fetch from server. For now, no-op (uses mock).
    }
}

struct ContactsListView: View {
    @StateObject private var container: ContactsListContainer
    @State private var searchText: String = ""

    init() {
        _container = StateObject(wrappedValue: ContactsListContainer())
    }

    var body: some View {
        List {
            ForEach(container.viewModel.filteredItems, id: \.userId) { item in
                NavigationLink(destination: detailView(for: item)) {
                    contactRow(item)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search contacts")
        .onChange(of: searchText) { _, newValue in
            container.setSearchQuery(newValue)
        }
        .navigationTitle("Contacts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Scan QR", systemImage: "qrcode.viewfinder") { }
                    Button("Add via NFC", systemImage: "wave.3.right") { }
                    Button("Add by phone", systemImage: "phone.badge.plus") { }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable { container.refresh() }
    }

    @ViewBuilder
    private func detailView(for item: ContactsListViewModel.Item) -> some View {
        // Map ContactsListViewModel.Item → ContactDetailViewModel for the detail view.
        let detail = ContactDetailViewModel(
            userId: item.userId,
            displayName: item.displayName,
            phoneHash: item.phoneHash,
            fingerprint: "????.????.????.????",  // TODO: lookup from key vault
            avatarUrl: item.avatarUrl,
            trustLevel: item.isVerified ? .sasVerified : .unverified,
            isBlocked: false,
            lastSeen: nil,
            recentCallCount: 0,
            unreadMessageCount: item.unreadMessageCount
        )
        ContactDetailView(viewModel: detail)
    }

    private func contactRow(_ item: ContactsListViewModel.Item) -> some View {
        HStack(spacing: 12) {
            avatar(item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName).font(.body.weight(.medium))
                    if item.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(item.isOnline ? "Online" : "Offline")
                    .font(.caption)
                    .foregroundStyle(item.isOnline ? .green : .secondary)
            }
            Spacer()
            if item.unreadMessageCount > 0 {
                Text("\(item.unreadMessageCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func avatar(_ item: ContactsListViewModel.Item) -> some View {
        Group {
            if let url = item.avatarUrl {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    placeholder(item)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                placeholder(item)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
    }

    private func placeholder(_ item: ContactsListViewModel.Item) -> some View {
        Circle()
            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 40, height: 40)
            .overlay(
                Text(initials(item.displayName))
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            )
    }

    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ")
        return String(words.prefix(2).compactMap { $0.first }).uppercased()
    }
}

#Preview {
    NavigationStack { ContactsListView() }
}
