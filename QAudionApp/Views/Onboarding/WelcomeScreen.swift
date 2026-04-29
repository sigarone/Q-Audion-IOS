import SwiftUI

/// Onboarding landing screen. Visual + copy replica of the Android
/// canonical source `qaudion-android-new/feature/feature-auth/ui/WelcomeScreen.kt`.
///
/// Dark editorial layout:
///   - top meta strap "Q-AUDION · SECURE COMMUNICATIONS"
///   - large headline "Benvenuto a Q-Audion."
///   - subtitle "La voce è la tua chiave."
///   - 3 feature pills (ML-KEM 1024 / Voice-as-Key / Deepfake Guard)
///   - CTA hierarchy:
///       1. **Primary** "Configurazione rapida (QR)" — fast-setup, the
///          zero-friction path the admin panel pushes by default
///       2. **Secondary** "Inizia con un codice invito" — placeholder for
///          a future invite-code flow (NOT YET WIRED — tap shows a
///          "Coming soon" sheet)
///       3. **Text** "Accedi con un account esistente" — placeholder for
///          phone-entry login (NOT YET WIRED)
///   - footer "Hybrid PQC · Voice-first · Deepfake Guard"
///
/// Per user 2026-04-29: only the Primary CTA (Fast Setup) is wired today.
/// The other two are stubs because the server-side register/login flows
/// don't have a phone-OTP path yet — server provisions credentials via
/// the QR.
struct WelcomeScreen: View {

    let onStartFastSetup: () -> Void
    let onStartRegister: () -> Void
    let onStartLogin: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Top meta strap (letter-spaced uppercase label)
                    Text("Q-AUDION · SECURE COMMUNICATIONS")
                        .font(.caption.weight(.medium))
                        .tracking(2.5)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 8)

                    Spacer().frame(height: 56)

                    // Headline
                    Text("Benvenuto a Q-Audion.")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Spacer().frame(height: 12)

                    Text("La voce è la tua chiave.")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.65))

                    Spacer().frame(height: 32)

                    // Feature pills (PQC accent color)
                    HStack(spacing: 8) {
                        FeaturePill(label: "ML-KEM 1024")
                        FeaturePill(label: "Voice-as-Key")
                        FeaturePill(label: "Deepfake Guard")
                    }

                    Spacer().frame(height: 32)

                    // CTAs
                    VStack(spacing: 12) {
                        Button(action: onStartFastSetup) {
                            Text("Configurazione rapida (QR)")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .foregroundStyle(.black)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button(action: onStartRegister) {
                            Text("Inizia con un codice invito")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .foregroundStyle(.white)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(.white.opacity(0.4), lineWidth: 1.2)
                                )
                        }

                        Button(action: onStartLogin) {
                            Text("Accedi con un account esistente")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }

                    Spacer().frame(height: 24)

                    // Footer
                    Text("Hybrid PQC · Voice-first · Deepfake Guard")
                        .font(.caption2.weight(.medium))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer().frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
        }
    }
}

private struct FeaturePill: View {
    let label: String

    /// PQC accent — cyan/blue tint matching Android's `extras.pqcAccent`.
    private let pqcAccent = Color(red: 0.40, green: 0.80, blue: 1.0)

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .tracking(1.0)
            .foregroundStyle(pqcAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(pqcAccent.opacity(0.12))
            )
    }
}

#Preview {
    WelcomeScreen(
        onStartFastSetup: {},
        onStartRegister: {},
        onStartLogin: {}
    )
}
