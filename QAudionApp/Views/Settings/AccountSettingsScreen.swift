import SwiftUI
import QAudionEngine

@MainActor
final class AccountSettingsContainer: ObservableObject {

    @Published private(set) var viewModel: AccountSettingsViewModel
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var draftDisplayName: String = ""
    @Published var draftStatusMessage: String = ""

    private let appState: AppState

    init(appState: AppState, initial: AccountSettingsViewModel = .mock) {
        self.appState = appState
        self.viewModel = initial
        self.draftDisplayName = initial.displayName ?? ""
        self.draftStatusMessage = initial.statusMessage ?? ""
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
                    self.viewModel = AccountSettingsViewModel(
                        userId: profile.userId,
                        phoneHash: self.viewModel.phoneHash,
                        displayName: profile.displayName,
                        statusMessage: profile.statusMessage,
                        avatarUrl: profile.avatarUrl.flatMap(URL.init(string:)),
                        dialExtension: self.viewModel.dialExtension
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

    /// True when neither draft field differs from the persisted value.
    var isDraftUnchanged: Bool {
        draftDisplayName == (viewModel.displayName ?? "") &&
        draftStatusMessage == (viewModel.statusMessage ?? "")
    }

    private func makeProvider() -> BCryptoBackendProvider? {
        guard let token = appState.authService.loadToken(), !token.isEmpty else { return nil }
        let config = BackendConfig(serverUrl: appState.serverUrl, accessToken: token)
        return BCryptoBackendProvider(config: config)
    }
}

struct AccountSettingsScreen: View {
    @ObservedObject var container: AccountSettingsContainer

    init(appState: AppState) {
        self._container = ObservedObject(
            wrappedValue: AccountSettingsContainer(appState: appState)
        )
    }

    var body: some View {
        Form {
            // Error banner
            if let error = container.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Identity") {
                LabeledContent("User ID") {
                    Text(container.viewModel.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Phone Hash") {
                    Text(String(container.viewModel.phoneHash.prefix(16)) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let ext = container.viewModel.dialExtension {
                    LabeledContent("Extension") {
                        Text(ext)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Profile") {
                TextField("Display name", text: $container.draftDisplayName)
                    .disabled(container.isLoading)
                TextField("Status message", text: $container.draftStatusMessage)
                    .disabled(container.isLoading)
            }

            Section {
                Button {
                    container.saveProfile()
                } label: {
                    if container.isLoading {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text("Saving…")
                        }
                    } else {
                        Text("Save")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(container.isLoading || container.isDraftUnchanged)
            }
        }
        .navigationTitle("Account")
        .onAppear {
            container.loadFromServer()
        }
    }
}
