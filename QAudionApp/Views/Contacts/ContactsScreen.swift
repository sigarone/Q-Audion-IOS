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
                    case .blocked:  blockedPlaceholder
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .navigationBarHidden(true)
        .onAppear { container.attach(appState: appState) }
        .onChange(of: searchText) { newValue in
            container.setSearchQuery(newValue)
        }
        .sheet(isPresented: $showingNewContact) {
            // W23.E: full ContactEditor in Add mode. Pure local form for
            // now (the persist hook prints + dismisses); will be wired
            // to ContactsStore + bcrypto directory when the engine
            // surfaces the resolve-by-extension API.
            NavigationStack {
                ContactEditorScreen(
                    mode: .add,
                    onSave: { draft in
                        print("[ContactEditor] new contact draft: \(draft)")
                        // W34: feedback transitorio via snackbar globale.
                        // Il messaggio scompare in 4s di default; il
                        // wiring persistente verso ContactsStore arriva
                        // quando l'engine espone l'API resolve-by-extension
                        // del bcrypto directory.
                        snackbar?.show(.init(
                            text: "Contatto \(draft.displayName) salvato in rubrica.",
                            severity: .info
                        ))
                    }
                )
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Text("Contatti")
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
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
        let unsorted = container.viewModel.filteredItems
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
                return unsorted.sorted { a, b in
                    if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
                    return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                }
            case .verifiedFirst:
                return unsorted.sorted { a, b in
                    if a.isVerified != b.isVerified { return a.isVerified && !b.isVerified }
                    return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                }
            }
        }()
        let onlineCount = items.filter { $0.isOnline }.count
        let totalCount  = items.count

        return List {
            if !items.isEmpty {
                Section {
                    ForEach(items, id: \.userId) { item in
                        NavigationLink(destination: detailDestination(for: item)) {
                            ContactRow(item: item,
                                       onChatTap: { openChat(item) },
                                       onCallTap: { openCall(item) })
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

    private var discoverPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Importa o scopri")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Text("L'import della rubrica peppered hash arriverà in una versione successiva. Per ora puoi aggiungere contatti via QR / NFC.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .padding(.top, 48)
    }

    private var blockedPlaceholder: some View {
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
    }

    private var emptyAll: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2")
                .font(.system(size: 56))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Nessun contatto")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Text("Aggiungi un contatto via QR o NFC dal pulsante in alto a destra.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
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

    private func openChat(_ item: ContactsListViewModel.Item) {
        // Hand off to ChatListScreen / ChatDetailScreen would require
        // navigating across tabs; for now we just leave the row's
        // primary tap open the detail screen and the chat icon is a
        // stub. A future wave can switch tabs + push the chat detail.
    }

    private func openCall(_ item: ContactsListViewModel.Item) {
        Task { await appState.startCall(contactId: item.userId, video: false) }
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
