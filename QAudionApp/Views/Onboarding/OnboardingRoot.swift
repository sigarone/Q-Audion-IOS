import SwiftUI

/// Top-level onboarding navigator. Replaces the old `LoginView` /
/// `RegisterView` duo as the entry point when the user is not yet
/// authenticated.
///
/// Flow:
///   - lands on `WelcomeScreen` (Q-Audion brand, 3 CTAs)
///   - "Configurazione rapida (QR)" → `FastSetupOnboardingScreen` (the
///     primary, working path today)
///   - "Inizia con un codice invito" → `PhoneEntryScreen(mode: .register)`
///     (status banner explains it's behind backend OTP work)
///   - "Accedi con un account esistente" → `PhoneEntryScreen(mode: .login)`
///     (same banner)
///
/// Once `appState.isAuthenticated` flips true (via `FastSetupAuth.run`
/// inside FastSetup), the parent `ContentView` unmounts this view and
/// routes to `HomeView`.
struct OnboardingRoot: View {
    @EnvironmentObject var appState: AppState
    @State private var route: Route = .welcome
    /// W459 — holds the QR text pre-decoded on WelcomeScreen (gallery path).
    /// Forwarded to FastSetupOnboardingScreen via `initialQrText` so
    /// payload validation happens in a single shared code path.
    @State private var fastSetupInitialQrText: String = ""

    private enum Route: Equatable {
        case welcome
        case fastSetup
        case phoneEntry(PhoneEntryScreen.Mode)
        case phoneSubmitted(hash: String, e164: String, mode: PhoneEntryScreen.Mode)
    }

    var body: some View {
        Group {
            switch route {
            case .welcome:
                WelcomeScreen(
                    onStartFastSetup: { route = .fastSetup },
                    onStartRegister: { route = .phoneEntry(.register) },
                    onStartLogin: { route = .phoneEntry(.login) },
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
                    onContinue: { hash, e164 in
                        route = .phoneSubmitted(hash: hash, e164: e164, mode: mode)
                    }
                )
            case .phoneSubmitted(let hash, _, let mode):
                phoneSubmittedPlaceholder(hash: hash, mode: mode)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Until the backend OTP flow lands, the phone-entry CTAs end here.
    /// The screen is informational only — explains the current state and
    /// nudges the user back to Fast Setup. Once the OTP screen is ready,
    /// this branch is replaced with `OtpVerificationScreen(hash, mode)`.
    @ViewBuilder
    private func phoneSubmittedPlaceholder(hash: String,
                                            mode: PhoneEntryScreen.Mode) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "hourglass.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("Verifica numero non ancora attiva")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Hash calcolato: \(hash.prefix(8))…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.5))
                Text("Il backend OTP è in lavorazione. Per ora completa l'onboarding tramite **Configurazione rapida (QR)** dal Welcome.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button {
                    route = .welcome
                } label: {
                    Text("Torna al Welcome")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(.black)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}
