import SwiftUI
import QAudionEngine

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    /// Tracks whether the SplashScreen has resolved. Mirrors Android's
    /// `SplashViewModel.state: Loading | GoHome | GoOnboarding`.
    @State private var splashResolved: Bool = false

    /// W34: Global snackbar host. Available to any descendant view via
    /// `@Environment(\.qaudionSnackbar)`. Callers push messages via
    /// `host.show(QAudionSnackbarMessage(...))`. Auto-dismisses after the
    /// configured duration, or on tap of the trailing close icon /
    /// action label. Renders as the topmost overlay so it floats above
    /// every screen + every sheet inside the same NavigationStack.
    @StateObject private var snackbarHost = QAudionSnackbarHostState()

    var body: some View {
        ZStack(alignment: .top) {
            mainStack
            QAudionSnackbarHost(state: snackbarHost)
        }
        // W18.A: apply the Q-Audion design system at the very top so
        // every descendant view can read tokens via @Environment without
        // each having to re-apply the modifier.
        .qAudionTheme(dark: true)
        .environment(\.qaudionSnackbar, snackbarHost)
        .animation(.easeInOut, value: appState.isAuthenticated)
        .animation(.easeInOut, value: appState.isInCall)
        .animation(.easeInOut, value: appState.isVideoCall)
        .animation(.easeInOut, value: splashResolved)
        // W37: bridge globale del deepfake detector. Quando AppState
        // alza il flag (DeepfakeMonitor → confidenceLevel == "red"
        // sustained), pushiamo una snackbar error visibile su qualsiasi
        // schermo. Il pattern Android è "color-only inline durante la
        // chiamata" — ma l'iOS ha l'esigenza extra di notificare anche
        // se l'utente ha messo l'app in background o aperto un altro
        // tab. La snackbar svanisce dopo 6s; il detector continua a
        // pulsare l'avatar halo via confidenceColor in parallelo.
        .onChange(of: appState.deepfakeAlert) { isAlert in
            guard isAlert else { return }
            // Mostra l'opzione "Termina chiamata" solo se siamo
            // effettivamente in chiamata; altrimenti il bottone non
            // avrebbe senso.
            let inCall = appState.isInCall
            snackbarHost.show(.init(
                text: "Voce sospetta rilevata. Controlla l'identità del peer.",
                severity: .error,
                actionLabel: inCall ? "Termina chiamata" : nil,
                onAction: inCall ? { appState.endCall() } : nil,
                durationSeconds: 6
            ))
        }
    }

    @ViewBuilder
    private var mainStack: some View {
        if appState.isInCall && appState.isVideoCall {
            VideoCallView()
        } else if appState.isInCall {
            CallView()
        } else if !splashResolved {
            // W18.C: brand splash on cold start. Resolves itself
            // after the 400ms minimum window and toggles
            // `splashResolved` so the conditional below picks the
            // right destination (HomeView if a session is already
            // alive, else OnboardingRoot).
            SplashScreen(
                onGoHome:       { splashResolved = true },
                onGoOnboarding: { splashResolved = true }
            )
        } else if appState.isAuthenticated {
            HomeView()
        } else {
            // Wave 17: replaced the old `LoginView` (which exposed a
            // free-text Server URL with the placeholder
            // `bcrypto.example.com` and a generic username/password
            // form) with `OnboardingRoot` — a 1:1 visual + behavioural
            // port of the Android canonical Welcome → FastSetup flow
            // (`qaudion-android-new/feature/feature-auth/`). The
            // server URL is now pinned to `PinnedServerHost.url`
            // (`https://voip.bcrypto.com`) so a malicious or stale
            // QR cannot redirect the phone to a different origin.
            OnboardingRoot()
        }
    }
}
