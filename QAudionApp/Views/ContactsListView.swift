import SwiftUI
import QAudionEngine

@MainActor
final class ContactsListContainer: ObservableObject {
    @Published var viewModel: ContactsListViewModel
    @Published private(set) var isRefreshing: Bool = false
    @Published var errorMessage: String?
    @Published var scanProgress: PhonebookSyncCoordinator.ScanProgress?

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

    /// Persists a QR-scanned payload as a verified local contact. Identity
    /// and device-link payloads both carry a userId + pubkey so we can render
    /// them in the contacts list immediately; fast-setup is onboarding-time
    /// only and is ignored here (the OnboardingFlow path will consume it).
    /// Returns `true` if a new row was inserted (or an existing one updated).
    @discardableResult
    func addScannedContact(_ decoded: QrPayloadRouter.Decoded) -> Bool {
        let userId: String
        let displayName: String
        switch decoded {
        case .identity(let id):
            userId = id.userId
            displayName = id.userId
        case .deviceLink(let dl):
            userId = dl.userId
            displayName = dl.userId
        case .fastSetup, .invalid, .unknown:
            return false
        }
        let contact = ContactsStore.StoredContact(
            userId: userId,
            displayName: displayName,
            phoneHash: "",         // phone not present in QR payloads
            avatarUrl: nil,
            lastSeen: nil,
            isVerified: true        // in-person scan ⇒ verified
        )
        store.upsert(contact)
        // Refresh the in-memory view-model from the store so the new row
        // shows up immediately in the list.
        let stored = store.load()
        viewModel = ContactsListViewModel(
            items: stored.map { sc in
                ContactsListViewModel.Item(
                    userId: sc.userId, displayName: sc.displayName,
                    phoneHash: sc.phoneHash, avatarUrl: sc.avatarUrl,
                    isOnline: false,
                    unreadMessageCount: 0,
                    isVerified: sc.isVerified
                )
            },
            searchQuery: viewModel.searchQuery
        )
        return true
    }

    func refresh() {
        guard let svc = service else { return }
        Task {
            await MainActor.run {
                self.isRefreshing = true
                self.errorMessage = nil
                self.scanProgress = nil
            }
            do {
                let stored = try await svc.refreshFromPhonebook { progress in
                    Task { @MainActor in self.scanProgress = progress }
                }
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
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""
    @State private var showingQrScanner: Bool = false
    @State private var showingMyIdentity: Bool = false
    @State private var lastScanResult: ScanResultBanner?

    init() {
        _container = StateObject(wrappedValue: ContactsListContainer())
    }

    /// Transient banner shown after a successful QR scan so the user gets
    /// confirmation that the contact was added (or that the payload was
    /// rejected). Auto-dismisses after a short delay.
    private struct ScanResultBanner: Equatable {
        let title: String
        let detail: String
        let isError: Bool
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
        .onChange(of: searchText) { newValue in
            // Single-param form for iOS 16 compat.
            container.setSearchQuery(newValue)
        }
        .navigationTitle("Contacts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Scan QR", systemImage: "qrcode.viewfinder") {
                        showingQrScanner = true
                    }
                    Button("Show my identity", systemImage: "qrcode") {
                        showingMyIdentity = true
                    }
                    Button("Add via NFC", systemImage: "wave.3.right") { }
                    Button("Add by phone", systemImage: "phone.badge.plus") { }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable { container.refresh() }
        .overlay(alignment: .top) {
            if let progress = container.scanProgress, container.isRefreshing {
                scanProgressBanner(progress)
            } else if let banner = lastScanResult {
                scanResultBannerView(banner)
            }
        }
        .sheet(isPresented: $showingMyIdentity) {
            MyIdentityQrSheet(appState: appState)
        }
        .sheet(isPresented: $showingQrScanner) {
            QrScannerSheet(onAccepted: { decoded in
                let added = container.addScannedContact(decoded)
                if added {
                    let id: String = {
                        switch decoded {
                        case .identity(let i): return i.userId
                        case .deviceLink(let d): return d.userId
                        default: return "?"
                        }
                    }()
                    lastScanResult = ScanResultBanner(
                        title: "Contact added",
                        detail: id,
                        isError: false
                    )
                } else {
                    lastScanResult = ScanResultBanner(
                        title: "Scan ignored",
                        detail: "Payload not supported as a contact",
                        isError: true
                    )
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if lastScanResult != nil { lastScanResult = nil }
                }
            })
        }
    }

    private func scanResultBannerView(_ banner: ScanResultBanner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                Text(banner.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.systemBackground).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 2, y: 1)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.2), value: lastScanResult)
    }

    private func scanProgressBanner(_ p: PhonebookSyncCoordinator.ScanProgress) -> some View {
        HStack {
            ProgressView().scaleEffect(0.7)
            Text("Scanning phonebook: \(p.processedContacts) / \(p.totalContacts) — found \(p.resolvedUserCount) Q-Audion users")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color(.systemBackground).opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
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
    // Preview needs an AppState in the environment because the "+" menu
    // presents MyIdentityQrSheet which requires it.
    NavigationStack { ContactsListView() }
        .environmentObject(AppState())
}
