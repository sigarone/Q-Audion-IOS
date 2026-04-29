import SwiftUI

/// Splash shown while the app decides whether to route the user to
/// onboarding (no token) or straight to the home shell (token + userId
/// present and verified).
///
/// 1:1 port of `qaudion-android-new/feature/feature-auth/ui/SplashScreen.kt`:
/// centred Q-AUDION wordmark, circular progress, "SECURE COMMS" label.
/// Background uses the design-system `background` token.
///
/// Timing rules (mirrors Android):
///   - Stay visible at least `minSplashMs = 400 ms` so the user perceives
///     the brand frame even on cold start with hot caches.
///   - Resolve to `goHome` if `appState.isAuthenticated && currentUserId`
///     are present after the minimum window.
///   - Resolve to `goOnboarding` otherwise.
///
/// The "decoy / lock" gesture from Android is intentionally NOT ported
/// here yet — it requires a separate `AppLockMode` infrastructure (Phase
/// later wave). Until then, `Splash` always treats the current state as
/// real.
struct SplashScreen: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let onGoHome: () -> Void
    let onGoOnboarding: () -> Void

    /// Minimum on-screen time so the splash isn't a flicker. Matches
    /// Kotlin `MIN_SPLASH_MS = 400`.
    private static let minSplashMs: UInt64 = 400_000_000  // 400 ms in ns

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Q-AUDION")
                    .qaudionStyle(type.headlineLarge)
                    .tracking(2)
                    .foregroundStyle(scheme.onBackground)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(scheme.primary)
                    .controlSize(.regular)

                Text("SECURE COMMS")
                    .qaudionStyle(type.labelSmall)
                    .tracking(3)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
        .task {
            // Sleep at least the minimum splash window, then route.
            try? await Task.sleep(nanoseconds: Self.minSplashMs)
            await MainActor.run {
                if appState.isAuthenticated, appState.currentUserId != nil {
                    onGoHome()
                } else {
                    onGoOnboarding()
                }
            }
        }
    }
}
