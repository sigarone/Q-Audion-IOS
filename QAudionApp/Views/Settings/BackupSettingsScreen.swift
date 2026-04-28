import SwiftUI
import QAudionEngine

@MainActor
final class BackupSettingsContainer: ObservableObject {
    @Published var viewModel: BackupSettingsViewModel
    init(initial: BackupSettingsViewModel = .mock) { self.viewModel = initial }
}

struct BackupSettingsScreen: View {
    @ObservedObject var container: BackupSettingsContainer

    init(state: AppState) {
        let c = BackupSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
    }

    private var lastBackupText: String {
        guard let date = container.viewModel.lastBackupAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var lastBackupSizeText: String {
        guard let bytes = container.viewModel.lastBackupSizeBytes else { return "—" }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    var body: some View {
        Form {
            if !container.viewModel.cloudBackupEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Cloud Backup Unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Cloud backup pending cross-platform .qabk container alignment (Discrepancy §10)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text("Desktop uses QABK magic + 32B salt + scrypt N=2^15; Android uses QAUD + 16B salt + scrypt N=2^17. Upload and download are disabled until all platforms converge on a single container layout.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.yellow.opacity(0.2))
            }

            Section("Last Backup") {
                LabeledContent("Date") {
                    Text(lastBackupText)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Size") {
                    Text(lastBackupSizeText)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Encryption") {
                    Text(container.viewModel.localEncryptionOnly ? "Local only" : "Cloud-synced")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cloud Backup") {
                LabeledContent("Status") {
                    Text(container.viewModel.cloudBackupEnabled ? "Enabled" : "Disabled")
                        .foregroundStyle(container.viewModel.cloudBackupEnabled ? .green : .orange)
                }
                Button("Backup Now") { }
                    .disabled(!container.viewModel.cloudBackupEnabled)
                Button("Restore from Backup") { }
                    .disabled(!container.viewModel.cloudBackupEnabled || container.viewModel.restoreInProgress)
            }
        }
        .navigationTitle("Backup")
    }
}
