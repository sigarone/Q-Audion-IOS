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

    /// Build a provider for the current mode.
    ///
    /// `.setup` (`recoverySetup`) is an AUTHENTICATED endpoint — enrolling
    /// a recovery hash only makes sense for an already-logged-in session,
    /// so this still requires a stored token and returns `nil` without one
    /// (same behaviour as before this fix).
    ///
    /// `.verify` (`recoveryVerify`) is explicitly documented as a
    /// NO-SESSION endpoint (see its kdoc on `AccountApi`: "Re-provision a
    /// device from a recovery secret on a fresh install (no active
    /// session)"). 2026-07-29 fix: this method used to unconditionally
    /// require a token for BOTH modes, which made the "restore from
    /// recovery phrase" flow impossible on the exact scenario it exists
    /// for — a fresh install with no prior session. That bug never
    /// surfaced because `RecoverySeedContainer(mode: .verify, ...)` had
    /// zero call sites anywhere in the shipped app until `OnboardingRoot`
    /// wired one in. Build an unauthenticated provider for `.verify`
    /// instead — `recoveryVerify`'s `identifier` + `recoverySecret`
    /// arguments ARE the credential, no bearer token needed.
    private func makeProvider() -> BCryptoBackendProvider? {
        let token = appState.authService.loadToken()
        if mode == .setup && token == nil { return nil }
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
                // Only inside the success path, never in the catch below —
                // this is the write that answers the "awaiting" record the
                // mandatory onboarding reveal left (this method is shared
                // with it), so a user who did enrol is never nagged later.
                if let uid = appState.currentUserId {
                    RecoveryEnrollmentStatus.markEnrolled(userId: uid)
                }
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
                let creds = try await provider.accountApi.recoveryVerify(
                    identifier: identifier,
                    recoverySecret: hash,
                    deviceName: deviceName
                )
                // 2026-07-29 fix: the returned credentials used to be
                // discarded entirely (`_ = try await ...`) — a successful
                // recovery-verify never actually logged the user in, it
                // just flipped the view to a "Done" screen with no working
                // session behind it. Persist + activate exactly like the
                // password-based login paths do (AppState.login /
                // loginWithPhoneHash) so restoring from a mnemonic on a
                // fresh install actually leaves the user signed in.
                appState.authService.saveCredentials(creds)
                appState.currentUserId = creds.userId  // saveCredentials already persisted it (TokenVault)
                appState.activatePendingSession()
                // Restoring from a mnemonic IS enrolling: the account
                // already proved it holds one, so any "awaiting" record
                // left for it on this device is answered.
                RecoveryEnrollmentStatus.markEnrolled(userId: creds.userId)
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
        // SECURITY H-18: in `.setup` mode this screen displays the recovery
        // mnemonic in clear. Mirror ChatDetailScreen's secure-window lifecycle
        // so it cannot be screenshotted / recorded / AirPlay-mirrored while
        // shown. `.verify` mode (the user TYPES a phrase they already hold)
        // takes no lock, and therefore releases none either.
        .onAppear {
            if container.mode == .setup { ScreenshotLockService.lock() }
        }
        .onDisappear {
            if container.mode == .setup { ScreenshotLockService.unlock() }
        }
    }
}

/// Owns a `.setup` container for as long as the screen that shows it lives.
///
/// `RecoverySeedContainer.init(mode: .setup, ...)` generates a NEW mnemonic.
/// Building the container inline in a view body, a `.sheet` closure or a
/// `LazyView` closure runs that init on every re-evaluation of the parent, and
/// `RecoverySeedContainerView` holds the container as `@ObservedObject`, so it
/// follows the swap: the words on screen change under the user, and the hash
/// sent to the server on confirm can belong to a different phrase than the one
/// they wrote down. `@StateObject` makes SwiftUI run the initializer once per
/// view lifetime (the `wrappedValue` autoclosure is not evaluated again), so
/// the phrase is fixed from the moment the screen appears until it goes away.
/// Presenting the screen again starts a new host, and so a new phrase, which
/// is what a new enrolment wants.
///
/// Every `.setup` entry point that is not the onboarding root (which keeps its
/// container in `@State` for the same reason) goes through this view.
struct RecoverySetupHost: View {
    @StateObject private var container: RecoverySeedContainer

    init(appState: AppState, onDismiss: (() -> Void)? = nil) {
        self._container = StateObject(wrappedValue: RecoverySeedContainer(
            mode: .setup, appState: appState, onDismiss: onDismiss
        ))
    }

    var body: some View {
        RecoverySeedContainerView(container: container)
    }
}
