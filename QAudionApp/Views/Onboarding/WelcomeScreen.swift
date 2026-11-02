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
///       1. **Primary** "Crea un account" — SMS-OTP
///          registration (`PhoneEntryScreen` → `OtpVerificationScreen`)
///       2. **Text** "Accedi con un account esistente" — SMS-OTP login,
///          same phone-entry screen in `.login` mode
///       3. **Text** "Accedi con estensione e password" — typed login
///       4. **Text** "Registrati senza numero" — extension-only
///          registration (email required, no phone at all)
///       5. **Text** "Ho già una frase di recupero" — restores an
///          existing account's session from a previously-enrolled
///          mnemonic (fresh-install recovery path)
///   - footer "Hybrid PQC · Voice-first · Deepfake Guard"
///
/// All the CTAs above are live.
struct WelcomeScreen: View {

    let onStartRegister: () -> Void
    let onStartLogin: () -> Void
    /// Typed login (extension + password).
    let onStartExtensionLogin: () -> Void
    /// 2026-07-29 — extension-only registration (no phone number, email
    /// required). Previously there was no distinct CTA for this path.
    let onStartExtensionOnlyRegister: () -> Void
    /// 2026-07-29 — restores an existing account's session from a
    /// previously-enrolled recovery mnemonic. Previously
    /// `RecoverySeedContainer(mode: .verify)` had zero call sites
    /// anywhere in the shipped app, so a fresh install had no way to
    /// actually use a saved mnemonic.
    let onStartRecoveryRestore: () -> Void

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
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    Spacer().frame(height: 56)

                    Text("Benvenuto a Q-Audion.")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(scheme.onBackground)
                        .lineLimit(2)
                        // A word never runs past the edge: on a narrow cover display or at a large text size the
                        // headline shrinks (down to half) and wraps instead.
                        .minimumScaleFactor(0.5)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer().frame(height: 12)

                    Text("La voce è la tua chiave.")
                        .qaudionStyle(type.titleMedium)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer().frame(height: 32)

                    // Feature pills (PQC accent token from extras)
                    AnyLayout(FeatureFlowLayout(spacing: 8)) {
                        FeaturePill(label: "ML-KEM 1024", accent: extras.pqcAccent)
                        FeaturePill(label: "Voice-as-Key", accent: extras.pqcAccent)
                        FeaturePill(label: "Deepfake Guard", accent: extras.pqcAccent)
                    }

                    Spacer().frame(height: 32)

                    // CTAs — using the QAudionButton design-system component
                    VStack(spacing: 12) {
                        QAudionButton(
                            action: onStartRegister,
                            label: String(localized: "onboarding.welcome.cta_register", defaultValue: "Crea un account", comment: "Welcome screen button: start the registration of a new account."),
                            variant: .primary
                        )
                        QAudionButton(
                            action: onStartLogin,
                            label: String(localized: "onboarding.welcome.cta_login", defaultValue: "Accedi con un account esistente", comment: "Welcome screen button: sign in with an account that already exists."),
                            variant: .text
                        )
                        QAudionButton(
                            action: onStartExtensionLogin,
                            label: String(localized: "Accedi con estensione e password"),
                            variant: .text
                        )
                        QAudionButton(
                            action: onStartExtensionOnlyRegister,
                            label: String(localized: "onboarding.welcome.cta_extension_register", defaultValue: "Registrati con interno e email (senza numero)", comment: "Welcome screen button: register with a PBX extension (interno) and an email, without a phone number."),
                            variant: .text
                        )
                        QAudionButton(
                            action: onStartRecoveryRestore,
                            label: String(localized: "onboarding.welcome.cta_recovery", defaultValue: "Ho già una frase di recupero", comment: "Welcome screen button: restore an account from an existing recovery phrase."),
                            variant: .text
                        )
                    }

                    Spacer().frame(height: 12)

                    // App Store 5.1.1(i) — privacy policy reachable before
                    // any account is created, not only from Settings.
                    Button {
                        LegalLinks.open(LegalLinks.privacyPolicy())
                    } label: {
                        Text("Continuando accetti l'Informativa privacy")
                            .qaudionStyle(type.labelSmall)
                            .underline()
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Spacer().frame(height: 12)

                    Text("Hybrid PQC · Voice-first · Deepfake Guard")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.5)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer().frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                // The column keeps a readable width on the large inner display of a foldable iPhone and on tablets, and
                // takes exactly the width it is given on a phone: the content never has a width of its own.
                .qaudionReadableWidth()
            }
        }
    }
}

/// Places the feature pills in rows: a pill that does not fit on the current row
/// moves to the next one. A pill is never split (see `FeaturePill`), so the text of
/// a token like "ML-KEM 1024" keeps its line at every text size.
private struct FeatureFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                widest = max(widest, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widest, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
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
            .fixedSize(horizontal: true, vertical: false)
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
        onStartRegister: {},
        onStartLogin: {},
        onStartExtensionLogin: {},
        onStartExtensionOnlyRegister: {},
        onStartRecoveryRestore: {}
    )
}
