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
/// 2 FABs anchored bottom-trailing (matches Android `Box`+`Column`):
///   - secondary FAB (small, surface bg) → "Nuovo gruppo"
///   - primary FAB (large, primary bg)   → "Nuova chat"
///
/// Search field uses `.searchable` (system standard) so iOS keyboard +
/// "Cancel" affordance Just Work; Compose's TopBar TextField is the
/// equivalent UX on Android.
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

    @State private var searchText: String = ""
    @State private var showingNewConversation = false
    @State private var showingNewGroup = false
    /// W94: deep-link state. When `appState.pendingDeepLinkConversationId`
    /// is published (notification tap), `deepLinkItem` captures the
    /// matching conversation and `deepLinkActive` flips on, triggering
    /// `navigationDestination(isPresented:)` to push ChatDetailScreen.
    @State private var deepLinkItem: ConversationListViewModel.Item? = nil
    @State private var deepLinkActive: Bool = false
    @State private var adminBannerDismissed = false
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
                List {
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
            }

            fabStack
                .padding(.trailing, 16)
                .padding(.bottom, 16)
        }
        // W146: surface total unread inside the nav title — "Chat (3)"
        // when there's something to read, plain "Chat" otherwise.
        // iOS Mail / Messages idiom that keeps the count visible even
        // when individual rows are scrolled off-screen.
        .navigationTitle(container.totalUnread > 0
                         ? "Chat (\(container.totalUnread))"
                         : "Chat")
        .navigationBarTitleDisplayMode(.inline)
        // W50: overflow menu — "Segna tutti come letti" gated dal
        // count totale di unread. Disabilitato quando la lista è
        // tutta letta. Snackbar feedback con il count azzerato.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(scheme.onSurface)
                }
                .accessibilityLabel("Altro")
            }
        }
        .searchable(text: $searchText, prompt: "Cerca conversazioni")
        .onChange(of: searchText) { newValue in
            // iOS 16 single-param form (the iOS 17 onChange takes
            // (oldValue, newValue) — Codemagic's xcode 26 still has to
            // back-deploy to iOS 16 since CLAUDE.md pins target = 16.0).
            container.setSearchQuery(newValue)
        }
        .refreshable { container.loadFromStore() }
        // Fase 1B — recompute the group rows' preview / unread / time when a
        // group message lands or is marked read (GroupMessageStore signals
        // via NotificationCenter, not an @Published property).
        .onReceive(NotificationCenter.default.publisher(
            for: GroupMessageStore.didChangeNotification)) { _ in
            groupRefreshToken &+= 1
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
        .sheet(isPresented: $showingNewConversation) {
            NavigationStack {
                ContactsListView()
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
                    // W40.C: dopo create, presentiamo full-screen
                    // il GroupChatScreen del nuovo gruppo. Il nome è
                    // un placeholder finché l'engine non espone i
                    // metadati del gruppo (membership / admins).
                    showingNewGroup = false
                    openedGroup = OpenedGroup(
                        id: newGroupId,
                        name: "Nuovo gruppo",
                        memberCount: 1   // placeholder: solo "Tu"
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
                name: e.name,
                memberCount: e.members.count,
                epoch: Int(e.epoch),
                preview: (last?.text.isEmpty == false) ? last?.text : nil,
                lastActivity: last?.ts ?? e.joinedAt,
                unread: GroupMessageStore.shared.unreadCount(forGroupHex: e.id))
        }
        .sorted { $0.lastActivity > $1.lastActivity }
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
                QAudionAvatar(displayName: row.name, kind: .group, size: 44)
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

    private func conversationRow(_ item: ConversationListViewModel.Item) -> some View {
        NavigationLink(destination: chatDestination(for: item)) {
            HStack(spacing: 12) {
                // W120: presence dot on the avatar — green when peer
                // online via PresenceService, gray when offline. Group
                // avatars don't get a dot.
                QAudionAvatar(displayName: item.peerDisplayName,
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
                        Text(item.peerDisplayName)
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
                            HStack(spacing: 4) {
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
                        HStack {
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
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "ieri"
        }
        if let days = cal.dateComponents([.day], from: date, to: now).day,
           days < 7 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateFormat = "EEE"
            return f.string(from: date).capitalized
        }
        let nowYear = cal.component(.year, from: now)
        let dateYear = cal.component(.year, from: date)
        let f = DateFormatter()
        f.dateFormat = (nowYear == dateYear) ? "dd/MM" : "dd/MM/yy"
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

    private var fabStack: some View {
        VStack(spacing: 12) {
            Button(action: { showingNewGroup = true }) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(scheme.surface))
                    .overlay(Circle().stroke(scheme.outline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
            .accessibilityLabel("Nuovo gruppo")

            Button(action: { showingNewConversation = true }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(scheme.onPrimary)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(scheme.primary))
                    .shadow(color: .black.opacity(0.30), radius: 8, y: 4)
            }
            .accessibilityLabel("Nuova chat")
        }
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
