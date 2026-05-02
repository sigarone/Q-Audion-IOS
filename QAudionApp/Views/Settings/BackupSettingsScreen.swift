import SwiftUI
import QAudionEngine

// MARK: - Container

@MainActor
final class BackupSettingsContainer: ObservableObject {

    @Published var viewModel: BackupSettingsViewModel
    @Published var coordinator: BackupCoordinator
    @Published var showingBackupPasswordSheet = false
    @Published var showingRestorePasswordSheet = false

    init(appState: AppState) {
        let coordinator = BackupCoordinator(
            conversationStore: ConversationStore(),
            contactsStore: ContactsStore()
        )
        self.coordinator = coordinator
        self.viewModel = BackupSettingsViewModel(
            lastBackupAt: coordinator.lastBackupAt,
            lastBackupSizeBytes: coordinator.lastBackupSizeBytes,
            localEncryptionOnly: true,
            cloudBackupEnabled: false,
            restoreInProgress: false
        )
    }

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
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let title: String
    let subtitle: String
    let actionLabel: String
    let isConfirmMode: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var confirm = ""
    @FocusState private var focused: Bool

    var isValid: Bool {
        if isConfirmMode {
            return password.count >= 6 && password == confirm
        }
        return !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                scheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(subtitle)
                            .qaudionStyle(type.bodyMedium)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.top, 16)

                        secureField(label: "Password",
                                    text: $password,
                                    contentType: .password)
                            .focused($focused)
                        if isConfirmMode {
                            secureField(label: "Conferma password",
                                        text: $confirm,
                                        contentType: .newPassword)
                            if !confirm.isEmpty && password != confirm {
                                Label("Le password non coincidono",
                                      systemImage: "xmark.circle.fill")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(extras.riskHigh)
                            } else if password.count > 0 && password.count < 6 {
                                Label("Almeno 6 caratteri",
                                      systemImage: "info.circle")
                                    .qaudionStyle(type.labelSmall)
                                    .foregroundStyle(extras.warning)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionLabel) { onCommit(password) }
                        .disabled(!isValid)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func secureField(label: String,
                             text: Binding<String>,
                             contentType: UITextContentType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)
            SecureField("", text: text)
                .textContentType(contentType)
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(scheme.primary)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(scheme.surfaceVariant.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
                )
        }
    }
}

// MARK: - Screen

/// Backup settings sub-screen. W31 design-token refactor.
struct BackupSettingsScreen: View {
    @ObservedObject var container: BackupSettingsContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    init(state: AppState) {
        self._container = ObservedObject(wrappedValue: BackupSettingsContainer(appState: state))
    }

    private var lastBackupText: String {
        guard let date = container.viewModel.lastBackupAt else { return "Mai" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
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
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    infoBanner

                    SettingsSectionHeader("ULTIMO BACKUP")
                    VStack(spacing: 8) {
                        kvRow(label: "Data", value: lastBackupText, mono: false)
                        kvRow(label: "Dimensione", value: lastBackupSizeText, mono: true)
                        // W308: 'Cifratura' becomes tap-to-copy. The
                        // algorithm string is the most-pasted value in
                        // security questions / audit responses.
                        tapCopyRow(label: "Cifratura",
                                   value: "Locale (QAUD/AES-256-GCM)")
                        // W306: estimate of current data that WOULD
                        // go into the next backup. Walks UserDefaults
                        // for the conversation/message keys and sums
                        // their byte sizes. Cheap (no I/O), gives
                        // testers a sense of 'will this fit'.
                        kvRow(label: "Backup stimato",
                              value: Self.estimatedBackupSizeLabel(),
                              mono: true)
                    }

                    SettingsSectionHeader("AZIONI")
                    VStack(spacing: 8) {
                        actionButton(icon: "arrow.up.doc.fill",
                                     title: "Backup adesso",
                                     subtitle: "Cifra il backup locale con la tua password",
                                     tint: scheme.primary,
                                     enabled: !container.coordinator.isProcessing) {
                            container.showingBackupPasswordSheet = true
                        }
                        actionButton(icon: "arrow.down.doc.fill",
                                     title: "Ripristina da backup",
                                     subtitle: container.coordinator.localBackupExists
                                        ? "Decifra l'ultimo backup locale"
                                        : "Nessun backup disponibile",
                                     tint: scheme.primary,
                                     enabled: container.coordinator.localBackupExists
                                            && !container.coordinator.isProcessing) {
                            container.showingRestorePasswordSheet = true
                        }
                    }

                    if let msg = container.coordinator.errorMessage {
                        errorBanner(msg).padding(.top, 16)
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }

            if container.coordinator.isProcessing {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Elaborazione…")
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(.white)
                }
                .padding(32)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Backup cifrato")
        .sheet(isPresented: $container.showingBackupPasswordSheet) {
            PasswordSheet(
                title: "Backup adesso",
                subtitle: "Crea una password per proteggere il backup. Ti servirà per ripristinarlo.",
                actionLabel: "Crea backup",
                isConfirmMode: true,
                onCommit: { pwd in
                    container.showingBackupPasswordSheet = false
                    container.coordinator.errorMessage = nil
                    Task {
                        await container.backupNow(password: pwd)
                        // Push feedback dopo il completamento (success
                        // se errorMessage è nil, altrimenti il banner
                        // riskHigh esistente fa il proprio lavoro).
                        if container.coordinator.errorMessage == nil {
                            snackbar?.show(.init(
                                text: "Backup cifrato completato.",
                                severity: .info))
                        }
                    }
                },
                onCancel: { container.showingBackupPasswordSheet = false }
            )
        }
        .sheet(isPresented: $container.showingRestorePasswordSheet) {
            PasswordSheet(
                title: "Ripristina backup",
                subtitle: "Inserisci la password che hai usato per creare il backup.",
                actionLabel: "Ripristina",
                isConfirmMode: false,
                onCommit: { pwd in
                    container.showingRestorePasswordSheet = false
                    container.coordinator.errorMessage = nil
                    Task {
                        await container.restore(password: pwd)
                        if container.coordinator.errorMessage == nil {
                            snackbar?.show(.init(
                                text: "Backup ripristinato.",
                                severity: .info))
                        }
                    }
                },
                onCancel: { container.showingRestorePasswordSheet = false }
            )
        }
    }

    // MARK: - Info banner

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(extras.success)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Backup locale attivo")
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(extras.success)
                Text("Container QAUD · scrypt N=2¹⁷ + AES-256-GCM. Parità formato con Android.")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurface)
                Text("Interop cross-platform con Desktop .qabk via utility Migration. Upload server differito.")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.success.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(extras.success.opacity(0.45), lineWidth: 1)
        )
        .padding(.top, 8)
    }

    // MARK: - Rows + helpers

    /// W308: tap-to-copy variant of kvRow. Mirror of the AboutSettings
    /// + AccountSettings helpers from W297/W307 — same visual +
    /// interaction. Useful for the Cifratura algo string which is
    /// the most-pasted value in security audit questions.
    private func tapCopyRow(label: String, value: String) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            #if canImport(UIKit)
            UIPasteboard.general.string = value
            HapticFeedback.messageSent()
            #endif
        }
    }

    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededB(mono: mono))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func actionButton(icon: String,
                              title: String,
                              subtitle: String,
                              tint: Color,
                              enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurface)
                    Text(subtitle)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
            .opacity(enabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.riskHigh)
                .padding(.top, 1)
            Text(msg)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }

    /// W306: estimate the byte size of the local conversation +
    /// message + draft data that would be included in a backup.
    /// Walks UserDefaults for the relevant keys and sums their
    /// stored payload sizes. Returns a ByteCountFormatter-formatted
    /// label like '127 KB' or '4,2 MB'. Cheap — single pass over
    /// the user defaults dictionary.
    private static func estimatedBackupSizeLabel() -> String {
        let store = UserDefaults.standard
        let allKeys = store.dictionaryRepresentation().keys
        var totalBytes: Int64 = 0
        // Conversation list
        if let data = store.data(forKey: "qaudion.conv.list") {
            totalBytes += Int64(data.count)
        }
        // Per-conversation message blobs (qaudion.conv.msgs.<convId>)
        let msgPrefix = "qaudion.conv.msgs."
        for k in allKeys where k.hasPrefix(msgPrefix) {
            if let data = store.data(forKey: k) {
                totalBytes += Int64(data.count)
            }
        }
        // Composer drafts (qaudion.composer.draft.<convId>)
        let draftPrefix = "qaudion.composer.draft."
        for k in allKeys where k.hasPrefix(draftPrefix) {
            if let s = store.string(forKey: k) {
                totalBytes += Int64(s.utf8.count)
            }
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: totalBytes)
    }
}

private struct MonoIfNeededB: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
