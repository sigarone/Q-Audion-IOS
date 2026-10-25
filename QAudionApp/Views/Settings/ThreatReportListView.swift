import SwiftUI
import QAudionEngine

/// W16.B: real list view of historic threat reports submitted by the user.
///
/// Replaces the `ThreatReportPlaceholderView` that was wired in
/// `SecurityDashboardScreen.swift`. Reads from `ThreatReportLogStore`
/// (App-layer UserDefaults-backed) so the user can revisit every past
/// report even though the server doesn't yet expose a history GET.
///
/// Each row shows: category icon + severity color, snake_case kind,
/// short detail preview, relative time. Tapping a row pushes a
/// detail screen with the full payload + a delete action. A toolbar
/// "+" button presents the existing `ThreatReportContainerView` to
/// file a new report; once that returns success, the new entry shows
/// up at the top automatically (the store gets a fresh entry from
/// `ThreatReportContainer.submit`).
struct ThreatReportListView: View {
    let appState: AppState

    @StateObject private var model: ThreatReportListModel
    @State private var showingNewReport = false

    init(appState: AppState) {
        self.appState = appState
        _model = StateObject(wrappedValue: ThreatReportListModel())
    }

    var body: some View {
        Group {
            if model.entries.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(model.entries) { entry in
                            NavigationLink(destination: ThreatReportDetailView(entry: entry,
                                                                                onDelete: {
                                model.remove(id: entry.id)
                            })) {
                                row(entry)
                            }
                        }
                        .onDelete { indices in
                            // Resolve ids BEFORE issuing any remove. Each
                            // remove() refreshes model.entries, which would
                            // shift indices and risk out-of-bounds reads
                            // when SwiftUI's IndexSet contains more than
                            // one row.
                            let ids = indices.compactMap { idx -> UUID? in
                                guard idx < model.entries.count else { return nil }
                                return model.entries[idx].id
                            }
                            for id in ids {
                                model.remove(id: id)
                            }
                        }
                    } footer: {
                        Text("Le segnalazioni vengono salvate localmente e inviate al server. La lista qui sopra è la tua cronologia locale; le righe più vecchie del limite vengono rimosse automaticamente.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Minacce attive")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewReport = true
                } label: {
                    Label("Nuova segnalazione", systemImage: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showingNewReport, onDismiss: {
            // Refresh after the sheet closes — submit() in
            // ThreatReportContainer appends to the log on success.
            model.refresh()
        }) {
            NavigationStack {
                ThreatReportContainerView(
                    container: ThreatReportContainer(appState: appState),
                    onDismiss: { showingNewReport = false }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla") { showingNewReport = false }
                    }
                }
            }
        }
        .onAppear { model.refresh() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // W63: traduzione IT + allineamento al pattern empty-state CTA
        // di W61/W62. Il bottone "Nuovo report" usa lo stesso state
        // `showingNewReport` del bottone "+" in toolbar (single source
        // of truth). Native SwiftUI .borderedProminent style preserved
        // per consistenza con il toolbar-button parent (questa view è
        // dentro un List + Form context, non Q-Audion design system).
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Nessuna segnalazione")
                .font(.title3.weight(.semibold))
            Text("Apri una nuova segnalazione dal pulsante in alto se rilevi un deepfake, una mismatch vocale, un'alterazione di chiavi o un comportamento sospetto.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showingNewReport = true
            } label: {
                Label("Nuova segnalazione", systemImage: "plus.circle.fill")
                    .padding(.vertical, 4)
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    private func row(_ entry: ThreatReportLogStore.Entry) -> some View {
        HStack(spacing: 12) {
            severityIcon(for: entry.severity)
                .font(.title3)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(humanCategory(entry.category))
                    .font(.body.weight(.medium))
                Text(entry.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(entry.submittedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func severityIcon(for severity: String) -> some View {
        switch severity {
        case "critical":
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        case "high":
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case "medium":
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.yellow)
        case "low":
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
        default:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    /// Convert snake_case category back to a user-readable label.
    /// Mirrors the strings displayed by `ThreatReportView`'s picker.
    private func humanCategory(_ raw: String) -> String {
        switch raw {
        case "deepfake_detected":
            return String(localized: "security.threat_category.deepfake", defaultValue: "Deepfake rilevato", comment: "Threat report category: a deepfake (synthetic voice or video) was detected")
        case "voice_mismatch":
            return String(localized: "security.threat_category.voice_mismatch", defaultValue: "Voce non corrispondente", comment: "Threat report category: the voice did not match the saved voice of the contact")
        case "key_tampering":
            return String(localized: "security.threat_category.key_tampering", defaultValue: "Manomissione chiavi", comment: "Threat report category: signs that encryption keys were tampered with")
        case "suspicious_network":
            return String(localized: "security.threat_category.suspicious_network", defaultValue: "Rete sospetta", comment: "Threat report category: suspicious network behavior")
        case "panic_wipe_triggered":
            return String(localized: "security.threat_category.panic_wipe", defaultValue: "Wipe di emergenza attivato", comment: "Threat report category: the emergency wipe (erasing all data) was triggered")
        case "other":
            return String(localized: "Altro")
        default:
            // Forward-compat: capitalise unknown raw values so future
            // server-side categories still render readably.
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Human-readable severity label. Shared by list icon tooltip (via
/// accessibility) and the detail screen's plain-text row — the raw
/// `entry.severity` string stays untranslated for icon-switch matching.
private func humanSeverity(_ raw: String) -> String {
    switch raw {
    case "critical": return String(localized: "security.severity.critical", defaultValue: "Critica", comment: "Threat report severity (feminine, agrees with 'gravity'): critical")
    case "high": return String(localized: "security.severity.high", defaultValue: "Alta", comment: "Threat report severity (feminine, agrees with 'gravity'): high")
    case "medium": return String(localized: "security.severity.medium", defaultValue: "Media", comment: "Threat report severity (feminine, agrees with 'gravity'): medium")
    case "low": return String(localized: "security.severity.low", defaultValue: "Bassa", comment: "Threat report severity (feminine, agrees with 'gravity'): low")
    default: return raw.capitalized
    }
}

// MARK: - Detail view

/// Read-only detail of a single past report + a destructive delete action.
private struct ThreatReportDetailView: View {
    let entry: ThreatReportLogStore.Entry
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirm = false

    var body: some View {
        Form {
            Section("Categoria") {
                LabeledContent("Tipo") {
                    Text(entry.category)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Gravità") {
                    Text(humanSeverity(entry.severity))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Section("Inviata") {
                LabeledContent("Quando") {
                    Text(entry.submittedAt, style: .date)
                    + Text(" · ")
                    + Text(entry.submittedAt, style: .time)
                }
                if let sid = entry.sessionId {
                    LabeledContent("Sessione") {
                        Text(sid)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Dettagli") {
                Text(entry.details)
                    .font(.body)
                    .textSelection(.enabled)
            }
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Elimina questa voce", systemImage: "trash")
                }
            } footer: {
                Text("Rimuove la riga solo dalla tua cronologia locale. La segnalazione lato server resta intatta.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Rapporto minacce")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Eliminare questa segnalazione dalla cronologia?", isPresented: $showingDeleteConfirm) {
            Button("Annulla", role: .cancel) { }
            Button("Elimina", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("Non notificherà il server. Usa Impostazioni → Sicurezza per una richiesta di wipe se serve.")
        }
    }
}

// MARK: - Container model

@MainActor
private final class ThreatReportListModel: ObservableObject {
    @Published private(set) var entries: [ThreatReportLogStore.Entry] = []
    private let store = ThreatReportLogStore()

    init() { refresh() }

    func refresh() {
        entries = store.load()
    }

    func remove(id: UUID) {
        store.remove(id: id)
        refresh()
    }
}
