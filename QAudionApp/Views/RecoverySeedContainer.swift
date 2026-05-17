import SwiftUI
import QAudionEngine

@MainActor
final class RecoverySeedContainer: ObservableObject {

    enum Mode: Equatable {
        case setup       // user enrolls a NEW mnemonic
        case verify      // user enters a known mnemonic to recover account
    }

    @Published var viewModel: RecoverySeedViewModel
    @Published var errorMessage: String?

    let mode: Mode
    private let appState: AppState
    /// Closures are value types (not class-bound) so `weak` doesn't apply.
    /// We accept the strong-retain — if the host view goes away, the closure
    /// just won't fire (caller responsibility).
    private var hostingDismisser: (() -> Void)?

    init(mode: Mode, appState: AppState, onDismiss: (() -> Void)? = nil) {
        self.mode = mode
        self.appState = appState
        self.hostingDismisser = onDismiss
        switch mode {
        case .setup:
            self.viewModel = RecoverySeedViewModel(
                mnemonicWords: RecoveryMnemonic.generate(),
                userTypedWords: [],
                step: .setupShowMnemonic
            )
        case .verify:
            self.viewModel = RecoverySeedViewModel(
                mnemonicWords: [],
                userTypedWords: [],
                step: .verifyEnterMnemonic
            )
        }
    }

    // MARK: - Backend helper

    /// Build a provider from the currently-stored token, matching the pattern
    /// used in AppState.sendMessage. Returns nil if no token is available.
    private func makeProvider() -> BCryptoBackendProvider? {
        guard let token = appState.authService.loadToken() else { return nil }
        let config = BackendConfig.pinned(serverUrl: appState.serverUrl, accessToken: token)
        return BCryptoBackendProvider(config: config)
    }

    // MARK: - Actions

    /// Called when user confirms the displayed mnemonic during setup.
    /// Computes the recovery hash and submits to AccountApi.recoverySetup.
    func confirmSetup() {
        Task {
            do {
                let hash = try RecoveryMnemonic.canonicalHash(words: viewModel.mnemonicWords)
                guard let provider = makeProvider() else {
                    throw RecoverySeedContainerError.notAuthenticated
                }
                _ = try await provider.accountApi.recoverySetup(recoveryHash: hash)
                viewModel.transition(to: .complete)
            } catch {
                errorMessage = error.localizedDescription
                viewModel.transition(to: .error(message: error.localizedDescription))
            }
        }
    }

    /// Called when user types a mnemonic during recovery (.verify mode).
    /// Validates wordlist + submits to AccountApi.recoveryVerify.
    func verifyMnemonic(words: [String], identifier: String, deviceName: String) {
        Task {
            do {
                try RecoveryMnemonic.validate(words: words)
                let hash = try RecoveryMnemonic.canonicalHash(words: words)
                guard let provider = makeProvider() else {
                    throw RecoverySeedContainerError.notAuthenticated
                }
                _ = try await provider.accountApi.recoveryVerify(
                    identifier: identifier,
                    recoverySecret: hash,
                    deviceName: deviceName
                )
                viewModel.transition(to: .complete)
            } catch {
                errorMessage = error.localizedDescription
                viewModel.transition(to: .error(message: error.localizedDescription))
            }
        }
    }

    func dismiss() {
        hostingDismisser?()
    }
}

// MARK: - Errors

enum RecoverySeedContainerError: LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "No active session — please log in first."
        }
    }
}

// MARK: - View

struct RecoverySeedContainerView: View {
    @ObservedObject var container: RecoverySeedContainer
    @State private var identifier: String = ""
    @State private var deviceName: String = UIDevice.current.name

    var body: some View {
        VStack {
            // In .verify mode, show identifier + device-name fields above the seed view
            // so the user can supply the account identifier (phone number) and device name
            // that recoveryVerify() requires.
            if container.mode == .verify {
                Form {
                    Section("Account") {
                        TextField("Phone number (e.g. +1 555 000 0000)", text: $identifier)
                            .keyboardType(.phonePad)
                        TextField("Device name", text: $deviceName)
                    }
                }
                .frame(maxHeight: 160)
            }

            RecoverySeedView(
                viewModel: container.viewModel,
                onConfirmSetup: { _ in container.confirmSetup() },
                onVerifyMnemonic: { words in
                    container.verifyMnemonic(
                        words: words,
                        identifier: identifier,
                        deviceName: deviceName
                    )
                },
                onDismiss: { container.dismiss() }
            )
        }
    }
}
