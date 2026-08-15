import SwiftUI
import QAudionEngine

/// Sectioned chat list. 1:1 visual + behavioural port of Android
/// `qaudion-android-new/feature/feature-chat/.../ChatListScreen.kt`.
///
/// Sections render in this order (each only appears if it has content):
///   1. `adminBanner`  — pinned banner from the operator. Background
///                        `extras.warning @ 0.18α`, leading shield-icon,
///                        single-line title + multi-line message + optional
///                        "Apri" CTA. Dismissible (chevron `xmark.circle`).
///   2. "Gruppi"       — joined groups from `GroupRegistry`, rendered as
///                        1:1-style rows (avatar + name + last-activity time +
///                        last-message preview / member·epoch subtitle + unread
///                        badge). Preview/unread/time derive from
///                        `GroupMessageStore`; tapping pushes `GroupChatScreen`.
///   3. "Fissate"      — pinned 1-to-1 conversations (`pinned == true`).
///   4. "Conversazioni" — everything else, sorted by lastActivity desc.
///
/// One labelled FAB anchored bottom-trailing: an extended capsule reading
/// "Nuovo gruppo". Starting a 1:1 chat is a labelled icon in the header —
/// it used to be a second bare circle stacked above this one, duplicating
/// the empty-state CTA.
///
/// Above the sections sit the account header (`accountTopBar`) and an
/// in-body search field. Both used to be navigation-bar chrome —
/// `.navigationTitle` and `.searchable` — but that bar printed the tab's
/// own label and is now hidden, so the search field is a plain TextField
/// styled like the one on ContactsScreen. Same shape as Compose's TopBar
/// TextField on Android.
///
/// This screen is back-compatible with the existing `ConversationListContainer`
/// — the data layer is unchanged. Only the presentation layer is new.
struct ChatListScreen: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var container = ConversationListContainer()

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar
    /// Distinguishes the iPhone TabView host from the iPad
    /// NavigationSplitView detail pane, which already has a shell-level VPN
    /// chip in its sidebar.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var searchText: String = ""
    @State private var showingNewConversation = false
    @State private var showingNewGroup = false
    /// 2026-07-29 — "start a chat by typed number/extension" fields, shown
    /// above the contact picker inside the "new conversation" sheet. Ports
    /// `AppState.dialAndCall`'s resolution heuristic (extension / E.164 /
    /// already-a-userId) — previously only the DialPad (calls) had this;
    /// starting a CHAT required an existing contact.
    @State private var dialInput: String = ""
    @State private var isResolvingDial = false
    @State private var dialError: String?
    /// W94: deep-link state. When `appState.pendingDeepLinkConversationId`
    /// is published (notification tap), `deepLinkItem` captures the
    /// matching conversation and `deepLinkActive` flips on, triggering
    /// `navigationDestination(isPresented:)` to push ChatDetailScreen.
    @State private var deepLinkItem: ConversationListViewModel.Item? = nil
    @State private var deepLinkActive: Bool = false
    @State private var adminBannerDismissed = false
    /// Latch: true once the WebSocket has reached a connected state at
    /// least once this session. Gates the transport-down banner so it never
    /// shows before the socket has had a chance to attach — `.disconnected`
    /// is the initial value, not evidence of a fault.
    @State private var wsEverConnected = false
    /// nil = not checked yet. Read exactly once, the first time this
    /// screen's `.onAppear` fires, and never again — this is the SwiftUI
    /// approximation of "checked when the view model is constructed"
    /// (`ConversationListContainer` has no `AppState` reference to do the
    /// check itself). Deliberately NOT re-read on every reappearance:
    /// Android's `ChatListViewModel` (ChatListViewModel.kt:163-178) checks
    /// once at construction too, so re-checking here would make the banner
    /// vanish the instant the user enrols from Settings and taps back —
    /// behaviour shipped Android does not have.
    @State private var recoveryEnrolledAtLoad: Bool?
    @State private var recoveryBannerDismissedLocally = false
    /// Drives the sheet the banner's own "Configura" button opens.
    @State private var showingRecoveryFromBanner = false
    /// W40: gruppo creato (non-nil → presenta GroupChatScreen full-screen).
    @State private var openedGroup: OpenedGroup? = nil
    /// W139: pending conversation export — non-nil triggers the share
    /// sheet. The wrapper holds the on-disk URL of the rendered .txt
    /// transcript, which `UIActivityViewController` ships out via
    /// AirDrop / Files / Mail / Messages.
    @State private var exportTarget: ExportTarget? = nil
    /// Fase 1B — real joined groups for the "Gruppi" section. The chat-list
    /// group rows were previously sourced from `ConversationStore`
    /// (`kind == .group`), which no production path ever writes, so the
    /// section was effectively dead. Source them from the live GroupRegistry
    /// instead and derive preview/unread/time from GroupMessageStore.
    @ObservedObject private var groupRegistry = GroupRegistry.shared
    /// Bumped on any GroupMessageStore change so `groupRows` recomputes its
    /// preview / unread / last-activity (GroupMessageStore posts a
    /// NotificationCenter event rather than an @Published property).
    @State private var groupRefreshToken: Int = 0
    /// W-GRPDEL (2026-08-02) — group row awaiting delete confirmation.
    /// Group rows had NO delete affordance at all: swipe and long-press were
    /// wired for 1:1 conversations only, and the single way out of a group
    /// was "Esci dal gruppo" buried in the info sheet — which did not tell
    /// the server, so the chat came back on the next reconcile. Deleting is
    /// irreversible locally, hence the confirmation.
    @State private var pendingGroupDelete: GroupRowUi? = nil
    @State private var showingGroupDeleteConfirm = false

    /// Sentinel Identifiable per `.fullScreenCover(item:)` con il
    /// groupId + name appena creati.
    private struct OpenedGroup: Identifiable, Equatable {
        let id: UUID
        let name: String
        let memberCount: Int
    }

    /// W139: wrapper for `.sheet(item:)`. Identity is the file URL —
    /// each export produces a fresh tmp file so identity is unique.
    private struct ExportTarget: Identifiable {
        let id: URL
        var url: URL { id }
    }

    // MARK: - Account header

    /// The header of the Chats tab shows the one thing only it can show:
    /// whose account this device is logged into. It used to print "Chat",
    /// character-for-character the tab-bar label drawn directly below it,
    /// while the logged-in identity appeared on no home surface at all on
    /// iPhone.
    ///
    /// Metrics match the strips ContactsScreen and CallHistoryView already
    /// use, so the four tabs line up.
    private var accountTopBar: some View {
        let labels = AccountIdentityLabels.make(
            dialExtension: appState.currentUserDialExtension,
            avatarName: appState.accountAvatarName
        )
        return HStack(spacing: 12) {
            QAudionAvatar(
                // Name only, never `labels.primary`: the avatar turns what
                // it is handed into initials, and `primary` can be an
                // extension or the complete-your-profile prompt. The digits
                // arrive through `shortNumber` instead — and are dropped
                // once there is a real name to draw initials from.
                displayName: labels.nameLabel ?? "Q",
                imageURL: AvatarUploader.resolveSelfAvatarURL(version: appState.selfAvatarVersion),
                size: 36,
                shortNumber: labels.nameLabel == nil ? appState.currentUserDialExtension : nil
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(labels.primary)
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                if !labels.secondary.isEmpty {
                    Text(labels.secondary)
                        .qaudionStyle(type.labelSmall)
                        .monospaced()
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            // One VoiceOver element, not three fragments read in sequence.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            // Replaces the unlabelled `square.and.pencil` circle that used
            // to sit under the group FAB. Same sheet, same state — that
            // sheet is also the app's only mount for the dial-by-number
            // row, the contact picker, QR scan and NFC pairing, which is
            // why the glyph stays a compose pencil rather than a dialpad.
            Button { showingNewConversation = true } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Nuova chat")
            markAllMenu
            // Compact only — on iPad the sidebar draws one chip for the
            // whole shell, same gate the other three tabs use.
            if horizontalSizeClass != .regular {
                VpnToggleChip(vpnService: appState.vpnService,
                              accessToken: appState.currentAccessToken ?? "")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    /// W50: overflow menu — "Segna tutti come letti", gated on the total
    /// unread count. Lived in the navigation bar until that bar was hidden;
    /// it had to move in the same edit or it would have gone with it.
    private var markAllMenu: some View {
        Menu {
            Button {
                let n = container.totalUnread
                container.markAllAsRead()
                // W70: replay server-side bulk read-all (best-effort).
                if let sync = TrackBSyncService.from(serverUrl: appState.serverUrl, token: appState.authService.loadToken()) {
                    Task { await sync.markAllConversationsRead() }
                }
                snackbar?.show(.init(
                    text: n > 0
                        ? "Segnate \(n) conversazioni come lette."
                        : "Nessuna conversazione non letta.",
                    severity: .info))
            } label: {
                Label("Segna tutti come letti",
                      systemImage: "checkmark.circle")
            }
            .disabled(container.totalUnread == 0)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(scheme.onSurface)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("Altro")
    }

    /// In-body replacement for `.searchable`, which lived in the navigation
    /// bar this screen now hides. Same shape as ContactsScreen's field so
    /// the two search surfaces match.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(scheme.onSurfaceVariant)
            TextField("", text: $searchText,
                      prompt: Text("Cerca conversazioni")
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

    /// W57 (Track B engine wire #3): admin banner content. Priorità
    /// (high → low):
    ///
    ///   1. **Recent security alert** — se `ThreatReportLogStore` ha
    ///      una entry con severity ≥ "warning" nelle ultime 24h, mostra
    ///      quella come banner. Equivalente Android di
    ///      `ObserveConversationsUseCase` che aggrega le righe
    ///      `securityEventDao.observeRecentAlerts(sinceTs = now - 24h)`.
    ///   2. **First-launch hint** — fallback friendly se la rubrica è
    ///      vuota e nessun threat report recente.
    ///   3. **nil** — nessun banner.
    ///
    /// Engine wiring per `SecurityEventDao` lato iOS resta deferred —
    /// oggi `ThreatReportLogStore` è populated dai POST `/security/
    /// threat-report` che l'utente fa esplicitamente da
    /// `ThreatReportContainer`. Quando l'engine surface esporrà eventi
    /// passive (peer key changed, new device detected, etc.), aggiungere
    /// quella sorgente con priorità superiore.
    private var adminBanner: AdminBannerData? {
        guard !adminBannerDismissed else { return nil }

        // 1. Recent security alert (≤ 24h, severity warning/alert).
        if let recentAlert = recentSecurityAlertBanner() {
            return recentAlert
        }

        // 2. First-launch hint.
        if container.viewModel.items.isEmpty && container.searchText.isEmpty {
            return AdminBannerData(
                title: "Q-Audion attivo",
                message: "Le tue chiamate e i tuoi messaggi sono protetti con ML-KEM 1024 + Voice-as-Key.",
                ctaLabel: nil
            )
        }

        return nil
    }

    /// W57: surface alert dalle ultime 24h come banner. Threat reports
    /// con severity == "alert" o "warning" hanno precedenza su
    /// "info"/"low". Restituisce nil se nessuna alert recente.
    private func recentSecurityAlertBanner() -> AdminBannerData? {
        let store = ThreatReportLogStore()
        let entries = store.load()
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let recent = entries
            .filter { $0.submittedAt >= cutoff }
            .filter { $0.severity == "alert" || $0.severity == "warning" }
        guard let latest = recent.first else { return nil }

        // Format: "Categoria · X minuti fa". `category` è snake_case
        // raw, prettify per il banner UI.
        let pretty = latest.category
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        let when = formatRelative(latest.submittedAt)
        return AdminBannerData(
            title: "Allerta sicurezza · \(pretty)",
            message: "\(latest.details.prefix(160))\(latest.details.count > 160 ? "…" : "") · segnalata \(when)",
            ctaLabel: "Vedi dettagli"
        )
    }

    /// Whether to show the "configura la frase di recupero" nudge. False
    /// while `recoveryEnrolledAtLoad` is still nil (before the one-time
    /// check has run) so the banner never flashes on the very first frame.
    private var recoveryBannerVisible: Bool {
        guard let enrolled = recoveryEnrolledAtLoad, !enrolled else { return false }
        return !recoveryBannerDismissedLocally
    }

    /// Whether to warn that the socket is down.
    ///
    /// When the transport drops, typed messages queue locally and this list
    /// looks exactly like a healthy one — the user has no way to tell that
    /// nothing is being delivered.
    ///
    /// The `wsEverConnected` latch matters: `wsConnectionState` starts at
    /// `.disconnected`, so without it a cold launch would flash a red strip
    /// before the socket has had any chance to attach, and so would every
    /// return from the background. Once the socket has been up once, any
    /// subsequent drop is real and worth saying.
    private var wsBannerVisible: Bool {
        guard wsEverConnected else { return false }
        switch appState.wsConnectionState {
        case .connected, .authenticated: return false
        case .disconnected, .connecting:  return true
        }
    }

    /// Compact "X min/h fa" formatter — evita di trascinare in
    /// dependency aggiuntive solo per questa label.
    private func formatRelative(_ date: Date) -> String {
        let delta = Int(Date().timeIntervalSince(date))
        if delta < 60 { return "ora" }
        if delta < 3600 { return "\(delta / 60) min fa" }
        if delta < 86400 { return "\(delta / 3600) h fa" }
        return "\(delta / 86400) g fa"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            scheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                QAudionBrandBanner()
                accountTopBar
                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                List {
                    // Reminder of the same fact the Settings banner states
                    // non-dismissably — this one CAN be dismissed, because
                    // Settings remains reachable as the non-dismissable
                    // backstop. Primary-tinted, not the risk-red the
                    // Settings version uses: this is a nudge on the app's
                    // main surface, not a warning about something already
                    // wrong.
                    if recoveryBannerVisible {
                        Section {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "lock.trianglebadge.exclamationmark")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(scheme.primary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Configura la frase di recupero")
                                        .qaudionStyle(type.labelMedium)
                                        .foregroundStyle(scheme.primary)
                                    Text("12 parole · l'unica via per non perdere l'account.")
                                        .qaudionStyle(type.labelSmall)
                                        .foregroundStyle(scheme.onSurfaceVariant)
                                    Button("Configura") {
                                        showingRecoveryFromBanner = true
                                    }
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.primary)
                                    .padding(.top, 2)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    let uid = appState.currentUserId ?? ""
                                    RecoveryEnrollmentStatus.dismissBanner(userId: uid)
                                    recoveryBannerDismissedLocally = true
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(scheme.onSurfaceVariant)
                                }
                                .accessibilityLabel("Ignora promemoria frase di recupero")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(scheme.primary.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                                      bottom: 8, trailing: 12))
                        }
                    }

                    // Its own Section, above and independent of the admin
                    // banner — the two can legitimately be on screen at once
                    // and say different things.
                    if wsBannerVisible {
                        Section {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(extras.riskHigh)
                                    // The text says it; the glyph would only
                                    // make VoiceOver say it twice.
                                    .accessibilityHidden(true)
                                Text("Connessione persa · riconnessione in corso. I messaggi verranno inviati automaticamente.")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(extras.riskHigh)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(extras.riskHigh.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityElement(children: .combine)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                                      bottom: 8, trailing: 12))
                        }
                    }

                    if let banner = adminBanner {
                        Section {
                            adminBannerView(banner)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                                          bottom: 8, trailing: 12))
                        }
                    }

                    if !groupRows.isEmpty {
                        Section {
                            ForEach(groupRows) { row in
                                groupRow(row)
                            }
                        } header: {
                            sectionHeader("Gruppi")
                        }
                    }

                    if !pinned.isEmpty {
                        Section {
                            ForEach(pinned, id: \.conversationId) { item in
                                conversationRow(item)
                            }
                        } header: {
                            sectionHeader("Fissate")
                        }
                    }

                    if !regular.isEmpty {
                        Section {
                            ForEach(regular, id: \.conversationId) { item in
                                conversationRow(item)
                            }
                        } header: {
                            sectionHeader("Conversazioni")
                        }
                    }

                    if container.viewModel.items.isEmpty && container.searchText.isEmpty {
                        Section {
                            emptyState
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(scheme.background)
                // Clearance for the floating capsule, which is wider and
                // taller than the circle it replaced. safeAreaInset rather
                // than bottom padding: padding would clip the scroll region
                // instead of extending it, and .contentMargins is iOS 17+
                // while this target is 16.
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 88) }
            }

            fabStack
                .padding(.trailing, 16)
                .padding(.bottom, 16)
        }
        // The navigation bar printed the word "Chat" directly above a tab
        // item labelled "Chat", and identified the account nowhere. It is
        // hidden now and `accountTopBar` takes its place; the two controls
        // that lived in it (the overflow menu and the search field) moved
        // into the body in the same edit so nothing was lost with the bar.
        // W146's unread total moved to the tab-bar badge in HomeView.
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: searchText) { newValue in
            // iOS 16 single-param form (the iOS 17 onChange takes
            // (oldValue, newValue) — Codemagic's xcode 26 still has to
            // back-deploy to iOS 16 since CLAUDE.md pins target = 16.0).
            container.setSearchQuery(newValue)
        }
        // Latches once the socket has genuinely been up, which is what
        // stops the cold-launch and background-return flash. Same iOS 16
        // single-parameter form as above.
        .onChange(of: appState.wsConnectionState) { state in
            if state == .connected || state == .authenticated {
                wsEverConnected = true
            }
        }
        .refreshable { container.loadFromStore() }
        // Recovery-nudge check — see the property doc on
        // `recoveryEnrolledAtLoad` for why this is guarded to run only
        // once per screen lifetime rather than every reappearance.
        .onAppear {
            if recoveryEnrolledAtLoad == nil {
                let uid = appState.currentUserId ?? ""
                recoveryEnrolledAtLoad = RecoveryEnrollmentStatus.isEnrolled(userId: uid)
                recoveryBannerDismissedLocally = RecoveryEnrollmentStatus.isBannerDismissed(userId: uid)
            }
        }
        // GAP FIX — app-launch group reconciliation. The chat list is the
        // first screen shown after login/launch; on each appear, best-effort
        // GET /api/v1/groups (every group the server says this account
        // belongs to) and apply it: a brand-new group whose
        // `group_membership_changed` add-event this device missed while
        // offline now gets bootstrapped here instead of never appearing
        // (2026-07-17 bug), and an already-known group's roster/metadata
        // refreshes the same way the old per-entry loop did (one bulk call
        // instead of N per-group GETs — see `reconcileAllGroupsFromServer`).
        .task {
            await appState.reconcileAllGroupsFromServer()
        }
        // Fase 1B — recompute the group rows' preview / unread / time when a
        // group message lands or is marked read (GroupMessageStore signals
        // via NotificationCenter, not an @Published property).
        .onReceive(NotificationCenter.default.publisher(
            for: GroupMessageStore.didChangeNotification)) { _ in
            groupRefreshToken &+= 1
        }
        // Bug fix (2026-08-05): a fresh avatar_announce lands via
        // AvatarAnnounceCoordinator -> ContactsStore.setAvatarLocalPath,
        // which posts .contactsDidChange — the rubrica (ContactsListView)
        // already observes it, but this screen didn't, so a 1:1 row kept
        // showing the OLD avatar (or the initials placeholder) until the
        // user left and re-entered the tab. Reload so `conversationRow`
        // re-reads `appState.cachedContacts` with the new avatarUrl.
        .onReceive(NotificationCenter.default.publisher(for: .contactsDidChange)) { _ in
            container.loadFromStore()
        }
        // W94: navigationDestination triggered by the deep-link state.
        // When a notification tap publishes appState.pendingDeepLinkConversationId,
        // the onChange below captures the matching item and flips the
        // boolean, which iOS pushes onto the nav stack automatically.
        .navigationDestination(isPresented: $deepLinkActive) {
            if let item = deepLinkItem {
                chatDestination(for: item)
            } else {
                EmptyView()
            }
        }
        .onChange(of: appState.pendingDeepLinkConversationId) { newId in
            guard let id = newId else { return }
            // Reload before lookup so a freshly-created conversation
            // (from a contact you've never messaged) is in the list.
            container.loadFromStore()
            if let item = container.viewModel.items.first(where: { $0.conversationId == id }) {
                deepLinkItem = item
                deepLinkActive = true
            }
            // Consume the deep link so a stale value doesn't re-fire
            // on the next view re-render.
            appState.pendingDeepLinkConversationId = nil
        }
        .sheet(isPresented: $showingRecoveryFromBanner) {
            NavigationStack {
                RecoverySeedContainerView(
                    container: RecoverySeedContainer(
                        mode: .setup,
                        appState: appState,
                        onDismiss: {
                            showingRecoveryFromBanner = false
                            recoveryEnrolledAtLoad = RecoveryEnrollmentStatus.isEnrolled(
                                userId: appState.currentUserId ?? "")
                        }
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla") { showingRecoveryFromBanner = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewConversation) {
            NavigationStack {
                VStack(spacing: 0) {
                    dialByNumberRow
                    Divider()
                    // W-DIALCHAT: explicit maxHeight so the List inside
                    // ContactsListView actually expands to fill the sheet
                    // instead of sizing to its intrinsic content — same
                    // fix ContactsScreen.body already applies to its own
                    // List-containing Group for the identical reason.
                    ContactsListView()
                        .frame(maxHeight: .infinity)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla") { showingNewConversation = false }
                    }
                }
            }
        }
        // W139: present the export share sheet when a transcript file
        // has been written. Single activityItem = the on-disk URL so
        // receivers see a real .txt with proper UTI.
        .sheet(item: $exportTarget) { target in
            ActivityShareSheet(activityItems: [target.url])
        }
        .sheet(isPresented: $showingNewGroup) {
            // W40.A: full group-creation flow. ContactPicker +
            // name field + Crea(N) button → callback `onGroupCreated`.
            // Engine wiring pending (real GroupChatRepository), per ora
            // stub UUID + snackbar feedback.
            NavigationStack {
                CreateGroupScreen { newGroupId in
                    // W40.C: dopo create, presentiamo full-screen il
                    // GroupChatScreen del nuovo gruppo. CreateGroupScreen's
                    // handleCreate() already persists name+members into
                    // GroupRegistry via appState.createGroup() BEFORE this
                    // callback fires -- read them back instead of the old
                    // "Nuovo gruppo"/1-membro placeholder, which otherwise
                    // stuck around until the user backed out and re-entered
                    // the chat (GroupChatScreen never refreshes state.name/
                    // memberCount from the registry after initial load).
                    showingNewGroup = false
                    let hex = newGroupId.uuidString
                        .replacingOccurrences(of: "-", with: "").lowercased()
                    let registryEntry = GroupRegistry.shared.entry(for: hex)
                    openedGroup = OpenedGroup(
                        id: newGroupId,
                        name: registryEntry?.name ?? "Nuovo gruppo",
                        memberCount: registryEntry?.members.count ?? 1
                    )
                }
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .fullScreenCover(item: $openedGroup) { group in
            NavigationStack {
                GroupChatScreen(
                    groupId: group.id,
                    initial: GroupChatUiState(
                        name: group.name,
                        memberCount: group.memberCount,
                        messages: []
                    )
                )
            }
        }
        // W-GRPDEL — irreversible locally, so it is confirmed. The copy says
        // plainly that this also leaves the group, because "delete for me"
        // and "leave" are the same act here: there is no screen that can
        // reach a group's history once its row is gone.
        .alert("Eliminare questa chat di gruppo?",
               isPresented: $showingGroupDeleteConfirm,
               presenting: pendingGroupDelete) { row in
            Button("Annulla", role: .cancel) { pendingGroupDelete = nil }
            Button("Elimina", role: .destructive) { confirmGroupDelete(row) }
        } message: { row in
            Text(Self.groupDeleteWarning(for: row.name))
        }
    }

    // MARK: - Group delete (W-GRPDEL)

    /// Message body for the delete confirmation. Built here rather than
    /// inline in the `@ViewBuilder` closure — SWIFT6_PATTERNS rule 1.
    private static func groupDeleteWarning(for name: String) -> String {
        return "\"" + name + "\" verrà rimossa da questo dispositivo insieme a tutti i suoi messaggi, e uscirai dal gruppo. L'operazione non può essere annullata."
    }

    /// Run the delete. Any member may do this — it is deliberately not
    /// gated on being creator or admin.
    ///
    /// `AppState.deleteGroupChatAndWait` is fail-open: it purges locally and
    /// writes the tombstone whatever the server leave does, so the row
    /// disappears even offline. The first snackbar therefore states the local
    /// outcome, which is the one that is always true.
    ///
    /// W-GRPDEL — when the server leave did NOT land, say so instead of
    /// letting the confirmation's "uscirai dal gruppo" stand as if it had.
    /// The other members still see this user in the group until the leave
    /// actually reaches the server. The notice may promise a retry only
    /// because there now IS one: `reconcileAllGroupsFromServer` re-issues the
    /// leave on the next sweep for exactly this case (a tombstone whose
    /// `serverLeaveOk` is false while the server still lists us). Do not
    /// reword this into a promise the code stops keeping.
    private func confirmGroupDelete(_ row: GroupRowUi) {
        pendingGroupDelete = nil
        let groupHex = row.hex
        snackbar?.show(.init(text: "Chat di gruppo eliminata.", severity: .info))
        Task { @MainActor in
            let outcome = await appState.deleteGroupChatAndWait(groupId: groupHex)
            groupRefreshToken &+= 1
            guard !serverLeaveConfirmed(outcome) else { return }
            snackbar?.show(.init(text: Self.groupLeavePendingNotice, severity: .warning))
        }
    }

    /// Copy for the "deleted here, but the server does not know yet" case.
    /// Bound as a static rather than inline — SWIFT6_PATTERNS rule 1.
    private static let groupLeavePendingNotice =
        "Chat eliminata da questo dispositivo. Non è stato possibile completare l'uscita dal gruppo: l'app riproverà automaticamente."

    private func requestGroupDelete(_ row: GroupRowUi) {
        pendingGroupDelete = row
        showingGroupDeleteConfirm = true
    }

    // MARK: - Section partitioning

    /// Fase 1B — chat-list model for a group row. Derived from the joined
    /// GroupRegistry entry + its GroupMessageStore history.
    private struct GroupRowUi: Identifiable {
        let id: UUID          // dashed-UUID form == GroupChatScreen `groupId`
        let hex: String       // dash-stripped == GroupMessageStore / registry key
        let name: String
        let memberCount: Int
        let epoch: Int
        let preview: String?  // last message text (nil ⇒ show member/epoch subtitle)
        let lastActivity: Date
        let unread: Int
        // GAP FIX — the group avatar, derived from `avatarRef` the SAME
        // "serverUrl + /api/v1/files/{fileId}" convention GroupInfoScreen's
        // hero uses (GroupChatScreen.makeInfoState). nil ⇒ no avatar set,
        // QAudionAvatar falls back to the generic group placeholder.
        let avatarUrl: URL?
    }

    /// Fase 1B — build the group rows from the live registry, sorted by
    /// last activity (newest first) to match the 1:1 ordering. Filtered by
    /// the same search field (name match). `groupRefreshToken` is read so
    /// the rows recompute when GroupMessageStore posts a change.
    private var groupRows: [GroupRowUi] {
        _ = groupRefreshToken   // dependency: recompute on message change
        let q = searchText.lowercased()
        return groupRegistry.entries.compactMap { e -> GroupRowUi? in
            guard let uuid = Self.hexToUUID(e.id) else { return nil }
            if !q.isEmpty && !e.name.lowercased().contains(q) { return nil }
            let last = GroupMessageStore.shared.lastMessage(forGroupHex: e.id)
            return GroupRowUi(
                id: uuid,
                hex: e.id,
                // Central rule (DisplayName.swift): a group whose registry
                // name is empty/UUID-shaped renders "Gruppo a1b2c3d4…",
                // never the raw id.
                name: DisplayName.forGroup(id: e.id, name: e.name),
                memberCount: e.members.count,
                epoch: Int(e.epoch),
                preview: Self.groupPreviewText(for: last),
                lastActivity: last?.ts ?? e.joinedAt,
                unread: GroupMessageStore.shared.unreadCount(forGroupHex: e.id),
                avatarUrl: e.avatarRef.flatMap {
                    URL(string: "\(appState.serverUrl)/api/v1/files/\($0)")
                })
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Fase 1B — chat-list row preview text for a group's newest message.
    /// A caption (or plain-text body) wins; an un-captioned attachment row
    /// (whose `text` is empty) falls back to a localized "[Foto]" / "[File]"
    /// placeholder so a media message never renders as a blank preview —
    /// mirroring the 1:1 list, which shows "📷 Foto" / "📎 Allegato" for the
    /// same case. Returns nil only for a group with no messages, so the row
    /// shows its member-count/epoch subtitle instead.
    private static func groupPreviewText(for last: GroupMessageStore.Stored?) -> String? {
        guard let last = last else { return nil }
        if !last.text.isEmpty { return last.text }
        if let kind = last.attachmentKind {
            return kind == GroupAttachmentEnvelope.kindImage ? "[Foto]" : "[File]"
        }
        return nil
    }

    /// Reconstruct a dashed UUID from the 32-char dash-stripped hex the
    /// GroupRegistry keys on (same logic as AppState.hexToDashedUUID, which
    /// is fileprivate to that file). Returns nil for a malformed id.
    private static func hexToUUID(_ hex: String) -> UUID? {
        let clean = hex.lowercased()
        guard clean.count == 32, clean.allSatisfy({ $0.isHexDigit }) else { return nil }
        let c = Array(clean)
        let dashed = "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
        return UUID(uuidString: dashed)
    }

    private var pinned: [ConversationListViewModel.Item] {
        container.viewModel.filteredItems.filter { $0.kind != .group && $0.pinned }
    }

    private var regular: [ConversationListViewModel.Item] {
        container.viewModel.filteredItems.filter { $0.kind != .group && !$0.pinned }
    }

    // MARK: - Section header

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .qaudionStyle(type.labelSmall)
            .tracking(1.5)
            .foregroundStyle(scheme.onSurfaceVariant)
            .padding(.top, 8)
    }

    // MARK: - Admin banner

    private func adminBannerView(_ data: AdminBannerData) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(extras.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(data.title)
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(scheme.onSurface)
                Text(data.message)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .lineLimit(3)
                if let cta = data.ctaLabel {
                    // W293: wire the CTA button to the optional URL.
                    // Pre-bind the URL into a local outside the Button
                    // closure to keep type-checker scope clean per
                    // CLAUDE.md §13. nil URL → no-op.
                    let url: URL? = data.ctaURL
                    Button(cta) {
                        Self.openAdminCtaURL(url)
                    }
                    .font(type.labelLarge.font)
                    .foregroundStyle(scheme.primary)
                }
            }
            Spacer()
            Button {
                adminBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chiudi avviso")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.warning.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(extras.warning.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Group row (Fase 1B)

    /// Group chat-list row — mirrors the 1:1 `conversationRow`: avatar +
    /// name + last-activity time + preview/subtitle + unread badge. Tapping
    /// pushes GroupChatScreen (the old horizontal card routed to the 1:1
    /// ChatDetailScreen, which was wrong for a group).
    private func groupRow(_ row: GroupRowUi) -> some View {
        NavigationLink {
            GroupChatScreen(
                groupId: row.id,
                initial: GroupChatUiState(
                    name: row.name,
                    memberCount: row.memberCount,
                    messages: []))
        } label: {
            HStack(spacing: 12) {
                QAudionAvatar(displayName: row.name, imageURL: row.avatarUrl,
                              kind: .group, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(row.name)
                            .qaudionStyle(type.titleSmall)
                            .foregroundStyle(scheme.onSurface)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(formatTime(row.lastActivity))
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }
                    HStack {
                        Text(groupPreviewText(row))
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        if row.unread > 0 {
                            // Same badge component + style as the 1:1 row.
                            Text("\(row.unread)")
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.onPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(scheme.primary))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(scheme.background)
        // W-GRPDEL — same trailing-swipe idiom the 1:1 rows have had all
        // along (`conversationRow` below). Group rows had no swipe action at
        // all, which is why deleting one meant hunting through the info
        // sheet for "Esci dal gruppo".
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                requestGroupDelete(row)
            } label: {
                Label("Elimina chat", systemImage: "trash")
            }
        }
        // Long-press mirrors the swipe, for the same reason the 1:1 rows do
        // it (W119): iPad / trackpad users cannot reach swipe actions.
        .contextMenu {
            Button(role: .destructive) {
                requestGroupDelete(row)
            } label: {
                Label("Elimina chat", systemImage: "trash")
            }
        }
    }

    /// Preview line for a group row: the last message (truncated like the
    /// 1:1 preview) when present, else the member-count/epoch subtitle the
    /// group previously showed as its only signal.
    private func groupPreviewText(_ row: GroupRowUi) -> String {
        if let preview = row.preview, !preview.isEmpty {
            return preview.count > 120 ? String(preview.prefix(120)) + "…" : preview
        }
        return "\(row.memberCount) membri · epoch \(row.epoch)"
    }

    // MARK: - Conversation row (1-to-1)

    /// W-UUIDSWEEP-2 (2026-07-20): the conversations table PERSISTS
    /// `peerDisplayName`, so rows created before the write-site fixes carry
    /// the raw 36-char UUID baked in as the title — the contacts-store
    /// migration cannot reach them. Never trust a persisted UUID-shaped
    /// title at render: re-resolve through the central chain (rubrica →
    /// "Utente/Gruppo xxxxxxxx…").
    ///
    /// W-EXTPREFIX consolidation (2026-07-29): the guard used to check only
    /// `looksLikeUUID`/`isEmpty` — a persisted "Phone #100" (written back
    /// when this row was created by, say, the old `resolveDialInput`)
    /// rendered verbatim forever. For the 1:1 case this now always calls
    /// `DisplayName.forUser` with the persisted value threaded through as
    /// `serverDisplay`, so the SAME placeholder check and extension
    /// recovery `forUser` applies everywhere else also applies here — the
    /// live rubrica (via `contacts:`) still wins first if it has a better
    /// name than what's frozen in this row.
    private func resolvedRowTitle(_ item: ConversationListViewModel.Item) -> String {
        if item.kind == .group {
            guard DisplayName.isPlaceholderName(item.peerDisplayName) else {
                return item.peerDisplayName
            }
            return DisplayName.forGroup(id: item.peerUserId, name: nil)
        }
        return DisplayName.forUser(
            item.peerUserId, serverDisplay: item.peerDisplayName,
            contacts: appState.cachedContacts)
    }

    /// Bug fix (2026-08-05): the 1:1 row never read the rubrica's
    /// `avatarUrl` at all — `conversationRow` built `QAudionAvatar` with no
    /// `imageURL` argument, so it always fell back to the initials
    /// placeholder regardless of what `ContactsStore`/`AvatarAnnounceCoordinator`
    /// had cached. Group rows already do this correctly via `row.avatarUrl`
    /// (see `groupRow` above) — this mirrors that for the 1:1 case.
    private func resolvedRowAvatarUrl(_ item: ConversationListViewModel.Item) -> URL? {
        guard item.kind != .group else { return nil }
        return appState.cachedContacts.first(where: { $0.userId == item.peerUserId })?.avatarUrl
    }

    /// The peer's short number for the row preview line.
    ///
    /// Suppressed for groups, which have no single peer, and suppressed
    /// when it would merely repeat the row title: `DisplayName.forUser`'s
    /// last fallback tier returns the bare extension verbatim, so a peer
    /// with no name is ALREADY displayed by extension.
    ///
    /// `contacts:` is passed explicitly on purpose. The default is
    /// `contacts ?? ContactsStore().load()`, and that load is a UserDefaults
    /// read plus a decrypt and decode — one disk hit per row per render
    /// while the user is scrolling.
    private func resolvedRowExtension(_ item: ConversationListViewModel.Item,
                                      title: String) -> String? {
        guard item.kind != .group else { return nil }
        guard let ext = DisplayName.resolvedExtension(
            for: item.peerUserId,
            serverDisplay: item.peerDisplayName,
            contacts: appState.cachedContacts) else { return nil }
        let formatted = DisplayName.formatExtension(ext)
        return formatted == title ? nil : formatted
    }

    /// The "<ext> · " run in front of the preview snippet, as ONE builder
    /// shared by both preview branches — applied to only one, the extension
    /// would blink away whenever the user left a draft.
    @ViewBuilder
    private func rowExtensionPrefix(_ item: ConversationListViewModel.Item,
                                    title: String) -> some View {
        if let ext = resolvedRowExtension(item, title: title) {
            // spacing 0: the separator carries its own padding and the
            // enclosing HStack must not add gaps around it.
            HStack(spacing: 0) {
                Text(ext)
                    .qaudionStyle(type.labelSmall)
                    .monospaced()
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .lineLimit(1)
                Text(" · ")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .accessibilityHidden(true)
            }
            // Unweighted and never shrinking, so only the snippet truncates.
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func conversationRow(_ item: ConversationListViewModel.Item) -> some View {
        let rowTitle = resolvedRowTitle(item)
        return NavigationLink(destination: chatDestination(for: item)) {
            HStack(spacing: 12) {
                // W120: presence dot on the avatar — green when peer
                // online via PresenceService, gray when offline. Group
                // avatars don't get a dot.
                QAudionAvatar(displayName: rowTitle,
                              imageURL: resolvedRowAvatarUrl(item),
                              kind: item.kind == .group ? .group : .person,
                              size: 44,
                              presenceDot: item.kind == .group
                                  ? nil
                                  : (appState.presenceService.isOnline(item.peerUserId)
                                     ? .online : .offline))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if item.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(extras.warning)
                        }
                        if item.muted {
                            // W89: bell-slash next to the name signals the
                            // muted state. Subdued tint so it doesn't
                            // compete with the pinned indicator.
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(scheme.onSurfaceVariant)
                        }
                        Text(rowTitle)
                            .qaudionStyle(type.titleSmall)
                            .foregroundStyle(scheme.onSurface)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(formatTime(item.lastActivity))
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }
                    // W138: if a composer draft exists for this
                    // conversation, surface it as the row preview with
                    // a leading "Bozza:" tag. WhatsApp / iMessage idiom
                    // — keeps the user aware of unfinished thoughts
                    // without making them open every chat.
                    if let draftPreview = draftPreviewSnippet(for: item.conversationId) {
                        HStack {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                rowExtensionPrefix(item, title: rowTitle)
                                Text("Bozza:")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(extras.warning)
                                Text(draftPreview)
                                    .qaudionStyle(type.bodySmall)
                                    .foregroundStyle(scheme.onSurfaceVariant)
                                    .italic()
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 6)
                            if item.unreadCount > 0 {
                                Text("\(item.unreadCount)")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.onPrimary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(scheme.primary))
                            }
                        }
                    } else if let preview = item.lastMessagePreview {
                        // spacing 4 rather than the default ~8 so the run
                        // reads "100 · preview". The outer HStack stays
                        // centre-aligned: on a two-line row a first-baseline
                        // alignment would make the unread capsule ride the
                        // first line.
                        HStack(spacing: 4) {
                            rowExtensionPrefix(item, title: rowTitle)
                            Text(preview)
                                .qaudionStyle(type.bodySmall)
                                .foregroundStyle(scheme.onSurfaceVariant)
                                .lineLimit(2)
                            Spacer(minLength: 6)
                            if item.unreadCount > 0 {
                                Text("\(item.unreadCount)")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(scheme.onPrimary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(scheme.primary))
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(scheme.background)
        // W140: leading swipe — mark as read. Common iOS Mail / Messages
        // affordance. Hidden when the row already has zero unread so the
        // gesture isn't a no-op.
        .swipeActions(edge: .leading) {
            if item.unreadCount > 0 {
                Button {
                    container.markRead(conversationId: item.conversationId)
                } label: {
                    Label("Segna letto", systemImage: "envelope.open")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                container.deleteConversation(conversationId: item.conversationId)
            } label: {
                Label("Elimina", systemImage: "trash")
            }
            Button {
                container.togglePinned(conversationId: item.conversationId)
            } label: {
                Label(item.pinned ? "Sblocca" : "Fissa",
                      systemImage: item.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
            // W89: mute / unmute. Muted conversations skip unread
            // increments and (future) suppress local-notif banner.
            Button {
                container.toggleMuted(conversationId: item.conversationId)
            } label: {
                Label(item.muted ? "Riattiva" : "Silenzia",
                      systemImage: item.muted ? "bell" : "bell.slash")
            }
            .tint(.indigo)
        }
        // W119: long-press context menu mirrors the swipe actions.
        // iPad / non-touch users (Stage Manager, external trackpad)
        // can't easily access swipe actions; right-click / long-press
        // surfaces the same options through the contextMenu API.
        .contextMenu {
            // W140: surface "Segna letto" in the long-press menu too —
            // hidden when there's nothing to mark.
            if item.unreadCount > 0 {
                Button {
                    container.markRead(conversationId: item.conversationId)
                } label: {
                    Label("Segna letto", systemImage: "envelope.open")
                }
            }
            Button {
                container.togglePinned(conversationId: item.conversationId)
            } label: {
                Label(item.pinned ? "Sblocca" : "Fissa",
                      systemImage: item.pinned ? "pin.slash" : "pin")
            }
            Button {
                container.toggleMuted(conversationId: item.conversationId)
            } label: {
                Label(item.muted ? "Riattiva" : "Silenzia",
                      systemImage: item.muted ? "bell" : "bell.slash")
            }
            // W139: export the transcript as a plaintext .txt and hand
            // it to the system share sheet. Decrypted-on-device content
            // — leaves the sandbox only at the user's direction.
            Button {
                exportConversation(item: item)
            } label: {
                Label("Esporta chat", systemImage: "square.and.arrow.up.on.square")
            }
            // W157: copy the peer userId for share / debug. Useful
            // when the user wants to forward a contact via SMS / mail
            // without going through the full profile screen.
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = item.peerUserId
                snackbar?.show(.init(
                    text: "ID utente copiato.",
                    severity: .info,
                    durationSeconds: 2
                ))
                #endif
            } label: {
                Label("Copia ID utente", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                container.deleteConversation(conversationId: item.conversationId)
            } label: {
                Label("Elimina", systemImage: "trash")
            }
        }
    }

    /// W139: build the transcript file off the row tap, then surface
    /// the share sheet via `exportTarget`. The store read happens on
    /// MainActor synchronously — chat sizes are small (capped at the
    /// engine layer), so no need to dispatch off-main.
    private func exportConversation(item: ConversationListViewModel.Item) {
        let store = ConversationStore()
        let messages = store.loadMessages(conversationId: item.conversationId)
        guard let url = ConversationExporter.export(
            messages: messages,
            peerDisplayName: item.peerDisplayName
        ) else {
            snackbar?.show(.init(
                text: "Esportazione fallita.",
                severity: .error,
                durationSeconds: 3
            ))
            return
        }
        exportTarget = ExportTarget(id: url)
    }

    /// W138: read the persisted composer draft (if any) for this
    /// conversation and return a single-line snippet to surface in the
    /// row. Returns nil when no draft exists. Snippet capped at 80
    /// characters with an ellipsis since rows are tight.
    /// W155: respects the `qaudion.privacy.show_drafts_in_list` toggle
    /// — when off, this returns nil regardless of stored content so
    /// the list never reveals unsent text from the home screen.
    private func draftPreviewSnippet(for conversationId: UUID) -> String? {
        // Read the privacy toggle directly out of UserDefaults so
        // this helper doesn't need an environment dependency. Default
        // is true (show drafts), preserving existing behaviour for
        // users who never toggled it.
        let prefsKey = "qaudion.privacy.show_drafts_in_list"
        if UserDefaults.standard.object(forKey: prefsKey) != nil
           && !UserDefaults.standard.bool(forKey: prefsKey) {
            return nil
        }
        let raw = ComposerDraftStore.load(for: conversationId)
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > 80 {
            return String(collapsed.prefix(80)) + "…"
        }
        return collapsed
    }

    private static let timeFormatterHHmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let timeFormatterEEE: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE"
        return f
    }()

    private static let timeFormatterDDMM: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM"
        return f
    }()

    private static let timeFormatterDDMMYY: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy"
        return f
    }()

    private func formatTime(_ date: Date) -> String {
        // W121: more granular relative time. Order:
        //   1. < 1 min: "ora"
        //   2. same day: HH:mm
        //   3. yesterday: "ieri"
        //   4. < 7 days: weekday short
        //   5. same year: dd/MM
        //   6. older: dd/MM/yy
        let cal = Calendar.current
        let now = Date()
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60, elapsed >= 0 {
            return "ora"
        }
        if cal.isDateInToday(date) {
            return Self.timeFormatterHHmm.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "ieri"
        }
        if let days = cal.dateComponents([.day], from: date, to: now).day,
           days < 7 {
            return Self.timeFormatterEEE.string(from: date).capitalized
        }
        let nowYear = cal.component(.year, from: now)
        let dateYear = cal.component(.year, from: date)

        let f = (nowYear == dateYear) ? Self.timeFormatterDDMM : Self.timeFormatterDDMMYY
        return f.string(from: date)
    }

    @ViewBuilder
    private func chatDestination(for item: ConversationListViewModel.Item) -> some View {
        // Navigates to the new `ChatDetailScreen` (1:1 visual port of
        // Android `feature-chat/.../ChatDetailScreen.kt`). Data layer
        // (`ChatContainer` + engine) is unchanged. The legacy
        // `ChatView` and `ConversationListView` files have been removed
        // in W26 cleanup — this is the only chat entry point now.
        ChatDetailScreen(
            conversationId: item.conversationId,
            peerUserId: item.peerUserId,
            peerDisplayName: item.peerDisplayName
        )
    }

    // MARK: - New conversation by number/extension (2026-07-29)

    /// Inline row shown above the contact picker inside the "new
    /// conversation" sheet — lets the user type a raw phone number, PBX
    /// extension, or userId and start a chat directly, without needing an
    /// existing rubrica entry first. `.default` keyboard (not `.phonePad`)
    /// since the field also accepts a raw userId (letters + digits +
    /// hyphens), unlike the DialPad which is purely numeric.
    private var dialByNumberRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Numero, interno o ID utente", text: $dialInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: dialInput) { _ in dialError = nil }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(scheme.surfaceVariant.opacity(0.5))
                    )
                Button {
                    Task { await startChatFromDialInput() }
                } label: {
                    Group {
                        if isResolvingDial {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Avvia")
                                .qaudionStyle(type.labelMedium)
                        }
                    }
                    .foregroundStyle(scheme.onPrimary)
                    .frame(width: 72, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(scheme.primary))
                }
                .buttonStyle(.plain)
                .disabled(dialInput.trimmingCharacters(in: .whitespaces).isEmpty || isResolvingDial)
            }
            if let err = dialError {
                Text(err)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(extras.riskHigh)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Resolves `dialInput` via `AppState.resolveDialInput` (the same
    /// extension/E.164/userId heuristic `dialAndCall` uses for calls) and,
    /// on success, starts a chat with the resolved peer.
    private func startChatFromDialInput() async {
        dialError = nil
        isResolvingDial = true
        defer { isResolvingDial = false }
        guard let target = await appState.resolveDialInput(dialInput) else {
            dialError = appState.errorMessage ?? "Risoluzione fallita."
            return
        }
        startChatFromDial(target: target)
    }

    /// Creates-or-finds the conversation for a dial-resolved peer, exactly
    /// like `ContactsListView.openOrCreateChat`, PLUS persists the peer as
    /// a local contact if it isn't one already — unlike the contact-picker
    /// path (where the peer is by definition already a stored contact),
    /// a peer reached by typed number/extension usually is NOT yet known
    /// locally, so without this the conversation would exist but the peer
    /// would never show up in the Contacts tab.
    private func startChatFromDial(target: AppState.ResolvedDialTarget) {
        let contactsStore = ContactsStore()
        if contactsStore.load().first(where: { $0.userId == target.userId }) == nil {
            contactsStore.upsert(ContactsStore.StoredContact(
                userId: target.userId,
                displayName: target.displayLabel,
                phoneHash: "",
                avatarUrl: nil,
                lastSeen: nil,
                isVerified: false
            ))
        }
        let convStore = ConversationStore()
        let convId: UUID
        if let existing = convStore.loadConversations().first(where: { $0.peerUserId == target.userId }) {
            convId = existing.id
        } else {
            let newConv = Conversation(
                id: UUID(),
                peerUserId: target.userId,
                peerDisplayName: target.displayLabel,
                lastMessagePreview: nil,
                lastActivity: Date(),
                unreadCount: 0,
                pinned: false
            )
            convStore.upsertConversation(newConv)
            convId = newConv.id
        }
        dialInput = ""
        showingNewConversation = false
        appState.pendingDeepLinkConversationId = convId
    }

    // MARK: - Empty state

    @State private var emptyStateBounce: Bool = false

    private var emptyState: some View {
        VStack(spacing: 16) {
            // W129: gentle bounce on the empty-state icon to nudge the
            // user without being obnoxious. 1.0 → 1.08 → 1.0 over 1.4s
            // ease-in-out repeating, autoreverse=true. Matches the
            // VoiceNote pulse animation pattern (W126).
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56))
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaleEffect(emptyStateBounce ? 1.08 : 1.0)
                .animation(
                    .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: emptyStateBounce
                )
                .onAppear { emptyStateBounce = true }
            Text("Nessuna conversazione")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Text("Aggiungi un contatto per iniziare a scrivere.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            // W112: actionable CTA — opens the contacts sheet directly
            // instead of asking the user to find the FAB. Clearer
            // affordance for first-time users with no chats yet.
            Button {
                showingNewConversation = true
            } label: {
                Label("Nuova conversazione", systemImage: "plus.bubble.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(scheme.primary)
                    )
                    .foregroundStyle(scheme.onPrimary)
            }
            .buttonStyle(.plain)
            Spacer().frame(height: 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    // MARK: - FABs

    /// One primary action, carrying its own word.
    ///
    /// This used to be two stacked bare circles. The larger one
    /// (`square.and.pencil`) opened `showingNewConversation` — the identical
    /// statement to the empty-state CTA, so both were on screen at once
    /// whenever the list was empty — and neither circle showed a word to a
    /// sighted user; the only labels were `.accessibilityLabel`.
    ///
    /// "Nuovo gruppo" is what survives as the labelled capsule.
    /// Start-a-chat-by-number moves to a labelled icon in the header, next
    /// to the identity, so it is still reachable once the user has a
    /// conversation and the empty state is gone.
    private var fabStack: some View {
        Button(action: { showingNewGroup = true }) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 18, weight: .semibold))
                    // The visible Text is the label now; without this the
                    // symbol contributes a second phrase to VoiceOver.
                    .accessibilityHidden(true)
                Text("Nuovo gruppo")
                    .qaudionStyle(type.labelLarge)
            }
            .foregroundStyle(scheme.onPrimary)
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(Capsule().fill(scheme.primary))
            .shadow(color: .black.opacity(0.30), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// W293: open the admin banner's CTA URL (if any). Static helper
    /// kept on the struct so the call site closure body is a single
    /// statement — type-checker safe per CLAUDE.md §13.
    fileprivate static func openAdminCtaURL(_ url: URL?) {
        #if canImport(UIKit)
        guard let target = url else { return }
        UIApplication.shared.open(target)
        #endif
    }
}

// MARK: - AdminBannerData

/// Admin / operator banner content. Mirrors Android's `AdminMessage`.
struct AdminBannerData: Equatable {
    let title: String
    let message: String
    let ctaLabel: String?
    /// W293: optional URL for the CTA button. nil → tapping the CTA
    /// is a no-op (some banners are purely informational and the
    /// CTA is rendered just for visual emphasis). Otherwise opens
    /// in the system browser via `UIApplication.shared.open`.
    let ctaURL: URL?

    init(title: String, message: String, ctaLabel: String? = nil, ctaURL: URL? = nil) {
        self.title = title
        self.message = message
        self.ctaLabel = ctaLabel
        self.ctaURL = ctaURL
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ChatListScreen()
    }
    .environmentObject(AppState())
    .qAudionTheme(dark: true)
}
