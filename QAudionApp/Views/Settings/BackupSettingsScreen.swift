import SwiftUI
import QAudionEngine

// MARK: - Container

@MainActor
final class BackupSettingsContainer: ObservableObject {

    // MARK: Published

    @Published var viewModel: BackupSettingsViewModel

    // Coordinator drives actual encrypt/decrypt work.
    @Published var coordinator: BackupCoordinator

    // Sheet presentation
    @Published var showingBackupPasswordSheet = false
    @Published var showingRestorePasswordSheet = false

    // MARK: Init

    init(appState: AppState) {
        let coordinator = BackupCoordinator(
            conversationStore: ConversationStore(),
            contactsStore: ContactsStore()
        )
        self.coordinator = coordinator
        // Seed ViewModel from any existing backup on disk.
        self.viewModel = BackupSettingsViewModel(
            lastBackupAt: coordinator.lastBackupAt,
            lastBackupSizeBytes: coordinator.lastBackupSizeBytes,
            localEncryptionOnly: true,
            cloudBackupEnabled: false,
            restoreInProgress: false
        )
    }

    // MARK: Actions

    func backupNow(password: String) async {
        do {
            try await coordinator.backupNow(password: password)
            viewModel = BackupSettingsViewModel(
                lastBackupAt: coordinator.lastBackupAt,
                lastBackupSizeBytes: coordinator.lastBackupSizeBytes,
                localEncryptionOnly: true,
                cloudBackupEnabled: false,
                restoreInProgress: false
            )
        } catch {
            coordinator.errorMessage = error.localizedDescription
        }
    }

    func restore(password: String) async {
        do {
            _ = try await coordinator.restore(password: password)
        } catch {
            coordinator.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Password Entry Sheet

private struct PasswordSheet: View {
    let title: String
    let subtitle: String
    let actionLabel: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var confirm = ""
    @FocusState private var focused: Bool

    var isConfirmMode: Bool { actionLabel == "Create Backup" }

    var isValid: Bool {
        if isConfirmMode {
            return password.count >= 6 && password == confirm
        }
        return password.count >= 1
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Password") {
                    SecureField("Enter password", text: $password)
                        .textContentType(.password)
                        .focused($focused)
                    if isConfirmMode {
                        SecureField("Confirm password", text: $confirm)
                            .textContentType(.newPassword)
                    }
                }

                if isConfirmMode && !confirm.isEmpty && password != confirm {
                    Section {
                        Label("Passwords do not match", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionLabel) {
                        onCommit(password)
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - Screen

struct BackupSettingsScreen: View {
    @ObservedObject var container: BackupSettingsContainer

    init(state: AppState) {
        self._container = ObservedObject(wrappedValue: BackupSettingsContainer(appState: state))
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
        ZStack {
            Form {
                // MARK: Info banner (demoted from BLOCKED to informational)
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Local Backups Available", systemImage: "checkmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text("Local encrypted backups are now enabled (QAUD container, scrypt N=2^17 + AES-256-GCM, Android format parity).")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text("Cross-platform interop with Desktop .qabk files is coming via the Migration utility (W13.C). Server upload deferred per audit §3.6.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.green.opacity(0.12))

                // MARK: Last Backup
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
                        Text("Local only (QAUD/AES-256-GCM)")
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Actions
                Section("Backup & Restore") {
                    Button {
                        container.showingBackupPasswordSheet = true
                    } label: {
                        Label("Backup Now", systemImage: "arrow.up.doc.fill")
                    }

                    Button {
                        container.showingRestorePasswordSheet = true
                    } label: {
                        Label("Restore from Backup", systemImage: "arrow.down.doc.fill")
                    }
                    .disabled(!container.coordinator.localBackupExists)
                }

                // MARK: Error feedback
                if let msg = container.coordinator.errorMessage {
                    Section {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }

            // MARK: Processing overlay
            if container.coordinator.isProcessing {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Processing…")
                        .font(.callout)
                        .foregroundStyle(.white)
                }
                .padding(32)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Backup cifrato")
        // MARK: Backup password sheet
        .sheet(isPresented: $container.showingBackupPasswordSheet) {
            PasswordSheet(
                title: "Backup Now",
                subtitle: "Create a password to protect your backup. You will need it to restore.",
                actionLabel: "Create Backup",
                onCommit: { pwd in
                    container.showingBackupPasswordSheet = false
                    container.coordinator.errorMessage = nil
                    Task { await container.backupNow(password: pwd) }
                },
                onCancel: {
                    container.showingBackupPasswordSheet = false
                }
            )
        }
        // MARK: Restore password sheet
        .sheet(isPresented: $container.showingRestorePasswordSheet) {
            PasswordSheet(
                title: "Restore Backup",
                subtitle: "Enter the password you used when creating the backup.",
                actionLabel: "Restore",
                onCommit: { pwd in
                    container.showingRestorePasswordSheet = false
                    container.coordinator.errorMessage = nil
                    Task { await container.restore(password: pwd) }
                },
                onCancel: {
                    container.showingRestorePasswordSheet = false
                }
            )
        }
    }
}
