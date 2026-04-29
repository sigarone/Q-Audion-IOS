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

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    Text("Q-AUDION · SECURE COMMUNICATIONS")
                        .qaudionStyle(type.labelSmall)
                        .tracking(2.5)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.top, 8)

                    Spacer().frame(height: 56)

                    Text("Benvenuto a Q-Audion.")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(scheme.onBackground)
                        .lineLimit(2)

                    Spacer().frame(height: 12)

                    Text("La voce è la tua chiave.")
                        .qaudionStyle(type.titleMedium)
                        .foregroundStyle(scheme.onSurfaceVariant)

                    Spacer().frame(height: 32)

                    // Feature pills (PQC accent token from extras)
                    HStack(spacing: 8) {
                        FeaturePill(label: "ML-KEM 1024", accent: extras.pqcAccent)
                        FeaturePill(label: "Voice-as-Key", accent: extras.pqcAccent)
                        FeaturePill(label: "Deepfake Guard", accent: extras.pqcAccent)
                    }

                    Spacer().frame(height: 32)

                    // CTAs — using the QAudionButton design-system component
                    VStack(spacing: 12) {
                        QAudionButton(
                            action: onStartFastSetup,
                            label: "Configurazione rapida (QR)",
                            variant: .primary
                        )
                        QAudionButton(
                            action: onStartRegister,
                            label: "Inizia con un codice invito",
                            variant: .secondary
                        )
                        QAudionButton(
                            action: onStartLogin,
                            label: "Accedi con un account esistente",
                            variant: .text
                        )
                    }

                    Spacer().frame(height: 24)

                    Text("Hybrid PQC · Voice-first · Deepfake Guard")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.5)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer().frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
        }
    }
}

/// Feature pill rendered with the design-system `pqcAccent` color (no
/// more hardcoded `Color(red: 0.40, green: 0.80, blue: 1.0)`). 12% fill
/// + full-color label matches Android's `extras.pqcAccent.copy(alpha=0.12f)`.
private struct FeaturePill: View {
    @Environment(\.qaudionType) private var type
    let label: String
    let accent: Color

    var body: some View {
        Text(label)
            .qaudionStyle(type.labelSmall)
            .tracking(1.0)
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.12)))
    }
}

#Preview {
    WelcomeScreen(
        onStartFastSetup: {},
        onStartRegister: {},
        onStartLogin: {}
    )
}
