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

    @State private var searchText: String = ""
    @State private var showingNewConversation = false
    @State private var showingNewGroup = false
    @State private var adminBannerDismissed = false

    /// Optional admin banner content. Wired from AppState in a future
    /// pass; nil hides the section. Hard-coding nil today keeps the
    /// screen behaviour identical to the previous list while we wait
    /// for the Android-side AdminMessage feed to be exposed iOS-side.
    private var adminBanner: AdminBannerData? {
        // TODO(W19.H): wire to a real AdminMessage feed from the engine.
        // For now, surface a friendly first-launch hint when the user
        // has zero conversations and no banner has been dismissed yet.
        guard !adminBannerDismissed,
              container.viewModel.items.isEmpty,
              container.searchText.isEmpty else { return nil }
        return AdminBannerData(
            title: "Q-Audion attivo",
            message: "Le tue chiamate e i tuoi messaggi sono protetti con ML-KEM 1024 + Voice-as-Key.",
            ctaLabel: nil
        )
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
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Cerca conversazioni")
        .onChange(of: searchText) { newValue in
            // iOS 16 single-param form (the iOS 17 onChange takes
            // (oldValue, newValue) — Codemagic's xcode 26 still has to
            // back-deploy to iOS 16 since CLAUDE.md pins target = 16.0).
            container.setSearchQuery(newValue)
        }
        .refreshable { container.loadFromStore() }
        .sheet(isPresented: $showingNewConversation) {
            NavigationStack {
                ContactsListView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingNewConversation = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingNewGroup) {
            // Placeholder: full group-creation flow lands in a later wave.
            // The sheet at least prevents a "FAB does nothing" dead-end.
            VStack(spacing: 16) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(scheme.primary)
                Text("Nuovo gruppo")
                    .qaudionStyle(type.titleLarge)
                    .foregroundStyle(scheme.onSurface)
                Text("La creazione di gruppi sarà disponibile a breve.")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Chiudi") { showingNewGroup = false }
                    .padding(.top, 8)
            }
            .padding()
            .presentationDetents([.medium])
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
                QAudionAvatar(displayName: item.peerDisplayName,
                              kind: item.kind == .group ? .group : .person,
                              size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if item.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(extras.warning)
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
                    if let preview = item.lastMessagePreview {
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
        }
    }

    private func formatTime(_ date: Date) -> String {
        // Same day → HH:mm; this week → weekday short; older → dd/MM.
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day,
           days < 7 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateFormat = "EEE"
            return f.string(from: date).capitalized
        }
        let f = DateFormatter()
        f.dateFormat = "dd/MM"
        return f.string(from: date)
    }

    @ViewBuilder
    private func chatDestination(for item: ConversationListViewModel.Item) -> some View {
        // W20: navigate to the new `ChatDetailScreen` (1:1 visual port of
        // Android `feature-chat/.../ChatDetailScreen.kt`) instead of the
        // legacy `ChatView`. Data layer (`ChatContainer` + engine) is
        // unchanged. The legacy `ChatView` is still wired from the
        // older `ConversationListView` entry point — that file will be
        // removed once nothing references it.
        ChatDetailScreen(
            conversationId: item.conversationId,
            peerUserId: item.peerUserId,
            peerDisplayName: item.peerDisplayName
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Nessuna conversazione")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Text("Inizia una nuova chat o un gruppo dai pulsanti in basso.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
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
