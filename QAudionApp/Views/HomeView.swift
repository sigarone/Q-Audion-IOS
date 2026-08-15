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
            // W-1TO1RING (2026-07-27) — the thin incomingCallBanner is retired:
            // ContentView's fullScreenCover now shows the full IncomingCallScreen
            // for 1:1 calls too (same screen already used for group calls),
            // driven by appState.incomingCallRingVisible. Only inCallBanner
            // (post-answer, mid-call) remains here.
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
        // W-CONTACTOPEN (2026-08-06): screens outside the Chats tab
        // (ContactsScreen, CallHistoryView) publish appState.pendingDeepLinkConversationId
        // to open a chat with a peer. ChatListScreen's own onChange (unchanged)
        // does the actual push onto its NavigationStack; this just makes sure
        // the Chats tab is the one visible when that happens, instead of the
        // push silently queuing behind whatever tab the user is currently on.
        .onChange(of: appState.pendingDeepLinkConversationId) { newId in
            if newId != nil {
                selectedTab = .chats
            }
        }
    }

    // MARK: - W55 layouts

    private var tabLayout: some View {
        TabView(selection: $selectedTab) {
            chatsTab
                .tabItem { Label(Tab.chats.label, systemImage: Tab.chats.systemImage) }
                // W146's "Chat (3)" navigation title is gone — that bar now
                // carries the account identity instead of the tab's own
                // word. The count moves to the badge, which is where the
                // iPad sidebar has always shown it and where iOS users
                // expect it. Without this the total would have vanished
                // from the phone entirely.
                .badge(totalUnreadCount)
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
        // W-BRAND (2026-08-15): the wordmark banner does NOT live here.
        // First attempt used `.safeAreaInset(edge: .top)` on this TabView,
        // reasoning that a layout primitive (unlike `.toolbar`) could not be
        // suppressed by a child's `.toolbar(.hidden, for: .navigationBar)`.
        // Reported live the same day, on the Chat tab specifically (the
        // other three rendered fine — never fully root-caused, plausibly a
        // TabView first-visible-tab timing quirk with safeAreaInset):
        // ChatListScreen's `accountTopBar`, which draws the signed-in
        // identity, rendered UNDER the inset instead of below it, an
        // overlap indistinguishable from a hidden banner at a glance.
        // Moved to inline placement on all four screens regardless of
        // which one actually broke — it is the same fix already proven
        // for the VPN chip (see `vpnToolbarItem()`'s kdoc), it does not
        // depend on this fragile shell/inset timing at all, and leaving
        // three screens on the old mechanism while one used the new one
        // would be its own inconsistency. Stop
        // trying to attach shared chrome from the shell and draw it INSIDE
        // each screen's own already-correct top-of-body row instead — see
        // `QAudionBrandBanner` (DesignSystem) and its call site at the top
        // of ChatListScreen/ContactsScreen/CallHistoryView/SettingsScreen.
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
            .toolbar { vpnToolbarItem() }
        } detail: {
            // W-BRAND (2026-08-15): no shared safeAreaInset here either —
            // see the kdoc on `tabLayout`'s TabView for why that composes
            // badly with a detail screen that hides its own nav bar. Each
            // of chatsTab/contactsTab/callsTab/settingsTab draws
            // `QAudionBrandBanner` itself, at the top of its own body, same
            // as the compact layout. The sidebar keeps its own plain-text
            // `.navigationTitle("Q-Audion")` (iPadSidebarHeader's kdoc
            // explains why that stays text) — unaffected either way.
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

    /// Account header at the top of the iPad sidebar.
    ///
    /// It used to state two facts in five renderings. The primary line and
    /// the avatar bubble both showed the extension, because the label the
    /// primary line read resolves to the extension when no name exists; and
    /// the secondary line printed the literal "Q-Audion" under a list whose
    /// `.navigationTitle` is already "Q-Audion". The account's phone number
    /// appeared nowhere.
    ///
    /// Now: name as primary, "#<ext> · <phone>" as secondary, with whatever
    /// was promoted never repeated below — the same two lines the Chats-tab
    /// header and the Settings hero draw, from the same helper, so the three
    /// cannot disagree. The brand stays on the navigation title, which on
    /// iPad is the shell's own chrome and the one legitimate place for it.
    @ViewBuilder
    private var iPadSidebarHeader: some View {
        let labels = AccountIdentityLabels.make(
            dialExtension: appState.currentUserDialExtension,
            avatarName: appState.accountAvatarName
        )
        HStack(spacing: 10) {
            QAudionAvatar(
                // Name alone, never `labels.primary`: the avatar turns what
                // it is handed into initials, and `primary` can be an
                // extension or the complete-your-profile prompt. The digits
                // arrive through `shortNumber`, and stop once there is a
                // real name to draw initials from.
                displayName: labels.nameLabel ?? "Q",
                imageURL: nil,
                size: 36,
                presenceDot: .online,
                shortNumber: labels.nameLabel == nil ? appState.currentUserDialExtension : nil
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(labels.primary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                if !labels.secondary.isEmpty {
                    Text(labels.secondary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }

    // MARK: - VPN chip helper

    /// Trailing toolbar item for the one host that still HAS a navigation
    /// bar: the iPad sidebar.
    ///
    /// It used to be attached to all four tabs, and the comment here used to
    /// claim it "appears in each tab's root navigation bar" — but every tab
    /// screen ends its own body with
    /// `.toolbar(.hidden, for: .navigationBar)` (the W460 iOS 26
    /// crash-on-tap fix), and an item placed in a hidden bar is simply not
    /// drawn. All four screens now render the chip inline in their own
    /// header strip; the four dead attachments are gone.
    ///
    /// The `currentAccessToken ?? ""` fallback means the chip renders but
    /// any tap while unauthenticated will fail fast inside VpnApiService.
    @ToolbarContentBuilder
    private func vpnToolbarItem() -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            VpnToggleChip(
                vpnService: appState.vpnService,
                accessToken: appState.currentAccessToken ?? ""
            )
        }
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
                // Resolve peer display name (extension, contact, truncated UUID)
                // — same priority as incoming call banner — never show raw UUID.
                // W-EXTPREFIX consolidation (2026-07-29): the outgoing branch
                // used to check only `looksLikeUUID` on the rubrica name (a
                // stale "Phone #100" would have shown verbatim); both
                // branches now collapse into one `DisplayName.forUser` call,
                // which already does rubrica-first-then-serverDisplay itself.
                Text({
                    guard let cid = appState.callContactId, !cid.isEmpty else { return "Chiamata attiva" }
                    // AppState.cachedContacts is refreshed on every
                    // ContactsStore write — avoids a UserDefaults decode on
                    // every in-call banner render.
                    let candidate = appState.incomingCallerName.isEmpty ? nil : appState.incomingCallerName
                    let name = DisplayName.forUser(cid, serverDisplay: candidate, contacts: appState.cachedContacts)
                    return "Chiamata attiva con \(name)"
                }())
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
        // W-EXTPREFIX consolidation (2026-07-29): this cache-hit shortcut
        // used to accept ANY non-empty cached name, including a legacy
        // placeholder ("Phone #100"/"New User") — bypassing the canonical
        // check entirely. Now gated the same way `forUser` itself gates
        // its own rubrica step.
        if let name = contactNameByUserId[userId], !DisplayName.isPlaceholderName(name) {
            return name
        }
        // Central rule (DisplayName.swift): never the raw UUID.
        return DisplayName.forUser(userId, contacts: appState.cachedContacts)
    }

    /// Rebuild the in-memory display-name map from AppState.cachedContacts.
    /// The cache is already kept fresh by the .contactsDidChange notification
    /// so this is effectively free (no UserDefaults access, no JSON decode).
    private func reloadContactNameCache() {
        var map: [String: String] = [:]
        // W-UUIDSWEEP: skip UUID-shaped stored names (legacy rows persisted
        // before addScannedContact was fixed) so displayNameFor falls
        // through to DisplayName.forUser's humane fallback. Also skips
        // every OTHER placeholder shape (W-EXTPREFIX, 2026-07-29) — see
        // `displayNameFor`'s own guard for why both places check this.
        for c in appState.cachedContacts
        where !DisplayName.isPlaceholderName(c.displayName) {
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
