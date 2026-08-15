import SwiftUI
import QAudionEngine

/// Top-level Contacts screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-contacts/.../ContactsScreen.kt`.
///
/// Layout (top → bottom):
///   1. **Top bar** "Contatti" + trailing `person.badge.plus` (Aggiungi).
///   2. **Search field** — capsule, "Cerca contatti o scopri tramite hash…"
///      placeholder, magnifying-glass leading icon.
///   3. **Tab row** — TUTTI / SCOPRI / BLOCCATI, monospace 1.5sp tracking,
///      selected variant has `primary @ 0.18α` fill + `primary` border.
///   4. **List** — sectioned by tab content:
///        TUTTI:    "ONLINE · n/m" header → online contacts → all others
///        SCOPRI:   import-rubrica card placeholder
///        BLOCCATI: blocked contacts list
///
/// Reuses the existing `ContactsListContainer` (no engine-data change).
/// The legacy `ContactsListView` is kept alive (still used by the new
/// conversation sheet) — this screen replaces only the Contacts tab in
/// `HomeView`. SCOPRI / BLOCCATI tabs are visual placeholders until the
/// engine exposes the import + block APIs to iOS.
struct ContactsScreen: View {
    @StateObject private var container: ContactsListContainer
    @EnvironmentObject private var appState: AppState

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    @State private var searchText: String = ""
    @State private var selectedTab: Tab = .all
    @State private var showingNewContact: Bool = false
    /// W58: ordinamento corrente della lista TUTTI. Persisted in
    /// UserDefaults così la scelta sopravvive ai riavvi.
    @State private var sortMode: SortMode = SortMode.loadFromDefaults()
    /// Locally persisted blocked contact IDs — refreshed on .onAppear
    /// and after each block/unblock action.
    @State private var blockedIds: Set<String> = BlockedContactsStore.loadBlockedIds()

    @Environment(\.qaudionSnackbar) private var snackbar

    enum Tab: Hashable, CaseIterable {
        case all, discover, blocked

        var title: String {
            switch self {
            case .all:      return "TUTTI"
            case .discover: return "SCOPRI"
            case .blocked:  return "BLOCCATI"
            }
        }
    }

    /// W58: opzioni di ordinamento della lista TUTTI. Etichette e icone
    /// sono pensate per l'overflow menu nel topBar.
    enum SortMode: String, CaseIterable, Identifiable {
        case nameAsc      // alphabetical A→Z (default)
        case onlineFirst  // online prima, poi alphabetical
        case verifiedFirst // verificati prima, poi alphabetical

        var id: String { rawValue }

        var label: String {
            switch self {
            case .nameAsc:        return "Nome (A→Z)"
            case .onlineFirst:    return "Online prima"
            case .verifiedFirst:  return "Verificati prima"
            }
        }

        var systemImage: String {
            switch self {
            case .nameAsc:        return "textformat.abc"
            case .onlineFirst:    return "circle.fill"
            case .verifiedFirst:  return "checkmark.seal.fill"
            }
        }

        private static let defaultsKey = "com.qaudion.contacts.sortMode"

        static func loadFromDefaults() -> SortMode {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let m = SortMode(rawValue: raw) { return m }
            return .nameAsc
        }

        func saveToDefaults() {
            UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        }
    }

    init() {
        _container = StateObject(wrappedValue: ContactsListContainer())
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            scheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                searchField.padding(.horizontal, 16).padding(.bottom, 12)
                tabRow.padding(.horizontal, 16).padding(.bottom, 8)

                Group {
                    switch selectedTab {
                    case .all:      allList
                    case .discover: discoverPlaceholder
                    case .blocked:  blockedTab
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        // W460: same fix as SettingsScreen — replace deprecated API.
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            container.attach(appState)
            blockedIds = BlockedContactsStore.loadBlockedIds()
        }
        .onChange(of: searchText) { newValue in
            container.setSearchQuery(newValue)
        }
        .sheet(isPresented: $showingNewContact) {
            // W23.E: full ContactEditor in Add mode.
            // 2026-08-06 fix: this used to only print(draft) + show a
            // "salvato in rubrica" snackbar unconditionally — nothing was
            // ever written to ContactsStore, so the contact never actually
            // appeared anywhere. The old comment said this was waiting on
            // the engine to surface a resolve-by-extension API; that API
            // (BCryptoSystemClient/AccountApi.lookupByExtension, already
            // used for dial-by-extension in AppState.dialAndCall) has
            // existed the whole time — this call site was just never
            // updated to use it. Now genuinely resolves the extension to a
            // real userId and persists via ContactsStore.upsert, with an
            // honest error snackbar (not a fake success) if either step
            // fails.
            NavigationStack {
                ContactEditorScreen(
                    mode: .add,
                    onSave: { draft in
                        saveNewContact(draft)
                    }
                )
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    private func saveNewContact(_ draft: ContactEditorScreen.Draft) {
        guard let ext = Int64(draft.extensionText) else {
            snackbar?.show(.init(text: "Interno non valido.", severity: .error))
            return
        }
        guard let provider = appState.liveProvider else {
            snackbar?.show(.init(text: "Non connesso al server — riprova.", severity: .error))
            return
        }
        Task {
            do {
                guard let profile = try await provider.accountApi.lookupByExtension(ext) else {
                    await MainActor.run {
                        snackbar?.show(.init(
                            text: "Interno \(ext) non assegnato — verifica il numero.",
                            severity: .error
                        ))
                    }
                    return
                }
                let contact = ContactsStore.StoredContact(
                    userId: profile.userId,
                    displayName: draft.displayName,
                    phoneHash: "",
                    avatarUrl: nil,
                    lastSeen: nil,
                    isVerified: false,
                    extension: draft.extensionText
                )
                ContactsStore().upsert(contact)
                await MainActor.run {
                    snackbar?.show(.init(
                        text: "Contatto \(draft.displayName) salvato in rubrica.",
                        severity: .info
                    ))
                }
            } catch {
                await MainActor.run {
                    snackbar?.show(.init(
                        text: "Salvataggio fallito: \(error.localizedDescription)",
                        severity: .error
                    ))
                }
            }
        }
    }

    // MARK: - Top bar

    /// Action strip, not a header: the screen deliberately states no title.
    /// It used to print "Contatti" directly above a tab bar whose label is
    /// the same word, in every locale — the shell already owns that word, so
    /// the only thing the duplicate bought was vertical space. The search
    /// field is now the first labelled thing under the shell chrome.
    private var topBar: some View {
        HStack {
            Spacer()
            // W58: sort menu — Nome / Online / Verificati. La scelta
            // viene persistita in UserDefaults così sopravvive a riavvi.
            // Visibile solo sulla tab TUTTI (irrilevante su SCOPRI /
            // BLOCCATI che non hanno una lista ordinabile reale).
            if selectedTab == .all {
                Menu {
                    Picker("Ordina per", selection: $sortMode) {
                        ForEach(SortMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(scheme.onSurface)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Ordina contatti")
                .onChange(of: sortMode) { newValue in
                    newValue.saveToDefaults()
                }
            }
            Button(action: { showingNewContact = true }) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Aggiungi contatto")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(scheme.onSurfaceVariant)
            TextField("", text: $searchText,
                      prompt: Text("Cerca contatti o scopri tramite hash…")
                          .foregroundColor(scheme.onSurfaceVariant))
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
                .tint(scheme.primary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(scheme.surfaceVariant.opacity(0.45))
        )
    }

    // MARK: - Tab row

    private var tabRow: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.5)
                        .foregroundStyle(selectedTab == tab ? scheme.primary
                                                            : scheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedTab == tab
                                      ? scheme.primary.opacity(0.18)
                                      : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedTab == tab
                                        ? scheme.primary
                                        : scheme.outline.opacity(0.6),
                                        lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Lists

    private var allList: some View {
        // W-ORPHANPEER — drop peers whose account no longer exists on the
        // server. Filtered HERE, at read time, and not inside the container:
        // `ContactsListContainer` builds its view model once and does not
        // observe `.contactsDidChange`, so a filter baked in there would keep
        // a contact visible after the 404 lands. Reading `appState.orphanPeerIds`
        // (@Published) also makes this re-render on its own as lookups resolve.
        let unsorted = container.viewModel.filteredItems
            .filter { !shouldHideContact(appState.orphanPeerIds.contains($0.userId)) }
        // W58: applica il sort prescelto. Locale-aware comparison sul
        // displayName — `localizedCaseInsensitiveCompare` rispetta
        // l'ordinamento italiano (es. é < f, à < b).
        let items: [ContactsListViewModel.Item] = {
            switch sortMode {
            case .nameAsc:
                return unsorted.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            case .onlineFirst:
                // I2: `item.isOnline` is a static snapshot value hardcoded
                // to `false` at construction time (ContactsListContainer) —
                // reading it here always produced a no-op sort. Read the
                // live PresenceService state instead, same source the row
                // dot below already uses.
                return unsorted.sorted { a, b in
                    let aOnline = appState.presenceService.isOnline(a.userId)
                    let bOnline = appState.presenceService.isOnline(b.userId)
                    if aOnline != bOnline { return aOnline && !bOnline }
                    return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                }
            case .verifiedFirst:
                return unsorted.sorted { a, b in
                    if a.isVerified != b.isVerified { return a.isVerified && !b.isVerified }
                    return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                }
            }
        }()
        // I2: same fix as the sort above — the header used to read the
        // hardcoded `item.isOnline` and always rendered "ONLINE · 0/N".
        let onlineCount = items.filter { appState.presenceService.isOnline($0.userId) }.count
        let totalCount  = items.count

        return List {
            if !items.isEmpty {
                Section {
                    ForEach(items, id: \.userId) { item in
                        NavigationLink(destination: detailDestination(for: item)) {
                            // W72: live presence dot from the engine
                            // `BCryptoPresenceManager`. Falls back to the
                            // model's `isOnline` heuristic if the
                            // service hasn't received a `presence_update`
                            // for this user yet (status .unknown).
                            ContactRow(item: item,
                                       presence: appState.presenceService.isOnline(item.userId) ? .online :
                                                 (appState.presenceService.status(for: item.userId) == .offline ? .offline : nil),
                                       onChatTap: { openChat(item) },
                                       onCallTap: { openCall(item) },
                                       onVideoCallTap: { openVideoCall(item) })
                        }
                        .listRowBackground(scheme.background)
                    }
                } header: {
                    Text("ONLINE · \(onlineCount)/\(totalCount)")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.5)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
            } else {
                Section {
                    emptyAll
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(scheme.background)
        .refreshable { container.refresh() }
    }

    // W442 — replaced static placeholder with real device-contacts import.
    private var discoverPlaceholder: some View {
        PhoneContactImportView(
            searchText: searchText,
            onImported: { _ in container.refresh() }
        )
    }

    private var blockedTab: some View {
        let allItems = container.viewModel.items
        let blocked = allItems.filter { blockedIds.contains($0.userId) }
        return Group {
            if blocked.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "circle.slash")
                        .font(.system(size: 56))
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Text("Nessun contatto bloccato")
                        .qaudionStyle(type.titleMedium)
                        .foregroundStyle(scheme.onSurface)
                    Text("I contatti che blocchi appariranno qui. Puoi sbloccarli in qualsiasi momento dal loro dettaglio.")
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
                .padding(.top, 48)
            } else {
                List(blocked, id: \.userId) { item in
                    HStack(spacing: 12) {
                        QAudionAvatar(displayName: item.displayName,
                                      imageURL: item.avatarUrl,
                                      size: 40,
                                      presenceDot: nil)
                        Text(item.displayName)
                            .qaudionStyle(type.bodyMedium)
                            .foregroundStyle(scheme.onSurface)
                        Spacer()
                        Button("Sblocca") { unblockContact(item) }
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.primary)
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(scheme.background)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(scheme.background)
            }
        }
    }

    private func unblockContact(_ item: ContactsListViewModel.Item) {
        BlockedContactsStore.remove(item.userId)
        blockedIds = BlockedContactsStore.loadBlockedIds()
        let uid: String = item.userId
        let name: String = item.displayName
        if let provider = appState.liveProvider {
            Task { try? await provider.contactsApi.unblockContact(userId: uid) }
        }
        snackbar?.show(.init(text: name + " sbloccato.", severity: .info))
    }

    private var emptyAll: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2")
                .font(.system(size: 56))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Nessun contatto")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Text("Aggiungi il primo contatto per iniziare a chattare e chiamare in modo sicuro.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // W61: CTA primario nello stato vuoto. Stesso flow del
            // bottone "+" del topBar — qui rende esplicito il next
            // step per first-launch users.
            Button {
                showingNewContact = true
            } label: {
                Label("Aggiungi contatto", systemImage: "person.badge.plus")
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onPrimary)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(
                        Capsule().fill(scheme.primary)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    // MARK: - Routing

    @ViewBuilder
    private func detailDestination(for item: ContactsListViewModel.Item) -> some View {
        ContactDetailScreen(item: item)
    }

    /// Find existing or create new conversation for this peer, then publish
    /// the deep-link so HomeView switches to the Chats tab and
    /// ChatListScreen pushes ChatDetailScreen. Mirrors
    /// `ContactsListView.openOrCreateChat` / `CallHistoryView.openOrCreateChat`
    /// — same find-or-create + deep-link pattern, applied to the Contacts tab.
    private func openChat(_ item: ContactsListViewModel.Item) {
        let store = ConversationStore()
        let convId: UUID
        if let existing = store.loadConversations().first(where: { $0.peerUserId == item.userId }) {
            convId = existing.id
        } else {
            let newConv = Conversation(
                id: UUID(),
                peerUserId: item.userId,
                peerDisplayName: item.displayName,
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

    private func openCall(_ item: ContactsListViewModel.Item) {
        Task { await appState.startCall(contactId: item.userId, video: false) }
    }

    private func openVideoCall(_ item: ContactsListViewModel.Item) {
        Task { await appState.startCall(contactId: item.userId, video: true) }
    }
}

// MARK: - New contact placeholder

private struct NewContactPlaceholder: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(scheme.primary)
            Text("Nuovo contatto")
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
            Text("Apri il QR scanner per aggiungere un contatto in modo verificato, o passa per NFC pairing.")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme.background)
        .navigationTitle("Aggiungi")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ContactsScreen()
    }
    .environmentObject(AppState())
    .qAudionTheme(dark: true)
}
