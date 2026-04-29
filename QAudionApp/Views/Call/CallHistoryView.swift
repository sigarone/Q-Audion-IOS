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
        entries = out
        loading = false
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
            // ergonomica per nuovi utenti / TestFlight QA.
            if store.entries.isEmpty {
                store.entries = CallHistoryStore.mockData
            }
        }
        .sheet(isPresented: $showingDialPad) {
            DialPadSheet(onCall: { dialed in
                showingDialPad = false
                Task { await appState.startCall(contactId: dialed, video: false) }
            })
        }
        .sheet(isPresented: $showingGroupComposer) {
            GroupComposerPlaceholderSheet()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Chiamate")
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
            Spacer()
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
            Text("Le chiamate effettuate appariranno qui dopo la prima telefonata.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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

// MARK: - DialPad sheet (placeholder)

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

private struct GroupComposerPlaceholderSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 56))
                .foregroundStyle(scheme.primary)
            Text("Nuova chiamata di gruppo")
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
            Text("La creazione di chiamate di gruppo arriverà nella prossima ondata (W40 GroupChat trio).")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Chiudi") { dismiss() }
                .padding(.top, 8)
            Spacer()
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme.background)
    }
}

#Preview {
    CallHistoryView()
        .environmentObject(AppState())
        .qAudionTheme(dark: true)
}
