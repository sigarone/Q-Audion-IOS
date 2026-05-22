import SwiftUI
import QAudionEngine

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    /// W55: switch tra `TabView` (compact, iPhone) e `NavigationSplitView`
    /// (regular, iPad / iPhone Plus landscape) via size class. Apple
    /// flagga full-screen-only apps in App Review come "non multitasking
    /// ready"; questo soddisfa il requisito senza duplicare logica.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: Tab = .chats
    @State private var presentingInCall: Bool = false
    /// W55: visibility del sidebar su iPad. Default `.all` mantiene la
    /// sidebar aperta di default su iPad — lo spazio disponibile la rende
    /// utile per accedere rapidamente a chat, chiamate e impostazioni.
    /// L'utente può chiuderla con il bottone toolbar se vuole più spazio.
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

    enum Tab: Hashable, CaseIterable, Identifiable {
        case chats
        case contacts
        case calls
        case settings

        var id: Self { self }

        var label: String {
            switch self {
            case .chats:    return "Chat"
            case .contacts: return "Contatti"
            case .calls:    return "Chiamate"
            case .settings: return "Impostazioni"
            }
        }

        var systemImage: String {
            switch self {
            case .chats:    return "bubble.left.and.bubble.right.fill"
            case .contacts: return "person.2.fill"
            case .calls:    return "phone.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                // W55: iPad / regular size class — sidebar + detail.
                splitLayout
            } else {
                // iPhone / compact size class — preservato il TabView
                // pre-W55 per parità completa con la UX iPhone esistente.
                tabLayout
            }
        }
        // W32: tint del tab bar (icona + label selezionati) sul primary
        // del design system Q-Audion. La tab non-selezionata mantiene
        // il default UIKit (grigio iOS) per leggibilità. Si applica
        // anche al sidebar selection highlight su iPad.
        .tint(scheme.primary)
        .overlay(alignment: .top) {
            if appState.isInCall && !presentingInCall {
                inCallBanner
            }
        }
        .fullScreenCover(isPresented: $presentingInCall) {
            inCallCoverView
        }
        .onChange(of: appState.isInCall) { isInCall in
            // Single-param form for iOS 16 compat. Auto-dismiss the cover
            // when the call ends.
            if !isInCall {
                presentingInCall = false
            }
        }
    }

    // MARK: - W55 layouts

    private var tabLayout: some View {
        TabView(selection: $selectedTab) {
            chatsTab
                .tabItem { Label(Tab.chats.label, systemImage: Tab.chats.systemImage) }
                .tag(Tab.chats)

            contactsTab
                .tabItem { Label(Tab.contacts.label, systemImage: Tab.contacts.systemImage) }
                .tag(Tab.contacts)

            callsTab
                .tabItem { Label(Tab.calls.label, systemImage: Tab.calls.systemImage) }
                .tag(Tab.calls)

            settingsTab
                .tabItem { Label(Tab.settings.label, systemImage: Tab.settings.systemImage) }
                .tag(Tab.settings)
        }
    }

    /// iPad / regular layout — sidebar list con la stessa enum `Tab` del
    /// TabView, detail panel che renderizza la stessa sub-view. Usa
    /// `NavigationSplitView` (iOS 16+, già nel deployment target).
    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            List {
                // Profile anchor in cima alla sidebar
                iPadSidebarHeader

                Divider()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)

                ForEach(Tab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: tab.systemImage)
                                .frame(width: 24)
                                .foregroundStyle(selectedTab == tab
                                                 ? scheme.primary
                                                 : scheme.onSurfaceVariant)
                            Text(tab.label)
                                .font(.system(size: 15, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundStyle(selectedTab == tab
                                                 ? scheme.primary
                                                 : scheme.onSurface)
                            Spacer(minLength: 0)
                            // Unread badge solo sulla tab Chat
                            if tab == .chats, totalUnreadCount > 0 {
                                Text(totalUnreadCount > 99 ? "99+" : "\(totalUnreadCount)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(scheme.primary))
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedTab == tab
                            ? scheme.primary.opacity(0.12)
                            : Color.clear
                    )
                }
            }
            .navigationTitle("Q-Audion")
            .navigationBarTitleDisplayMode(.inline)
        } detail: {
            switch selectedTab {
            case .chats:    chatsTab
            case .contacts: contactsTab
            case .calls:    callsTab
            case .settings: settingsTab
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Totale messaggi non letti da mostrare nel badge sidebar Chat.
    private var totalUnreadCount: Int {
        appState.conversations.reduce(0) { $0 + $1.unreadCount }
    }

    /// Header compatto con avatar + numero corto in cima alla sidebar iPad.
    @ViewBuilder
    private var iPadSidebarHeader: some View {
        // W466 — show the SHORT account label ("Interno 234") instead of
        // the raw 36-char UUID. The user reported the long UID as
        // unreadable in the main-screen top-left.
        let displayName = appState.displayAccountLabel
        HStack(spacing: 10) {
            QAudionAvatar(
                displayName: displayName,
                imageURL: nil,
                size: 36,
                presenceDot: .online,
                shortNumber: appState.currentUserDialExtension
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                Text("Q-Audion")
                    .font(.system(size: 11))
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }

    // MARK: - Tabs

    private var chatsTab: some View {
        // W19.G: replaced the bare `ConversationListView()` with the
        // sectioned `ChatListScreen` — admin banner / Gruppi / Fissate /
        // Conversazioni + 2 FABs, 1:1 visual port of Android
        // `qaudion-android-new/feature/feature-chat/.../ChatListScreen.kt`.
        // Data layer (`ConversationListContainer`) is unchanged: only the
        // presentation layer flipped, so the existing chat / search /
        // pin / delete / new-conversation flows keep working.
        NavigationStack {
            ChatListScreen()
        }
    }

    private var contactsTab: some View {
        // W23: Tab Contatti ora usa il nuovo `ContactsScreen` (1:1 visual
        // port di Android `feature-contacts/.../ContactsScreen.kt`) con
        // tab TUTTI / SCOPRI / BLOCCATI, ricerca capsule, FAB
        // person.badge.plus, ContactDetailScreen con TrustVerificationCard
        // / MetadataCard / SecurityLog. Il legacy `ContactsListView`
        // resta ancora montato per i flow di scan/import (sheets) finché
        // non li portiamo alla nuova UI.
        NavigationStack {
            ContactsScreen()
        }
    }

    /// W39: Calls tab ora usa il nuovo `CallHistoryView` (1:1 visual port
    /// di Android `feature-call/.../CallHistoryScreen.kt`) con call-history
    /// list (avatar 48 + name + direction icon + timestamp + duration +
    /// audio/video CTAs). Il legacy `CallsTabView` resta come private
    /// struct nel file ma non è più routed.
    private var callsTab: some View {
        NavigationStack {
            CallHistoryView()
        }
    }

    /// W24: Settings tab usa il nuovo `SettingsScreen` (1:1 visual port di
    /// Android `feature-settings/.../SettingsScreen.kt`) con
    /// ProfileHeroCard + SecurityChipsRow + sezioni ACCOUNT / SICUREZZA /
    /// PRIVACY / DATI / INFO / SVILUPPATORE. Le 11 sub-screen esistenti
    /// (AccountSettings / Privacy / Calls / Chat / Notifications / Backup
    /// / KeyManagement / Transport / About / Security / DeviceManagement)
    /// restano invariate — sono raggiunte via NavigationLink dal nuovo
    /// root. Toggle interni (DeepfakeGuard, ReadReceipts, etc.) restano
    /// nelle rispettive sub-screen finché l'engine non espone una
    /// SettingsUiState unificata.
    ///
    /// W439: NavigationStack lifted OUT of SettingsScreen and placed here.
    /// SettingsScreen used to embed its own NavigationStack, which worked
    /// on iPhone (TabView adds no implicit navigation) but crashed on iPad:
    /// NavigationSplitView's detail pane provides a navigation environment,
    /// and having a second NavigationStack inside it triggers an internal
    /// UINavigationController inconsistency that crashes on iPadOS.
    /// Putting the NavigationStack here means both layouts share the same
    /// pattern: NavigationStack { SettingsScreen() } — the only difference
    /// is the outer container (TabView vs NavigationSplitView.detail).
    private var settingsTab: some View {
        NavigationStack {
            SettingsScreen()
        }
    }

    // MARK: - Active call banner

    private var inCallBanner: some View {
        Button(action: { presentingInCall = true }) {
            HStack {
                Image(systemName: "phone.fill")
                Text(appState.callContactId.map { "Chiamata attiva con \($0)" } ?? "Chiamata attiva")
                Spacer()
                Text("Tocca per rientrare")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Full-screen in-call cover

    @ViewBuilder
    private var inCallCoverView: some View {
        if appState.activeCallKitId != nil {
            // Present the W12.D CallView (which internally creates InCallContainer
            // and delegates to InCallView). Interactive dismiss is disabled so the
            // user cannot accidentally swipe away mid-call; they must use the
            // in-call hang-up button, after which isInCall → false triggers the
            // onChange above and dismisses the cover.
            NavigationStack {
                CallView()
            }
            .environmentObject(appState)
            .interactiveDismissDisabled(true)
        } else {
            // Fallback: activeCallKitId not yet populated (race during call setup).
            // Show a minimal state and let the user dismiss manually.
            VStack(spacing: 24) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Nessuna chiamata attiva")
                    .font(.title2.weight(.semibold))
                Button("Chiudi") { presentingInCall = false }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Calls tab content (preserved from original HomeView)

private struct CallsTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var contactId = ""
    /// 2026-05-08 fix v1.0.417 — cache rubrica → display name so the
    /// recents row renders the contact's friendly name instead of the
    /// raw UUID. Loaded once `onAppear` and refreshed when the recents
    /// list changes (keeps freshly-added contacts visible without a
    /// full screen reload). Same priority as `CallHistoryStore`:
    /// rubrica match → raw userId fallback.
    @State private var contactNameByUserId: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Quick-dial bar
            HStack(spacing: 8) {
                TextField("Inserisci ID contatto", text: $contactId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)

                Button {
                    guard !contactId.isEmpty else { return }
                    Task { await appState.startCall(contactId: contactId, video: false) }
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.body)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(contactId.isEmpty)

                Button {
                    guard !contactId.isEmpty else { return }
                    Task { await appState.startCall(contactId: contactId, video: true) }
                } label: {
                    Image(systemName: "video.fill")
                        .font(.body)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(contactId.isEmpty)
            }
            .padding()

            List {
                Section("Chiamate recenti") {
                    if appState.recentCalls.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "phone.badge.checkmark")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text("Nessuna chiamata recente")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Lo storico apparirà qui dopo la prima chiamata.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 24)
                            Spacer()
                        }
                    } else {
                        ForEach(appState.recentCalls, id: \.self) { call in
                            HStack {
                                Label(displayNameFor(call), systemImage: "phone.fill")
                                Spacer()
                                Button {
                                    Task { await appState.startCall(contactId: call, video: false) }
                                } label: {
                                    Image(systemName: "phone.fill")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    Task { await appState.startCall(contactId: call, video: true) }
                                } label: {
                                    Image(systemName: "video.fill")
                                        .foregroundStyle(.green)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { reloadContactNameCache() }
        // iOS 16 deployment target — must use the single-param onChange
        // form. The two-param `{ _, _ in ... }` overload is iOS 17+ and
        // breaks the Xcode 26 build via silent Swift type-checker
        // timeout (xcbeautify swallows the diagnostic, Build IPA exits
        // 65 with no actionable error — see CLAUDE.md sec 13/14).
        // Existing onChange at line 69 already uses this single-param
        // form for the same reason.
        .onChange(of: appState.recentCalls) { _ in reloadContactNameCache() }
    }

    /// Resolve the rubrica name for a given userId, falling back to the
    /// raw userId when no rubrica match exists. Stays in sync with
    /// `CallHistoryStore.resolvePeerDisplay` — keep them aligned if you
    /// ever change the priority order.
    private func displayNameFor(_ userId: String) -> String {
        if let name = contactNameByUserId[userId], !name.isEmpty {
            return name
        }
        return userId
    }

    /// Pull the latest rubrica snapshot from `ContactsStore` and rebuild
    /// the in-memory dictionary used by `displayNameFor`. Cheap (one
    /// UserDefaults read + one JSON decode) so safe to call on every
    /// recents change; the alternative — looking up per-row inline —
    /// would re-decode for every visible cell on every scroll tick.
    private func reloadContactNameCache() {
        let stored = ContactsStore().load()
        var map: [String: String] = [:]
        for c in stored where !c.displayName.isEmpty {
            map[c.userId] = c.displayName
        }
        contactNameByUserId = map
    }
}

// MARK: - Contacts tab placeholder

private struct ContactsTabPlaceholder: View {
    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label("Contacts", systemImage: "person.2.fill")
            } description: {
                Text("Add a contact via NFC pairing or QR code in Settings → Key Management.")
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Contacts")
                    .font(.title2.weight(.semibold))
                Text("Add a contact via NFC pairing or QR code in Settings → Key Management.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
