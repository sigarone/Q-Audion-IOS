import SwiftUI
import QAudionEngine

@MainActor
final class ContactsListContainer: ObservableObject {
    @Published var viewModel: ContactsListViewModel
    @Published private(set) var isRefreshing: Bool = false
    @Published var errorMessage: String?

    private let appState: AppState?
    private let store: ContactsStore
    private let service: ContactsRefreshService?

    init(appState: AppState? = nil, store: ContactsStore = ContactsStore()) {
        self.appState = appState
        self.store = store
        if let s = appState {
            self.service = ContactsRefreshService(appState: s, store: store)
        } else {
            self.service = nil
        }
        // Load from local store first; fall back to mock if empty.
        let stored = store.load()
        if stored.isEmpty {
            self.viewModel = .mock
        } else {
            self.viewModel = ContactsListViewModel(items: stored.map { sc in
                ContactsListViewModel.Item(
                    userId: sc.userId, displayName: sc.displayName,
                    phoneHash: sc.phoneHash, avatarUrl: sc.avatarUrl,
                    isOnline: false,
                    unreadMessageCount: 0,
                    isVerified: sc.isVerified
                )
            })
        }
    }

    func setSearchQuery(_ query: String) {
        viewModel = ContactsListViewModel(items: viewModel.items, searchQuery: query)
    }

    func refresh() {
        guard let svc = service else { return }
        Task {
            await MainActor.run { self.isRefreshing = true; self.errorMessage = nil }
            do {
                // Phonebook integration deferred — pass empty until integrated.
                _ = try await svc.refresh(phonesToCheck: [])
                let stored = self.store.load()
                await MainActor.run {
                    self.viewModel = ContactsListViewModel(
                        items: stored.map { sc in
                            ContactsListViewModel.Item(
                                userId: sc.userId, displayName: sc.displayName,
                                phoneHash: sc.phoneHash, avatarUrl: sc.avatarUrl,
                                isOnline: false,
                                unreadMessageCount: 0,
                                isVerified: sc.isVerified
                            )
                        },
                        searchQuery: self.viewModel.searchQuery
                    )
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isRefreshing = false
                }
            }
        }
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
