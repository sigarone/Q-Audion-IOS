import SwiftUI
import QAudionEngine

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isInCall && appState.isVideoCall {
                VideoCallView()
            } else if appState.isInCall {
                CallView()
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
        .animation(.easeInOut, value: appState.isAuthenticated)
        .animation(.easeInOut, value: appState.isInCall)
        .animation(.easeInOut, value: appState.isVideoCall)
    }
}
