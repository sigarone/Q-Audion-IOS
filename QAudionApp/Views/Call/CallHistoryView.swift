import SwiftUI
import QAudionEngine

/// Entry storica di una chiamata. 1:1 port di Android
/// `CallHistoryRow` (domain model in feature-call) → UI item.
/// L'engine iOS oggi espone solo `appState.recentCalls: [String]` con
/// userId puri; quando il `CallHistoryRepository` cross-platform lands
/// iOS-side, la conversione DAO → CallHistoryEntry sostituisce lo stub
/// `CallHistoryStore.mock` qui sotto.
public struct CallHistoryEntry: Equatable, Identifiable {
    public enum Direction: String, Equatable, Sendable {
        case incoming, outgoing, missed
    }

    public let id: String
    public let peerUserId: String
    public let peerDisplay: String
    public let direction: Direction
    public let startedAt: Date
    /// Durata della chiamata in secondi. nil per missed/ongoing.
    public let durationSeconds: Int?
    public let isVideo: Bool
    /// Internal extension (PBX). Rendered bare, no prefix word (Pavel rule,
    /// 2026-07-29) — e.g. "103", never "Int. 103".
    public let peerExtension: Int?
    /// Bug fix (2026-08-05): rubrica's cached E2EE avatar (`ContactsStore
    /// .StoredContact.avatarUrl`, a local `file://` path — see
    /// `AvatarAnnounceCoordinator`). The row used to hardcode `imageURL: nil`
    /// so a contact's avatar update never reached this list even though the
    /// rubrica itself showed it correctly.
    public let peerAvatarUrl: URL?

    public init(id: String, peerUserId: String, peerDisplay: String,
                direction: Direction, startedAt: Date,
                durationSeconds: Int?, isVideo: Bool,
                peerExtension: Int? = nil,
                peerAvatarUrl: URL? = nil) {
        self.id = id
        self.peerUserId = peerUserId
        self.peerDisplay = peerDisplay
        self.direction = direction
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.isVideo = isVideo
        self.peerExtension = peerExtension
        self.peerAvatarUrl = peerAvatarUrl
    }
}

/// Call history store backed by `PersistentCallRecordStore`.
///
/// Primary source: `PersistentCallRecordStore.shared.records` —
/// real per-call data with accurate timestamps, duration, and direction.
/// Fallback: `appState.recentCalls` — backwards-compat on first launch
/// after upgrade (no metadata, displayed as outgoing stubs so the list
/// isn't empty immediately post-update).
@MainActor
final class CallHistoryStore: ObservableObject {
    @Published private(set) var entries: [CallHistoryEntry] = []
    @Published private(set) var loading: Bool = false

    /// Refresh from PersistentCallRecordStore. Falls back to
    /// `appState.recentCalls` stubs when the persistent store is empty
    /// (first launch after upgrade from pre-persistent build).
    func refresh(cachedContacts: [ContactsStore.StoredContact], recentCalls: [String]) {
        loading = true
        let persistedRecords = PersistentCallRecordStore.shared.records
        // Bug fix (2026-08-05): built alongside nameMap so both history
        // paths below can stamp the rubrica's current avatar onto each
        // entry — this map used to only carry displayName, so the row's
        // avatar was never sourced from ContactsStore at all.
        var avatarMap: [String: URL] = [:]
        for c in cachedContacts { if let url = c.avatarUrl { avatarMap[c.userId] = url } }
        if !persistedRecords.isEmpty {
            // Re-resolve display names at RENDER time using the passed snapshot,
            // avoiding a UserDefaults decode on each history load/refresh.
            var nameMap: [String: String] = [:]
            for c in cachedContacts where !c.displayName.isEmpty { nameMap[c.userId] = c.displayName }
            entries = persistedRecords.map { Self.toEntry($0, nameByUserId: nameMap, avatarByUserId: avatarMap) }
        } else {
            // Backwards-compat stub path: builds display-name-resolved
            // outgoing entries from the legacy recentCalls list.
            var nameMap: [String: String] = [:]
            for c in cachedContacts where !c.displayName.isEmpty {
                nameMap[c.userId] = c.displayName
            }
            let recents = recentCalls
            let now = Date()
            var out: [CallHistoryEntry] = []
            for (idx, userId) in recents.enumerated() {
                let started = now.addingTimeInterval(-Double(idx) * 300)
                let display = PersistentCallRecordStore.resolveDisplayName(
                    userId: userId, wireDisplay: nil, nameByUserId: nameMap)
                out.append(.init(
                    id: "stub-\(idx)-\(userId)",
                    peerUserId: userId,
                    peerDisplay: display,
                    direction: .outgoing,
                    startedAt: started,
                    durationSeconds: nil,
                    isVideo: false,
                    peerExtension: nil,
                    peerAvatarUrl: avatarMap[userId]
                ))
            }
            entries = out
        }
        loading = false
    }

    /// Convert a persisted record to the UI model used by CallHistoryRow.
    private static func toEntry(_ record: CallRecord,
                                nameByUserId: [String: String] = [:],
                                avatarByUserId: [String: URL] = [:]) -> CallHistoryEntry {
        let dir: CallHistoryEntry.Direction
        switch record.direction {
        case .incoming: dir = .incoming
        case .outgoing: dir = .outgoing
        case .missed:   dir = .missed
        }
        // W-EXTPREFIX consolidation (2026-07-29): this used to be an
        // independent copy of the priority chain (live rubrica name > a
        // stored "real" name checked only for UUID-shape, not placeholder
        // shape > "Int. NNN" > `resolveDisplayName`) — a stale "Phone #100"
        // in either `nameByUserId` or `record.peerDisplayName` rendered
        // verbatim. Now a single call into the canonical `DisplayName
        // .forUser`: `nameByUserId` (live rubrica) wins first via
        // `contacts`, then `record.peerDisplayName` (the persisted value at
        // call time) via `serverDisplay`, then `record.peerExtension` —
        // every source subject to the SAME placeholder check.
        let display: String = {
            var contacts: [ContactsStore.StoredContact] = []
            if let n = nameByUserId[record.peerUserId], !n.isEmpty {
                contacts = [ContactsStore.StoredContact(
                    userId: record.peerUserId, displayName: n, phoneHash: "",
                    avatarUrl: nil, lastSeen: nil, isVerified: false)]
            }
            return DisplayName.forUser(
                record.peerUserId,
                serverDisplay: record.peerDisplayName,
                knownExtension: record.peerExtension.flatMap { $0 > 0 ? String($0) : nil },
                contacts: contacts
            )
        }()
        return CallHistoryEntry(
            id: record.id,
            peerUserId: record.peerUserId,
            peerDisplay: display,
            direction: dir,
            startedAt: record.startedAt,
            durationSeconds: record.durationSeconds,
            isVideo: record.isVideo,
            peerExtension: record.peerExtension,
            peerAvatarUrl: avatarByUserId[record.peerUserId]
        )
    }

    /// No-op — kept for call-site compatibility. Real seeding is handled
    /// by PersistentCallRecordStore during actual calls.
    func seedWithMockIfEmpty() {}

    /// Delete a single entry. Delegates to PersistentCallRecordStore so
    /// the deletion survives restarts without a separate tombstone set.
    func deleteEntry(_ entryId: String) {
        entries.removeAll { $0.id == entryId }
        PersistentCallRecordStore.shared.deleteRecord(entryId)
    }

    /// Clear all history. Delegates to PersistentCallRecordStore.
    func clearAll() {
        PersistentCallRecordStore.shared.clearAll()
        entries.removeAll()
    }

    static let mockData: [CallHistoryEntry] = [
        .init(id: "h1", peerUserId: "user-mario", peerDisplay: "Mario Rossi",
              direction: .incoming,
              startedAt: Date().addingTimeInterval(-1800),
              durationSeconds: 161, isVideo: false, peerExtension: 103),
        .init(id: "h2", peerUserId: "user-anna", peerDisplay: "Anna Bianchi",
              direction: .missed,
              startedAt: Date().addingTimeInterval(-7200),
              durationSeconds: nil, isVideo: false, peerExtension: 207),
        .init(id: "h3", peerUserId: "user-luigi", peerDisplay: "Luigi Verdi",
              direction: .outgoing,
              startedAt: Date().addingTimeInterval(-86_400),
              durationSeconds: 420, isVideo: true, peerExtension: nil)
    ]
}

/// Schermo "Chiamate" — call history list. 1:1 port di Android
/// `qaudion-android-new/feature/feature-call/.../CallHistoryScreen.kt`.
///
/// Layout (top → bottom):
///   - TopBar "Chiamate" + trailing icone person.2 / dial.fill
///   - List rows: avatar 48 + name + direction icon + timestamp + duration
///   - Empty state "Nessuna chiamata recente"
///   - Tap row → openPeer (chat detail)
///   - Trailing icons row → audio call / video call
struct CallHistoryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var store = CallHistoryStore()
    /// Observe the shared persistent store so the list refreshes
    /// automatically when a call ends and `records` changes.
    @ObservedObject private var persistedStore = PersistentCallRecordStore.shared

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    @State private var showingDialPad = false
    @State private var showingGroupComposer = false
    @State private var showingClearAllConfirm = false
    /// 2026-07-29 fix (Pavel: dialed a real phone number, "nothing
    /// happened") — `DialPadSheet` dismisses synchronously the instant
    /// "chiama" is tapped, before `dialAndCall`'s async resolution even
    /// starts, and nothing on this screen ever read `appState.errorMessage`
    /// (the resolve-failure path DOES set it correctly — mirrors
    /// `ChatListScreen`'s `dialError` — it was just never surfaced here).
    /// A local, screen-owned var (not bound live to the shared
    /// `errorMessage`) so an unrelated later error elsewhere in the app
    /// can't pop this alert back up.
    @State private var dialCallError: String?

    /// W296: filter toggle. When true, only missed calls are shown.
    /// State persists for the lifetime of the screen instance, not
    /// across launches (intentional — most users want this scoped
    /// to a single triage session).
    @State private var missedOnly: Bool = false

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                content
            }
        }
        // W460: same fix as SettingsScreen — replace deprecated API.
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            store.refresh(cachedContacts: appState.cachedContacts, recentCalls: appState.recentCalls)
            store.seedWithMockIfEmpty()
        }
        // Reactive refresh: when PersistentCallRecordStore.shared.records
        // changes (e.g. a call just ended and got its endedAt stamped),
        // re-derive the entry list so duration/direction update in-place.
        .onChange(of: persistedStore.records.count) { _ in
            store.refresh(cachedContacts: appState.cachedContacts, recentCalls: appState.recentCalls)
        }
        // Bug fix (2026-08-05): this screen never observed .contactsDidChange
        // at all — a fresh avatar_announce (or a display-name/extension fix)
        // landed in ContactsStore but `entries` (built once by `refresh` and
        // cached in @Published) never got recomputed, so the row stayed
        // stale until the user left and re-entered "Chiamate". Mirrors the
        // records-count reload above.
        .onReceive(NotificationCenter.default.publisher(for: .contactsDidChange)) { _ in
            store.refresh(cachedContacts: appState.cachedContacts, recentCalls: appState.recentCalls)
        }
        .sheet(isPresented: $showingDialPad) {
            DialPadSheet(onCall: { dialed in
                showingDialPad = false
                // W414: il numero digitato non è uno user_id BCrypto —
                // può essere una short extension PBX (es. "175") o un
                // E.164 (+39...). Risolviamo prima a userId via
                // /api/v1/directory/by-extension/{n} per gli interi
                // corti, altrimenti via /contacts/discover-v2 per
                // E.164. Senza questa risoluzione il server riceve
                // recipient_id='175' e droppa il segnale silenziosamente
                // (Android non squilla).
                Task {
                    appState.errorMessage = nil
                    await appState.dialAndCall(rawInput: dialed, video: false)
                    if let err = appState.errorMessage {
                        dialCallError = err
                    }
                }
            })
            // Su iPad il sheet viene presentato come floating card —
            // un'altezza fissa di 560pt lo rende compatto e centrato
            // invece di occupare quasi tutto lo schermo.
            .presentationDetents([.height(560)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingGroupComposer) {
            // W45: sostituito GroupComposerPlaceholderSheet (stale) con il
            // vero CreateGroupScreen. W40 è già live in v1.0.86+, quindi
            // il placeholder "in arrivo" era obsoleto. onGroupCreated
            // chiude il sheet e mostra snackbar; in futuro, una volta
            // wired startGroupCall, può anche aprire direttamente la
            // chiamata di gruppo invece della chat.
            NavigationStack {
                CreateGroupScreen(onGroupCreated: { _ in
                    showingGroupComposer = false
                })
            }
        }
        // W47: alert di conferma per clear-all dello storico.
        .alert("Cancella tutto lo storico?",
               isPresented: $showingClearAllConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Cancella", role: .destructive) {
                store.clearAll()
                // W70: replay loop server-side (best-effort fire-and-forget).
                if let sync = TrackBSyncService.from(serverUrl: appState.serverUrl, token: appState.authService.loadToken()) {
                    Task { await sync.deleteAllCallHistory() }
                }
            }
        } message: {
            Text("Verranno rimosse \(store.entries.count) chiamate dallo storico locale. L'azione non si può annullare.")
        }
        // 2026-07-29 fix — see dialCallError kdoc above.
        .alert("Chiamata non riuscita",
               isPresented: Binding(
                    get: { dialCallError != nil },
                    set: { if !$0 { dialCallError = nil } }
               )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dialCallError ?? "")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Chiamate")
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            // W47: overflow menu — "Cancella tutto" sullo storico.
            // Disabled quando la lista è già vuota.
            Menu {
                Button(role: .destructive) {
                    showingClearAllConfirm = true
                } label: {
                    Label("Cancella storico", systemImage: "trash")
                }
                .disabled(store.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Altro")
            Button(action: { showingGroupComposer = true }) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Nuova chiamata di gruppo")
            Button(action: { showingDialPad = true }) {
                Image(systemName: "dial.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Componi numero")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.loading && store.entries.isEmpty {
            QAudionLoadingState(message: "Caricamento storico…")
        } else if store.entries.isEmpty {
            emptyState
        } else {
            list
        }
    }

    /// W296: visible entries — either all of `store.entries` or just
    /// the `.missed` ones depending on the filter toggle. Computed at
    /// render time so toggling is reactive without re-fetch.
    private var visibleEntries: [CallHistoryEntry] {
        if missedOnly {
            return store.entries.filter { $0.direction == .missed }
        }
        return store.entries
    }

    /// W296: filter toggle row. Renders only when there's at least
    /// one entry (avoids cluttering the empty state).
    @ViewBuilder
    private var filterRow: some View {
        if !store.entries.isEmpty {
            HStack(spacing: 8) {
                Toggle(isOn: $missedOnly) {
                    Text("Solo perse")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurface)
                }
                .toggleStyle(.switch)
                .tint(extras.warning)
                Spacer()
                Text(Self.filterCountLabel(
                    total: store.entries.count,
                    visible: visibleEntries.count,
                    filtered: missedOnly
                ))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private static func filterCountLabel(total: Int, visible: Int, filtered: Bool) -> String {
        if filtered {
            return String(visible) + " di " + String(total)
        }
        return String(total)
    }

    private var list: some View {
        List {
            // W296: insertion of filterRow at the top of the List as a
            // pseudo-header. Hidden when no entries (empty state takes
            // over instead of `list`).
            filterRow
                .listRowBackground(scheme.background)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            ForEach(visibleEntries) { entry in
                CallHistoryRow(entry: entry,
                               onAudioCall: { peerId in
                    Task { await appState.startCall(contactId: peerId, video: false) }
                }, onVideoCall: { peerId in
                    Task { await appState.startCall(contactId: peerId, video: true) }
                }, onChat: { peerId, displayName in
                    openOrCreateChat(peerUserId: peerId, displayName: displayName)
                })
                .listRowBackground(scheme.background)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16,
                                          bottom: 4, trailing: 16))
                // W47: swipe-to-delete sulla singola entry. Engine wire
                // (real `CallHistoryRepository.delete`) deferred — oggi
                // muta solo lo store in-memoria.
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteEntry(entry.id)
                        // W70: replay server-side (best-effort).
                        if let sync = TrackBSyncService.from(serverUrl: appState.serverUrl, token: appState.authService.loadToken()) {
                            let id = entry.id
                            Task { await sync.deleteCallHistoryEntry(id) }
                        }
                    } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(scheme.background)
        .refreshable { store.refresh(cachedContacts: appState.cachedContacts, recentCalls: appState.recentCalls) }
    }

    /// Find existing or create new conversation for a peer, then trigger
    /// ChatListScreen navigation via AppState deep-link.
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "phone.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text("Nessuna chiamata recente")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Text("Componi un numero o un ID contatto per fare la prima chiamata sicura.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // W62: CTA empty-state "Componi numero" — stesso flow del
            // bottone dial in topBar, accessibile inline così first-
            // launch users hanno un next-step chiaro. Riusa il
            // `showingDialPad` esistente, single source of truth.
            Button {
                showingDialPad = true
            } label: {
                Label("Componi numero", systemImage: "dial.fill")
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onPrimary)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(
                        Capsule().fill(scheme.primary)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer()
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

private struct CallHistoryRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let entry: CallHistoryEntry
    let onAudioCall: (String) -> Void
    let onVideoCall: (String) -> Void
    let onChat: (String, String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            QAudionAvatar(displayName: entry.peerDisplay,
                          imageURL: entry.peerAvatarUrl,
                          size: 48,
                          shortNumber: entry.peerExtension.map(String.init))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.peerDisplay)
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(entry.direction == .missed
                                     ? extras.riskHigh
                                     : scheme.onSurface)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: directionIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(directionColor)
                    Text(metadataLine)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(1)
                        .modifier(MonoCaption())
                    if entry.isVideo {
                        Image(systemName: "video.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(extras.pqcAccent)
                    }
                }
            }

            Spacer(minLength: 8)

            Button(action: { onChat(entry.peerUserId, entry.peerDisplay) }) {
                Image(systemName: "bubble.right")
                    .font(.system(size: 18))
                    .foregroundStyle(scheme.primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Chatta con \(entry.peerDisplay)")

            Button(action: { onAudioCall(entry.peerUserId) }) {
                Image(systemName: "phone")
                    .font(.system(size: 18))
                    .foregroundStyle(extras.success)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Chiama \(entry.peerDisplay)")

            Button(action: { onVideoCall(entry.peerUserId) }) {
                Image(systemName: "video.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(extras.pqcAccent)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Videochiama \(entry.peerDisplay)")
        }
        .padding(.vertical, 6)
    }

    private var directionIcon: String {
        switch entry.direction {
        case .incoming: return "phone.arrow.down.left.fill"
        case .outgoing: return "phone.arrow.up.right.fill"
        case .missed:   return "phone.down.fill"
        }
    }

    private var directionColor: Color {
        switch entry.direction {
        case .incoming: return extras.success
        case .outgoing: return scheme.onSurfaceVariant
        case .missed:   return extras.riskHigh
        }
    }

    private var metadataLine: String {
        var parts: [String] = []
        // Pavel, 2026-07-29: bare digits, no "Int." prefix — this subtitle
        // must show the SAME string as the title above it would if the
        // peer had no real name (rule 3), never a differently-formatted
        // copy of the identical extension.
        if let ext = entry.peerExtension, ext > 0 {
            parts.append(String(ext))
        }
        parts.append(timestampLabel)
        if let dur = entry.durationSeconds {
            parts.append(String(format: "%d:%02d", dur / 60, dur % 60))
        } else if entry.direction == .missed {
            parts.append("persa")
        }
        return parts.joined(separator: " · ")
    }

    private static let timeFormatterHHmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let timeFormatterEEEHHmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    private static let timeFormatterDDMMHHmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    private var timestampLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(entry.startedAt) {
            return Self.timeFormatterHHmm.string(from: entry.startedAt)
        } else if cal.isDateInYesterday(entry.startedAt) {
            return "Ieri"
        } else if let days = cal.dateComponents([.day], from: entry.startedAt, to: Date()).day,
                  days < 7 {
            return Self.timeFormatterEEEHHmm.string(from: entry.startedAt)
        } else {
            return Self.timeFormatterDDMMHHmm.string(from: entry.startedAt)
        }
    }
}

private struct MonoCaption: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(.caption, design: .monospaced))
    }
}

// MARK: - DialPad sheet

/// Sheet "Componi numero" con griglia dialpad in-app.
/// Non usa la tastiera sistema — ogni tasto aggiunge un carattere
/// con haptic feedback, il backspace rimuove l'ultimo.
private struct DialPadSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""
    let onCall: (String) -> Void

    private let keys: [[DialKey]] = [
        [.digit("1", ""),    .digit("2", "ABC"), .digit("3", "DEF")],
        [.digit("4", "GHI"), .digit("5", "JKL"), .digit("6", "MNO")],
        [.digit("7", "PQRS"),.digit("8", "TUV"), .digit("9", "WXYZ")],
        [.symbol("*"),       .digit("0", "+"),   .symbol("+")],
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                scheme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Display numero composto
                    ZStack {
                        Text(input.isEmpty ? "——" : input)
                            .font(.system(size: 38, weight: .semibold, design: .monospaced))
                            .foregroundStyle(input.isEmpty ? scheme.onSurfaceVariant.opacity(0.4) : scheme.onSurface)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, 56)
                        HStack {
                            Spacer()
                            Button {
                                guard !input.isEmpty else { return }
                                input.removeLast()
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Image(systemName: "delete.backward")
                                    .font(.system(size: 22))
                                    .foregroundStyle(input.isEmpty ? scheme.onSurfaceVariant.opacity(0.3) : scheme.onSurfaceVariant)
                            }
                            .buttonStyle(.plain)
                            .disabled(input.isEmpty)
                            .padding(.trailing, 16)
                            .accessibilityLabel("Cancella ultima cifra")
                        }
                    }
                    .frame(height: 64)
                    .padding(.top, 16)

                    Divider()
                        .background(scheme.outline.opacity(0.3))
                        .padding(.vertical, 8)

                    // Griglia 3×4
                    VStack(spacing: 4) {
                        ForEach(keys.indices, id: \.self) { row in
                            HStack(spacing: 4) {
                                ForEach(keys[row]) { key in
                                    DialKeyButton(key: key, scheme: scheme, type: type) {
                                        input.append(key.value)
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // Riga backspace + chiama
                    HStack(spacing: 16) {
                        Spacer()
                        Button {
                            let trimmed = input.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            onCall(trimmed)
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(scheme.onPrimary)
                                .frame(width: 68, height: 68)
                                .background(
                                    Circle().fill(input.isEmpty ? scheme.surfaceVariant : extras.success)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(input.isEmpty)
                        .animation(.easeInOut(duration: 0.2), value: input.isEmpty)
                        .accessibilityLabel("Chiama")
                        Spacer()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Componi numero")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }
}

private enum DialKey: Identifiable, Equatable {
    case digit(String, String)  // main, sub-label (ABC etc.)
    case symbol(String)

    var id: String { value }

    var value: String {
        switch self {
        case .digit(let v, _): return v
        case .symbol(let v):   return v
        }
    }

    var label: String {
        switch self {
        case .digit(let v, _): return v
        case .symbol(let v):   return v
        }
    }

    var sublabel: String? {
        switch self {
        case .digit(_, let s): return s.isEmpty ? nil : s
        case .symbol:          return nil
        }
    }
}

private struct DialKeyButton: View {
    let key: DialKey
    let scheme: QAudionColorScheme
    let type: QAudionTypography
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(key.label)
                    .font(.system(size: 28, weight: .regular, design: .rounded))
                    .foregroundStyle(scheme.onSurface)
                if let sub = key.sublabel {
                    Text(sub)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .tracking(1.5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
        }
        .buttonStyle(DialKeyStyle(scheme: scheme))
    }
}

private struct DialKeyStyle: ButtonStyle {
    let scheme: QAudionColorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(configuration.isPressed
                          ? AnyShapeStyle(scheme.surfaceVariant)
                          : AnyShapeStyle(Color.clear))
            )
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Group composer placeholder

// W45: GroupComposerPlaceholderSheet removed. The "Nuovo gruppo" sheet
// now routes to the real CreateGroupScreen (W40), which is already
// live since v1.0.86 — the placeholder explanatory copy was stale.

#Preview {
    CallHistoryView()
        .environmentObject(AppState())
        .qAudionTheme(dark: true)
}
