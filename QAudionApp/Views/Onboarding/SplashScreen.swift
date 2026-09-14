import SwiftUI

/// Splash shown while the app decides whether to route the user to
/// onboarding (no token) or straight to the home shell (token + userId
/// present and verified).
///
/// 1:1 port of `qaudion-android-new/feature/feature-auth/ui/SplashScreen.kt`:
/// centred Q-AUDION wordmark, circular progress, "SECURE COMMS" label.
/// Background uses the design-system `background` token.
///
/// W-BRAND parity (2026-08-15): the wordmark is the same shield+"Q-AUDION"
/// PNG Android draws (`qaudion_logo_wordmark.png`, `core-ui` module) — a
/// transparent-background image, not a text label wrapped in a colored box.
/// Drawing it directly on `scheme.background` with nothing behind it is what
/// makes it read as one continuous surface instead of a logo pasted on a
/// card; do not wrap it in any `.background()`/shape or the fusion breaks.
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
            GeometryReader { geo in
                VStack(spacing: 24) {
                    // Matches Android's Modifier.fillMaxWidth(0.72f) +
                    // ContentScale.Fit — 72% of the available width, aspect
                    // preserved. No card, no background fill: the PNG's own
                    // transparency is what fuses it into `scheme.background`.
                    Image("QAudionWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width * 0.72)
                        .accessibilityLabel("Q-Audion")

                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(scheme.primary)
                        .controlSize(.regular)

                    Text("SECURE COMMS")
                        .qaudionStyle(type.labelSmall)
                        .tracking(3)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                .frame(width: geo.size.width, height: geo.size.height)
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
