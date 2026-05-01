import SwiftUI
import PhotosUI
import UIKit
import QAudionEngine

@MainActor
final class AccountSettingsContainer: ObservableObject {

    @Published private(set) var viewModel: AccountSettingsViewModel
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var draftDisplayName: String = ""
    @Published var draftStatusMessage: String = ""

    private let appState: AppState
    private let avatarUploader: AvatarUploader

    init(appState: AppState) {
        self.appState = appState
        // W73: start with an EMPTY state, NOT `.mock` (which had the
        // hardcoded "4242" extension that surfaced as the user's own
        // dial number after a fast-setup login). The screen renders a
        // loading skeleton until `loadFromServer()` populates real data.
        self.viewModel = AccountSettingsViewModel(
            userId: appState.currentUserId ?? "",
            phoneHash: "",
            displayName: nil,
            statusMessage: nil,
            avatarUrl: nil,
            dialExtension: nil
        )
        self.draftDisplayName = ""
        self.draftStatusMessage = ""
        self.avatarUploader = AvatarUploader(appState: appState)
    }

    func loadFromServer() {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return
        }
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                let profile = try await provider.accountApi.getProfile()
                await MainActor.run {
                    // W73: take phone_hash + extension from the SERVER
                    // response, not the local placeholder. The
                    // bcrypto-server `/profile` GET handler now returns
                    // both fields (commit `feat(server): expose
                    // extension+phone_hash on /profile`). For legacy
                    // accounts where the server hasn't rolled out yet
                    // these stay nil/0 and the UI shows "—".
                    let extString: String?
                    if let ext = profile.dialExtension, ext > 0 {
                        extString = String(ext)
                    } else {
                        extString = nil
                    }
                    self.viewModel = AccountSettingsViewModel(
                        userId: profile.userId,
                        phoneHash: profile.phoneHash ?? "",
                        displayName: profile.displayName,
                        statusMessage: profile.statusMessage,
                        avatarUrl: profile.avatarUrl.flatMap(URL.init(string:)),
                        dialExtension: extString
                    )
                    self.draftDisplayName = profile.displayName ?? ""
                    self.draftStatusMessage = profile.statusMessage ?? ""
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func saveProfile() {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return
        }
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                try await provider.accountApi.updateProfile(
                    displayName: draftDisplayName.isEmpty ? nil : draftDisplayName,
                    statusMessage: draftStatusMessage.isEmpty ? nil : draftStatusMessage,
                    avatarUrl: nil
                )
                loadFromServer()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Audit P0 #2.12 — GDPR data export
    /// Pulls /api/v1/account/export and presents a system Share sheet
    /// so the user can save the JSON envelope to Files or AirDrop it
    /// to a desktop. Best-effort; errors surface as errorMessage.
    func exportMyData(presenting: UIViewController) {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return
        }
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                let data = try await provider.accountApi.accountExport()
                let ts = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .prefix(15)
                let filename = "qaudion-server-export-\(ts).json"
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(filename)
                try data.write(to: tmp)
                await MainActor.run {
                    let share = UIActivityViewController(
                        activityItems: [tmp],
                        applicationActivities: nil,
                    )
                    presenting.present(share, animated: true)
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Audit P0 #2.12 — GDPR right-to-be-forgotten
    /// Fires DELETE /api/v1/account first, then triggers local logout
    /// via AuthService regardless of server response. The user wants
    /// to be forgotten — a server 5xx must not block the local wipe.
    /// Caller wraps this in a confirmation alert per UX guidelines.
    func deleteAccount() {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return
        }
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                // Best-effort server delete; ignore errors below.
                try? await provider.accountApi.deleteAccount()
                // Local logout — clears the keychain + tokens.
                try await provider.accountApi.logout()
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = nil
                    // Caller (host SwiftUI view) should observe the
                    // auth state and route back to onboarding.
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    /// True when neither draft field differs from the persisted value.
    var isDraftUnchanged: Bool {
        draftDisplayName == (viewModel.displayName ?? "") &&
        draftStatusMessage == (viewModel.statusMessage ?? "")
    }

    func uploadAvatar(image: UIImage) {
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                _ = try await avatarUploader.uploadAndApply(image: image)
                loadFromServer()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func makeProvider() -> BCryptoBackendProvider? {
        guard let token = appState.authService.loadToken(), !token.isEmpty else { return nil }
        let config = BackendConfig(serverUrl: appState.serverUrl, accessToken: token)
        return BCryptoBackendProvider(config: config)
    }
}

/// Account / Profile sub-screen. W31 design-token refactor —
/// migrated from stock Form to the design system. Same bindings:
/// avatar upload via PhotosPicker, draftDisplayName + draftStatusMessage
/// edits, saveProfile() submission, server load on appear.
struct AccountSettingsScreen: View {
    @ObservedObject var container: AccountSettingsContainer
    @State private var selectedItem: PhotosPickerItem?

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    init(appState: AppState) {
        self._container = ObservedObject(
            wrappedValue: AccountSettingsContainer(appState: appState)
        )
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = container.errorMessage {
                        errorBanner(error).padding(.top, 8)
                    }

                    SettingsSectionHeader("FOTO PROFILO")
                    photoSection

                    SettingsSectionHeader("IDENTITÀ")
                    VStack(spacing: 8) {
                        kvRow(label: "User ID",
                              value: container.viewModel.userId,
                              mono: true)
                        kvRow(label: "Phone Hash",
                              value: phoneHashShort,
                              mono: true)
                        if let ext = container.viewModel.dialExtension {
                            kvRow(label: "Interno",
                                  value: ext,
                                  mono: true)
                        }
                    }

                    SettingsSectionHeader("PROFILO")
                    VStack(spacing: 12) {
                        textField(label: "Nome visualizzato",
                                  value: $container.draftDisplayName,
                                  placeholder: "es. Mario Rossi",
                                  capitalization: .words)
                        textField(label: "Stato / nota",
                                  value: $container.draftStatusMessage,
                                  placeholder: "es. Disponibile dalle 9 alle 18",
                                  capitalization: .sentences)
                    }

                    Spacer().frame(height: 16)
                    saveButton
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Profilo")
        .onAppear { container.loadFromServer() }
        .onChange(of: selectedItem) { newItem in
            Task {
                guard let item = newItem,
                      let data = try? await item.loadTransferable(type: Data.self),
                      let img = UIImage(data: data) else { return }
                container.uploadAvatar(image: img)
                selectedItem = nil
            }
        }
    }

    // MARK: - Photo section

    private var photoSection: some View {
        HStack(spacing: 16) {
            avatarImage
            VStack(alignment: .leading, spacing: 4) {
                PhotosPicker(
                    selection: $selectedItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                        Text("Cambia foto")
                            .qaudionStyle(type.labelLarge)
                    }
                    .foregroundStyle(scheme.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(
                        Capsule().stroke(scheme.primary.opacity(0.6), lineWidth: 1)
                    )
                }
                .disabled(container.isLoading)

                if container.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
                            .tint(scheme.onSurfaceVariant)
                        Text("Caricamento…")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 88)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let url = container.viewModel.avatarUrl {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                ProgressView().tint(scheme.onSurfaceVariant)
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(Circle().stroke(scheme.outline.opacity(0.4), lineWidth: 1))
        } else {
            QAudionAvatar(displayName: container.draftDisplayName.isEmpty
                                        ? container.viewModel.userId
                                        : container.draftDisplayName,
                          size: 64)
        }
    }

    // MARK: - Rows / fields

    private var phoneHashShort: String {
        let h = container.viewModel.phoneHash
        guard h.count > 12 else { return h }
        return "\(h.prefix(12))…"
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
                .modifier(MonoIfNeededA(mono: mono))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func textField(label: String,
                           value: Binding<String>,
                           placeholder: String,
                           capitalization: TextInputAutocapitalization) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)

            TextField("", text: value,
                      prompt: Text(placeholder).foregroundColor(scheme.onSurfaceVariant))
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(scheme.primary)
                .textInputAutocapitalization(capitalization)
                .disabled(container.isLoading)
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

    // MARK: - Save button

    private var saveButton: some View {
        Button {
            container.saveProfile()
            // Optimistic feedback. Il container chiama loadFromServer()
            // dopo updateProfile e setta errorMessage in caso di
            // failure. Per ora mostriamo solo il success ottimista
            // e lasciamo il banner riskHigh esistente per gli errori.
            snackbar?.show(.init(
                text: "Profilo aggiornato.",
                severity: .info
            ))
        } label: {
            HStack {
                if container.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(scheme.onPrimary)
                    Text("Salvataggio…")
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.onPrimary)
                } else {
                    Text("Salva")
                        .qaudionStyle(type.labelLarge)
                        .tracking(0.8)
                        .foregroundStyle(scheme.onPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(saveEnabled ? scheme.primary : scheme.surfaceVariant)
            )
            .opacity(saveEnabled ? 1.0 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!saveEnabled)
    }

    private var saveEnabled: Bool {
        !container.isLoading && !container.isDraftUnchanged
    }
}

private struct MonoIfNeededA: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
