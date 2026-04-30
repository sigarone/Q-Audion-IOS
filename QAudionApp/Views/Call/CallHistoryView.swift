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
    func refresh(from appState: AppState) {
        loading = true
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
                peerDisplay: userId.hasPrefix("user-")
                    ? String(userId.dropFirst(5)).capitalized
                    : userId,
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

    /// Seed the store with mock entries if empty. Used by the view's
    /// onAppear to provide a friendly first-run / TestFlight QA state
    /// when the engine repository hasn't wired in yet. Encapsulated as
    /// a method so callers don't poke the `private(set)` `entries`
    /// directly — preserves the invariant that all writes go through
    /// the store.
    func seedWithMockIfEmpty() {
        if entries.isEmpty {
            // W68: anche il mock catalog rispetta tombstones così se
            // l'utente ha "Cancella storico" la lista resta vuota anche
            // dopo restart finché non aggiunge nuove chiamate reali.
            let tombstones = Self.deletedIds
            entries = Self.mockData.filter { !tombstones.contains($0.id) }
        }
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
                Task { await appState.startCall(contactId: dialed, video: false) }
            })
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

    private var list: some View {
        List {
            ForEach(store.entries) { entry in
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

/// Sheet "Componi numero" — input libero ID/numero + bottone "Chiama".
/// Functional surface (non placeholder): l'input flusce direttamente in
/// `appState.startCall(contactId:video:)` via il callback `onCall`.
private struct DialPadSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""
    @FocusState private var focused: Bool
    let onCall: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                scheme.background.ignoresSafeArea()
                VStack(spacing: 20) {
                    // Display monospace dell'input corrente o placeholder.
                    Text(input.isEmpty ? "—" : input)
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .foregroundStyle(input.isEmpty ? scheme.onSurfaceVariant : scheme.onSurface)
                        .padding(.top, 24)
                        .frame(minHeight: 60)
                        .animation(.easeInOut(duration: 0.15), value: input.isEmpty)

                    // Input field (tastiera namePhonePad iOS gestisce
                    // direttamente l'inserimento; nessun pad in-app).
                    TextField("inserisci ID o numero",
                              text: $input)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.namePhonePad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .padding(.horizontal, 24)

                    Spacer()

                    Button {
                        let trimmed = input.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        onCall(trimmed)
                    } label: {
                        Text("Chiama")
                            .qaudionStyle(type.labelLarge)
                            .foregroundStyle(scheme.onPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(input.isEmpty
                                          ? scheme.surfaceVariant : scheme.primary)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(input.isEmpty)
                    .padding(.horizontal, 24)
                    Spacer().frame(height: 24)
                }
            }
            .navigationTitle("Componi numero")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
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
