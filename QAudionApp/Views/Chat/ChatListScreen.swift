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
///   2. "Gruppi"       — group conversations (`ConversationKind.group`).
///                        Visual = 56pt card with group avatar + member-count
///                        chip; horizontal scroll of cards.
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

                    if !groups.isEmpty {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(groups, id: \.conversationId) { item in
                                        NavigationLink(destination: chatDestination(for: item)) {
                                            groupCard(item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
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
        .navigationTitle("Chat")
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
                        if let sync = TrackBSyncService.from(appState) {
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

    private var groups: [ConversationListViewModel.Item] {
        container.viewModel.filteredItems.filter { $0.kind == .group }
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
                    Button(cta) { /* TODO: wire to admin URL/action */ }
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

    // MARK: - Group card

    private func groupCard(_ item: ConversationListViewModel.Item) -> some View {
        VStack(spacing: 6) {
            QAudionAvatar(displayName: item.peerDisplayName,
                          kind: .group,
                          size: 56)
            Text(item.peerDisplayName)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .frame(maxWidth: 80)
        }
        .padding(.horizontal, 4)
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
    private func draftPreviewSnippet(for conversationId: UUID) -> String? {
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
}

// MARK: - AdminBannerData

/// Admin / operator banner content. Mirrors Android's `AdminMessage`.
struct AdminBannerData: Equatable {
    let title: String
    let message: String
    let ctaLabel: String?
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ChatListScreen()
    }
    .environmentObject(AppState())
    .qAudionTheme(dark: true)
}
