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
                        Text("Threat reports are filed locally and POSTed to the server. The list above is your local history; older rows beyond the cap roll off automatically.")
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
                    Label("File new report", systemImage: "plus.circle.fill")
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
                        Button("Cancel") { showingNewReport = false }
                    }
                }
            }
        }
        .onAppear { model.refresh() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("No threats reported")
                .font(.title3.weight(.semibold))
            Text("File a new report from the toolbar if you spot a deepfake, voice mismatch, key tampering or any suspicious behaviour.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showingNewReport = true
            } label: {
                Label("File new report", systemImage: "plus.circle.fill")
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
        case "deepfake_detected": return "Deepfake detected"
        case "voice_mismatch": return "Voice mismatch"
        case "key_tampering": return "Key tampering"
        case "suspicious_network": return "Suspicious network"
        case "panic_wipe_triggered": return "Panic wipe triggered"
        case "other": return "Other"
        default:
            // Forward-compat: capitalise unknown raw values so future
            // server-side categories still render readably.
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
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
            Section("Category") {
                LabeledContent("Kind") {
                    Text(entry.category)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Severity") {
                    Text(entry.severity)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Section("Submitted") {
                LabeledContent("At") {
                    Text(entry.submittedAt, style: .date)
                    + Text(" · ")
                    + Text(entry.submittedAt, style: .time)
                }
                if let sid = entry.sessionId {
                    LabeledContent("Session") {
                        Text(sid)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Details") {
                Text(entry.details)
                    .font(.body)
                    .textSelection(.enabled)
            }
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete this entry", systemImage: "trash")
                }
            } footer: {
                Text("Removes the row from your local history only. The server-side report stays.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Rapporto minacce")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete this report from history?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("This won't notify the server. Use Settings → Security to file a wipe request if needed.")
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
