import SwiftUI

/// Top-level onboarding navigator. Replaces the old `LoginView` /
/// `RegisterView` duo as the entry point when the user is not yet
/// authenticated.
///
/// Flow (2026-07-29 — SMS-OTP + extension-only registration + recovery
/// wired end-to-end; previously the phone-entry CTAs dead-ended at a
/// hardcoded "backend not ready" placeholder):
///   - lands on `WelcomeScreen` (Q-Audion brand, 5 CTAs)
///   - "Configurazione rapida (QR)" → `FastSetupOnboardingScreen` (the
///     original, still-working QR-provisioning path)
///   - "Inizia con un codice invito" → `PhoneEntryScreen(mode: .register)`
///     → `OtpVerificationScreen` (SMS code) → `ProfileSetupScreen`
///     (optional display name) → mandatory recovery-phrase reveal
///     (`RecoverySeedContainerView(mode: .setup)`)
///   - "Accedi con un account esistente" → `PhoneEntryScreen(mode: .login)`
///     → `OtpVerificationScreen` → session activates immediately (no
///     profile setup / recovery reveal — those only apply to a brand-new
///     account)
///   - "Registrati senza numero (solo interno + email)" →
///     `ExtensionOnlyRegisterScreen` → mandatory recovery-phrase reveal
///     (display name + email are collected on that screen already, so no
///     separate profile-setup step)
///   - "Ho già una frase di recupero" → `RecoverySeedContainerView(mode: .verify)`
///     — restores an existing account's session on a fresh install
///
/// Once `appState.isAuthenticated` flips true, the parent `ContentView`
/// unmounts this view and routes to `HomeView`. For the register paths,
/// that flip is DEFERRED until the recovery-reveal step's "Done" is
/// tapped — see `AppState.completeOtpAuth` / `activatePendingSession`.
struct OnboardingRoot: View {
    @EnvironmentObject var appState: AppState
    @State private var route: Route = .welcome
    /// W459 — holds the QR text pre-decoded on WelcomeScreen (gallery path).
    /// Forwarded to FastSetupOnboardingScreen via `initialQrText` so
    /// payload validation happens in a single shared code path.
    @State private var fastSetupInitialQrText: String = ""
    /// Backing store for the recovery reveal/restore screens. Held here
    /// (rather than constructed inline in the route switch) so it survives
    /// re-renders of this view while the user is mid-flow — recreating it
    /// on every body evaluation would reset the mnemonic / typed words.
    /// Reused for both `.recoveryReveal` and `.recoveryRestore` since the
    /// two routes are mutually exclusive.
    @State private var recoveryContainer: RecoverySeedContainer?

    private enum Route: Equatable {
        case welcome
        case fastSetup
        case phoneEntry(PhoneEntryScreen.Mode)
        case otpVerification(e164: String, mode: PhoneEntryScreen.Mode, inviteCode: String?)
        case profileSetup
        case extensionOnlyRegister
        case extensionLogin
        case recoveryReveal
        case recoveryRestore
    }

    var body: some View {
        Group {
            switch route {
            case .welcome:
                WelcomeScreen(
                    onStartFastSetup: { route = .fastSetup },
                    onStartRegister: { route = .phoneEntry(.register) },
                    onStartLogin: { route = .phoneEntry(.login) },
                    onStartExtensionLogin: { route = .extensionLogin },
                    onStartExtensionOnlyRegister: { route = .extensionOnlyRegister },
                    onStartRecoveryRestore: { startRecoveryRestore() },
                    // W459: pre-decode QR on WelcomeScreen itself, then
                    // jump straight to FastSetup carrying the raw text so
                    // payload validation + login happen in one shared path.
                    onGalleryQrDecoded: { text in
                        fastSetupInitialQrText = text
                        route = .fastSetup
                    }
                )
            case .fastSetup:
                FastSetupOnboardingScreen(
                    appState: appState,
                    onCancel: {
                        fastSetupInitialQrText = ""
                        route = .welcome
                    },
                    initialQrText: fastSetupInitialQrText
                )
            case .phoneEntry(let mode):
                PhoneEntryScreen(
                    mode: mode,
                    onBack: { route = .welcome },
                    onContinue: { _, e164, inviteCode in
                        route = .otpVerification(e164: e164, mode: mode, inviteCode: inviteCode)
                    }
                )
            case .otpVerification(let e164, let mode, let inviteCode):
                OtpVerificationScreen(
                    appState: appState,
                    e164: e164,
                    mode: mode,
                    inviteCode: inviteCode,
                    onBack: { route = .phoneEntry(mode) },
                    onRegistered: { route = .profileSetup },
                    onLoggedIn: { route = .welcome }  // ContentView switches to HomeView on its own
                )
            case .profileSetup:
                ProfileSetupScreen(
                    appState: appState,
                    onDone: { startRecoveryReveal() }
                )
            case .extensionOnlyRegister:
                ExtensionOnlyRegisterScreen(
                    appState: appState,
                    onBack: { route = .welcome },
                    onRegistered: { startRecoveryReveal() }
                )
            case .extensionLogin:
                ExtensionLoginScreen(
                    appState: appState,
                    onBack: { route = .welcome },
                    onLoggedIn: { route = .welcome }  // ContentView switches to HomeView on its own
                )
            case .recoveryReveal, .recoveryRestore:
                if let container = recoveryContainer {
                    RecoverySeedContainerView(container: container)
                } else {
                    // Defensive fallback — should be unreachable since both
                    // start* helpers always set recoveryContainer before
                    // switching the route to one of these two cases.
                    ProgressView().onAppear { route = .welcome }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Mandatory recovery-phrase reveal at the end of a brand-new
    /// registration (either the SMS-OTP or extension-only path). The
    /// "Done" button on the completion screen — see `onDismiss` below —
    /// is what actually activates the session
    /// (`appState.activatePendingSession()`), which is what makes
    /// `ContentView` switch away from onboarding to `HomeView`. This is
    /// what makes the reveal MANDATORY: the account exists and its
    /// credentials are already saved (`completeOtpAuth` ran before this),
    /// but the app doesn't treat the user as "in" until they've clicked
    /// through the reveal.
    ///
    /// If `recoverySetup` itself errors server-side, the error screen's
    /// "Try again" button uses the SAME `onDismiss` callback (a
    /// pre-existing limitation of the shared `RecoverySeedView` component
    /// — it doesn't distinguish "done" from "give up and leave" for its
    /// caller). Activating the session anyway on that path is a deliberate
    /// choice, not an oversight: the account itself is already fully
    /// created and usable regardless of whether this specific enrollment
    /// step succeeds — recoverySetup is independent, best-effort, and can
    /// be redone later from Settings (same screen). Stranding the user on
    /// an unrecoverable error screen after their account was already
    /// created server-side would be worse than letting them into the app
    /// and retrying enrollment later.
    private func startRecoveryReveal() {
        recoveryContainer = RecoverySeedContainer(
            mode: .setup,
            appState: appState,
            onDismiss: { appState.activatePendingSession() }
        )
        route = .recoveryReveal
    }

    /// "Ho già una frase di recupero" from Welcome — restores an existing
    /// account's session from a previously-enrolled mnemonic on a device
    /// with no prior session (e.g. a fresh install). Unlike
    /// `startRecoveryReveal`, session activation happens INSIDE
    /// `RecoverySeedContainer.verifyMnemonic` itself the moment
    /// `recoveryVerify` succeeds (see that method) — by the time the
    /// user could tap "Done" here, `ContentView` has typically already
    /// switched to `HomeView`. `onDismiss` below only fires in practice
    /// on the error path ("Try again"), where it's correct to just go
    /// back to Welcome without activating anything.
    private func startRecoveryRestore() {
        recoveryContainer = RecoverySeedContainer(
            mode: .verify,
            appState: appState,
            onDismiss: { route = .welcome }
        )
        route = .recoveryRestore
    }
}
