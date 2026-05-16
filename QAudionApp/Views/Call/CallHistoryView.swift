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
    /// Internal extension (PBX). Italian copy: "Int. {ext}".
    public let peerExtension: Int?

    public init(id: String, peerUserId: String, peerDisplay: String,
                direction: Direction, startedAt: Date,
                durationSeconds: Int?, isVideo: Bool,
                peerExtension: Int? = nil) {
        self.id = id
        self.peerUserId = peerUserId
        self.peerDisplay = peerDisplay
        self.direction = direction
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.isVideo = isVideo
        self.peerExtension = peerExtension
    }
}

/// Storage stub per la call-history. Sostituire con
/// `CallHistoryRepository` (engine) quando esposto iOS-side.
@MainActor
final class CallHistoryStore: ObservableObject {
    @Published private(set) var entries: [CallHistoryEntry] = []
    @Published private(set) var loading: Bool = false

    /// Refresh dalle fonti disponibili. Oggi: degrada a
    /// `appState.recentCalls` (lista `[String]` di userId, no metadata).
    /// Quando l'engine wires il vero repository, questa funzione
    /// chiama il DAO + traduce in `CallHistoryEntry`.
    ///
    /// 2026-05-08 fix v1.0.417 — Pavel reported the call-history list
    /// was still rendering raw UUIDs even after the v1.0.416 caller-ID
    /// substitution fix (which only touched the inbound CallKit path).
    /// We now resolve `peerDisplay` against the local `ContactsStore`
    /// (rubrica) at refresh time. Same priority as the inbound handler:
    ///   1. local rubrica display name
    ///   2. legacy mock prefix strip (`user-mario` → "Mario")
    ///   3. raw userId (last-resort fallback)
    /// The peer's "public phone number" is NOT available here because
    /// the engine repository doesn't persist call records yet, so we
    /// only stash the rubrica match. When the engine repo lands, the
    /// resolved `caller_display` from the wire will fold in here too.
    func refresh(from appState: AppState) {
        loading = true
        // Pre-load contacts ONCE per refresh — `ContactsStore.load()`
        // hits UserDefaults + JSON-decodes the full list, so resolving
        // 20 recents inline would be 20 disk hits. Build a lookup dict.
        let stored = ContactsStore().load()
        var nameByUserId: [String: String] = [:]
        for c in stored where !c.displayName.isEmpty {
            nameByUserId[c.userId] = c.displayName
        }
        // Best-effort: per ogni recentCalls userId, costruiamo
        // un'entry "outgoing" con startedAt = adesso − idx × 5 min,
        // duration random 30-300s. Stub fino al wiring engine.
        let recents = appState.recentCalls
        let now = Date()
        var out: [CallHistoryEntry] = []
        for (idx, userId) in recents.enumerated() {
            let started = now.addingTimeInterval(-Double(idx) * 300)
            let dur = (idx % 3 == 0) ? nil : Int.random(in: 30...300)
            let dir: CallHistoryEntry.Direction = (idx % 3 == 0) ? .missed
                                                : (idx % 2 == 0) ? .outgoing
                                                : .incoming
            out.append(.init(
                id: "stub-\(idx)-\(userId)",
                peerUserId: userId,
                peerDisplay: Self.resolvePeerDisplay(
                    userId: userId,
                    nameByUserId: nameByUserId
                ),
                direction: dir,
                startedAt: started,
                durationSeconds: dur,
                isVideo: idx % 4 == 0,
                peerExtension: nil
            ))
        }
        // W68: filter out tombstoned IDs (deletions survived restart).
        let tombstones = Self.deletedIds
        entries = out.filter { !tombstones.contains($0.id) }
        loading = false
    }

    /// Resolve a peer's display string for the call-history row using the
    /// same priority as the inbound `call_incoming` handler in AppState.
    /// Pure helper so the logic stays testable independently of UserDefaults.
    static func resolvePeerDisplay(
        userId: String,
        nameByUserId: [String: String]
    ) -> String {
        if let name = nameByUserId[userId], !name.isEmpty {
            return name
        }
        // Legacy mock convention `user-<name>` — kept so existing
        // SwiftUI previews & test fixtures still render readable.
        if userId.hasPrefix("user-") {
            return String(userId.dropFirst(5)).capitalized
        }
        return userId
    }

    /// Seed the store with mock entries if empty. Used by the view's
    /// onAppear to provide a friendly first-run / TestFlight QA state
    /// when the engine repository hasn't wired in yet. Encapsulated as
    /// a method so callers don't poke the `private(set)` `entries`
    /// directly — preserves the invariant that all writes go through
    /// the store.
    func seedWithMockIfEmpty() {
        // W73: the user explicitly asked to remove fake "Mario Rossi"
        // history entries — empty state stays empty until the engine
        // wires real CallHistoryRepository -> server pull. The
        // `mockData` array below is kept (zero refs) for SwiftUI
        // previews only; it will be deleted once the engine repo lands.
        _ = Self.deletedIds  // silence unused warning during rollout
    }

    /// W68: tombstone set persisted to UserDefaults così le deletions
    /// sopravvivono ai riavvi. La engine repository non esiste ancora
    /// iOS-side, quindi facciamo persistence App-layer: ogni `deleteEntry`
    /// aggiunge l'ID al set, e `refresh(from:)` filtra gli ID nel set.
    private static let tombstoneKey = "com.qaudion.callHistory.deletedIds"

    private static var deletedIds: Set<String> {
        get {
            (UserDefaults.standard.array(forKey: tombstoneKey) as? [String])
                .map { Set($0) } ?? []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: tombstoneKey)
        }
    }

    /// Delete a single entry from the history. W68 wiring (App-layer):
    /// l'ID viene aggiunto al tombstone set in UserDefaults così
    /// `refresh(from:)` lo filtra al prossimo reload (anche post-restart).
    /// Engine repository wiring pending — quando lands, sostituire con
    /// `repository.delete(entryId:)` e ritirare il tombstone set.
    func deleteEntry(_ entryId: String) {
        entries.removeAll { $0.id == entryId }
        var t = Self.deletedIds
        t.insert(entryId)
        Self.deletedIds = t
    }

    /// Wipe the entire call history. W68 persistence: aggiunge TUTTI
    /// gli ID correnti al tombstone set + `appState.recentCalls`-derived
    /// stub IDs (così il refresh non li ri-popola).
    func clearAll() {
        var t = Self.deletedIds
        for entry in entries {
            t.insert(entry.id)
        }
        // Anche eventuali stub IDs futuri da recentCalls (il pattern è
        // "stub-<idx>-<userId>"), così il filter regge anche al prossimo
        // refresh che ricostruisce da appState.recentCalls.
        Self.deletedIds = t
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

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    @State private var showingDialPad = false
    @State private var showingGroupComposer = false
    @State private var showingClearAllConfirm = false

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
        .navigationBarHidden(true)
        .onAppear {
            store.refresh(from: appState)
            // Pre-popola con mock se nessuna recentCalls esiste — UX
            // ergonomica per nuovi utenti / TestFlight QA. La logica
            // sta dentro lo store (rispetta `private(set) entries`).
            store.seedWithMockIfEmpty()
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
                Task { await appState.dialAndCall(rawInput: dialed, video: false) }
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
                if let sync = TrackBSyncService.from(appState) {
                    Task { await sync.deleteAllCallHistory() }
                }
            }
        } message: {
            Text("Verranno rimosse \(store.entries.count) chiamate dallo storico locale. L'azione non si può annullare.")
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
                        if let sync = TrackBSyncService.from(appState) {
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
        .refreshable { store.refresh(from: appState) }
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            QAudionAvatar(displayName: entry.peerDisplay,
                          imageURL: nil,
                          size: 48)

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
        if let ext = entry.peerExtension {
            parts.append("Int. \(ext)")
        }
        parts.append(timestampLabel)
        if let dur = entry.durationSeconds {
            parts.append(String(format: "%d:%02d", dur / 60, dur % 60))
        } else if entry.direction == .missed {
            parts.append("persa")
        }
        return parts.joined(separator: " · ")
    }

    private var timestampLabel: String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        if cal.isDateInToday(entry.startedAt) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(entry.startedAt) {
            return "Ieri"
        } else if let days = cal.dateComponents([.day], from: entry.startedAt, to: Date()).day,
                  days < 7 {
            f.dateFormat = "EEE HH:mm"
        } else {
            f.dateFormat = "dd/MM HH:mm"
        }
        return f.string(from: entry.startedAt)
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
        [.symbol("*"),       .digit("0", "+"),   .symbol("#")],
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
