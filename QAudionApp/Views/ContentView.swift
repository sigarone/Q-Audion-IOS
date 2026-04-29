import SwiftUI
import QAudionEngine

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    /// Tracks whether the SplashScreen has resolved. Mirrors Android's
    /// `SplashViewModel.state: Loading | GoHome | GoOnboarding`.
    @State private var splashResolved: Bool = false

    var body: some View {
        Group {
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
        // W18.A: apply the Q-Audion design system at the very top so
        // every descendant view can read tokens via @Environment without
        // each having to re-apply the modifier.
        .qAudionTheme(dark: true)
        .animation(.easeInOut, value: appState.isAuthenticated)
        .animation(.easeInOut, value: appState.isInCall)
        .animation(.easeInOut, value: appState.isVideoCall)
        .animation(.easeInOut, value: splashResolved)
    }
}
