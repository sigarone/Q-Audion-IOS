import SwiftUI
import Combine
import QAudionEngine

@MainActor
final class ContactsListContainer: ObservableObject {
    @Published var viewModel: ContactsListViewModel
    @Published private(set) var isRefreshing: Bool = false
    @Published var errorMessage: String?
    @Published var scanProgress: PhonebookSyncCoordinator.ScanProgress?

    private var appState: AppState?
    private let store: ContactsStore
    private var service: ContactsRefreshService?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState? = nil, store: ContactsStore = ContactsStore()) {
        self.appState = appState
        self.store = store
        if let s = appState {
            self.service = ContactsRefreshService(appState: s, store: store)
        } else {
            self.service = nil
        }
        // W73: load from local store. Empty list = empty list — DO NOT
        // populate with `.mock` (Mario Rossi / Anna Bianchi placeholders
        // that surfaced as "fake contacts" during the first end-to-end
        // QA pass). The empty-state UI in ContactsScreen handles the
        // "Nessun contatto" copy.
        let stored = store.load()
        // W-EXTPREFIX consolidation (2026-07-29): `displayName` used to be
        // `sc.displayName` verbatim — a stale "Phone #100"/"New User" row
        // rendered as-is everywhere this view model feeds (ContactsScreen,
        // the new-conversation contact picker). Resolved through the
        // canonical `DisplayName.forUser` instead, with `contacts: stored`
        // so it also picks up `sc`'s own structured `extension`/
        // `phoneNumber` fields for the bare-digit/phone fallback.
        self.viewModel = ContactsListViewModel(items: stored.map { sc in
            ContactsListViewModel.Item(
                userId: sc.userId,
                displayName: DisplayName.forUser(sc.userId, contacts: stored),
                phoneHash: sc.phoneHash, avatarUrl: sc.avatarUrl,
                isOnline: false,
                unreadMessageCount: 0,
                isVerified: sc.isVerified,
                extension: sc.`extension`
            )
        })
        // 2026-07-30 fix (real device evidence: a contact whose ONLY known
        // field is the extension shows the bare extension forever — server
        // display_name "Pavel Ivanov" never surfaces, contact detail's
        // METADATI stays permanently blank). `DisplayName.forUser`'s async
        // enrichment (`NameResolutionService.ensureResolved` →
        // `enrichFromCallProfile`, the only path that fetches the server
        // profile and persists name/phone) only fires on a tier-6 miss —
        // never here, since tier 4 (bare extension, always known once a
        // contact has one) succeeds first. This list — unlike the in-call
        // screens fixed earlier — never called `ensureResolved` at all, so
        // enrichment for a contact reached only by extension never had a
        // chance to run. Kick it explicitly for every row (cheap — the
        // call is internally deduped + cooldown-gated) and re-render via
        // `.contactsDidChange` once it lands.
        for sc in stored {
            NameResolutionService.shared.ensureResolved(userId: sc.userId)
        }
        NotificationCenter.default.publisher(for: .contactsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadFromStore() }
            .store(in: &cancellables)
    }

    /// Re-reads the store and rebuilds the view model, preserving the
    /// current search query — shared by the `.contactsDidChange` observer
    /// above and any other "the persisted contacts changed under us" path.
    private func reloadFromStore() {
        let stored = store.load()
        viewModel = ContactsListViewModel(
            items: stored.map { sc in
                ContactsListViewModel.Item(
                    userId: sc.userId,
                    displayName: DisplayName.forUser(sc.userId, contacts: stored),
                    phoneHash: sc.phoneHash, avatarUrl: sc.avatarUrl,
                    isOnline: false,
                    unreadMessageCount: 0,
                    isVerified: sc.isVerified,
                    extension: sc.`extension`
                )
            },
            searchQuery: viewModel.searchQuery
        )
    }

    func setSearchQuery(_ query: String) {
        viewModel = ContactsListViewModel(items: viewModel.items, searchQuery: query)
    }

    /// Returns the 32B X25519 pubkey for a stored contact, or nil if unknown.
    /// Forwarded straight to ContactsStore so the caller (e.g. detail view)
    /// can compute a canonical fingerprint without depending on the engine
    /// store directly.
    func lookupPubkey(userId: String) -> Data? {
        store.findPubkey(userId: userId)
    }

    /// Late-binds an AppState into the container after construction so the
    /// view can pull AppState from `@EnvironmentObject` and pass it down
    /// without forcing every call site (sheet presenters, previews) to
    /// inject one upfront. Idempotent: calling with the same AppState is
    /// a no-op; calling with a different AppState rebuilds the service.
    func attach(_ state: AppState) {
        if self.appState === state { return }
        self.appState = state
        self.service = ContactsRefreshService(appState: state, store: store)
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
        let pubkey: Data
        switch decoded {
        case .identity(let id):
            userId = id.userId
            // W-UUIDSWEEP root cause: this used to persist the RAW 36-char
            // userId as the contact's displayName — the UUID then rendered
            // as the contact's NAME everywhere downstream (contacts list,
            // chat list, call screens, CarPlay). Persist the humane short
            // fallback instead; the server-lookup recovery (InCallContainer)
            // and any later rename upgrade it to the real name.
            displayName = DisplayName.shortUserFallback(id.userId)
            pubkey = id.pubkey
        case .deviceLink(let dl):
            userId = dl.userId
            displayName = DisplayName.shortUserFallback(dl.userId)
            pubkey = dl.pubkey
        case .groupInvite(let invite):
            // W68c: invece di no-op, persistiamo la pending invite in
            // UserDefaults via `PendingGroupInviteStore`. Quando il
            // backend esporrà `POST /groups/:id/join`, l'app può
            // replay-are tutte le pending. Per ora il side-effect
            // visibile per l'utente è l'incremento del counter
            // (visibile in Diagnostica W48 quando wirato).
            PendingGroupInviteStore.append(from: invite)
            // W70: server endpoint live → replay subito invece di
            // attendere il prossimo login. Best-effort, se 401/5xx la
            // pending resta nel local store per il replay successivo.
            if let appState = self.appState,
               let sync = TrackBSyncService.from(serverUrl: appState.serverUrl, token: appState.authService.loadToken()) {
                Task { _ = await sync.replayPendingGroupInvites() }
            }
            return false  // non aggiunto come contatto — è un gruppo
        case .fastSetup, .invalid, .unknown:
            // fastSetup è onboarding-time, gestito da OnboardingFlow.
            return false
        }
        let contact = ContactsStore.StoredContact(
            userId: userId,
            displayName: displayName,
            phoneHash: "",         // phone not present in QR payloads
            avatarUrl: nil,
            lastSeen: nil,
            isVerified: true,       // in-person scan ⇒ verified
            pubkey: pubkey          // 32B X25519, source of canonical fingerprint
        )
        store.upsert(contact)
        // W77: kick off the pairwise PSK handshake so future chats with
        // this contact use a real shared secret instead of the
        // deterministic fallback. Fire-and-forget; the response (ACCEPT)
        // arrives via WS opaque_message and lands in the keychain.
        if let appState = self.appState {
            appState.triggerKeyExchange(with: userId, force: false)
        }
        // Refresh the in-memory view-model from the store so the new row
        // shows up immediately in the list.
        reloadFromStore()
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
                _ = try await svc.refreshFromPhonebook { progress in
                    Task { @MainActor in self.scanProgress = progress }
                }
                await MainActor.run {
                    self.reloadFromStore()
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
    @State private var showingNfcPair: Bool = false
    @State private var showingPhonebookImport: Bool = false
    @State private var lastScanResult: ScanResultBanner?
    @State private var showingGroupCallPicker: Bool = false
    @Environment(\.dismiss) private var dismiss

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
            // W-ORPHANPEER — this list is also the new-chat picker, so it
            // must not offer accounts that no longer exist. Read-time filter;
            // see the note in ContactsScreen.allList for why not in the container.
            ForEach(
                container.viewModel.filteredItems
                    .filter { !shouldHideContact(appState.orphanPeerIds.contains($0.userId)) },
                id: \.userId
            ) { item in
                NavigationLink(destination: detailView(for: item)) {
                    contactRow(item)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Cerca contatti")
        .onChange(of: searchText) { newValue in
            // Single-param form for iOS 16 compat.
            container.setSearchQuery(newValue)
        }
        .navigationTitle("Contatti")
        .toolbar {
            // W-GRPUI: real entry point to start a group call — mirrors
            // Android's HomeShell `onStartGroupCall` (contacts tab →
            // multi-select → GroupCallController.createCall). Previously
            // GroupCallController had zero UI reachability on iOS.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingGroupCallPicker = true
                } label: {
                    Image(systemName: "person.2.fill")
                }
                .disabled(container.viewModel.items.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Scansiona QR", systemImage: "qrcode.viewfinder") {
                        showingQrScanner = true
                    }
                    Button("Mostra la mia identità", systemImage: "qrcode") {
                        showingMyIdentity = true
                    }
                    Button("Aggiungi via NFC", systemImage: "wave.3.right") {
                        showingNfcPair = true
                    }
                    Button("Importa dal telefono", systemImage: "phone.badge.plus") {
                        showingPhonebookImport = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingGroupCallPicker) {
            GroupCallContactPickerSheet(
                // W-ORPHANPEER — group-call picker: a reach surface.
                contacts: container.viewModel.items
                    .filter { !shouldHideContact(appState.orphanPeerIds.contains($0.userId)) },
                onStart: { selectedIds, video in
                    showingGroupCallPicker = false
                    appState.groupCallController?.createCall(
                        invitees: selectedIds,
                        callType: video ? "video" : "audio")
                }
            )
        }
        .refreshable { container.refresh() }
        .onAppear {
            container.attach(appState)
            appState.presenceService.observeCallState(
                callContactId: appState.$callContactId.eraseToAnyPublisher(),
                isInCall: appState.$isInCall.eraseToAnyPublisher()
            )
        }
        // When a chat deep-link is set (e.g. user tapped Chat in ContactDetailView),
        // dismiss this sheet so ChatListScreen can navigate to the conversation.
        .onChange(of: appState.pendingDeepLinkConversationId) { newId in
            if newId != nil { dismiss() }
        }
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
        .sheet(isPresented: $showingNfcPair) {
            NavigationStack {
                NfcExchangeView()
                    .navigationTitle("Pair via NFC")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fatto") { showingNfcPair = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingPhonebookImport) {
            NavigationStack {
                PhonebookImportView(appState: appState)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fatto") { showingPhonebookImport = false }
                        }
                    }
            }
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
            Text("Scansione rubrica: \(p.processedContacts) / \(p.totalContacts) — trovati \(p.resolvedUserCount) utenti Q-Audion")
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
        let pubkey = container.lookupPubkey(userId: item.userId)
        let fingerprint: String = {
            guard let pk = pubkey else { return "????.????.????.????" }
            return (try? Fingerprint.format(pubkey: pk)) ?? "????.????.????.????"
        }()
        let detail = ContactDetailViewModel(
            userId: item.userId,
            displayName: item.displayName,
            phoneHash: item.phoneHash,
            fingerprint: fingerprint,
            avatarUrl: item.avatarUrl,
            trustLevel: item.isVerified ? .sasVerified : .unverified,
            isBlocked: false,
            lastSeen: nil,
            recentCallCount: 0,
            unreadMessageCount: item.unreadMessageCount
        )
        ContactDetailView(
            viewModel: detail,
            onCall: {
                Task { await appState.startCall(contactId: item.userId, video: false) }
            },
            onChat: {
                openOrCreateChat(peerUserId: item.userId, displayName: item.displayName)
            },
            onVerifySas: nil,
            onBlock: {
                BlockedContactsStore.add(item.userId)
            },
            onDelete: {
                ContactsStore().remove(userId: item.userId)
                container.refresh()
            }
        )
    }

    /// Find existing or create new conversation for a peer, then set the deep-link
    /// so ChatListScreen navigates to it. ContactsListView auto-dismisses via onChange.
    private func openOrCreateChat(peerUserId: String, displayName: String) {
        let store = ConversationStore()
        let convId: UUID
        if let existing = store.loadConversations().first(where: { $0.peerUserId == peerUserId }) {
            convId = existing.id
        } else {
            let newConv = Conversation(
                id: UUID(),
                peerUserId: peerUserId,
                peerDisplayName: displayName,
                lastMessagePreview: nil,
                lastActivity: Date(),
                unreadCount: 0,
                pinned: false
            )
            store.upsertConversation(newConv)
            convId = newConv.id
        }
        appState.pendingDeepLinkConversationId = convId
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
                // W445: extended presence label — shows "In chiamata",
                // "Non disturbare", etc. when the server or call-state
                // inference provides a richer state than binary online/offline.
                presenceLabel(for: item)
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

    // MARK: - W445 extended presence helpers (CLAUDE.md §13: pre-bind locals)

    @ViewBuilder
    private func presenceLabel(for item: ContactsListViewModel.Item) -> some View {
        let p = appState.presenceService.extendedPresence(for: item.userId)
        let text: String = presenceLabelText(p, isOnline: item.isOnline)
        let color: Color = presenceLabelColor(p, isOnline: item.isOnline)
        Text(text).font(.caption).foregroundStyle(color)
    }

    private func presenceLabelText(_ p: ExtendedPresence, isOnline: Bool) -> String {
        if p == .unknown { return isOnline ? "Online" : "Offline" }
        return p.label.isEmpty ? (isOnline ? "Online" : "Offline") : p.label
    }

    private func presenceLabelColor(_ p: ExtendedPresence, isOnline: Bool) -> Color {
        switch p {
        case .online:        return .green
        case .inCall:        return Color(hex: 0xB388FF)
        case .doNotDisturb:  return Color(hex: 0xF2B73A)
        case .unknown:       return isOnline ? .green : .secondary
        default:             return .secondary
        }
    }

    @ViewBuilder
    private func presenceDot(for item: ContactsListViewModel.Item) -> some View {
        let p = appState.presenceService.extendedPresence(for: item.userId)
        switch p {
        case .online:
            Circle().fill(Color.green).frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        case .inCall:
            ZStack {
                Circle().fill(Color(hex: 0xB388FF)).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: "phone.fill")
                    .font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
            }
        case .doNotDisturb:
            ZStack {
                Circle().fill(Color(hex: 0xF2B73A)).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: "moon.fill")
                    .font(.system(size: 5, weight: .bold)).foregroundStyle(.white)
            }
        default:
            EmptyView()
        }
    }

    private func avatar(_ item: ContactsListViewModel.Item) -> some View {
        let blocked = BlockedContactsStore.isBlocked(item.userId)
        return Group {
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
        .opacity(blocked ? 0.4 : 1.0)
        .overlay(alignment: .bottomTrailing) {
            if blocked {
                Image(systemName: "circle.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .background(Circle().fill(.white).padding(-1))
            } else {
                // W445: extended presence dot. Only shown when there is
                // a visible state (.online / .inCall / .doNotDisturb).
                // .offline / .unknown / .invisible render no dot.
                presenceDot(for: item)
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
