import SwiftUI
import QAudionEngine

/// New design-token-aware Settings root. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-settings/.../SettingsScreen.kt`.
///
/// Cross-platform parity is the contract:
///   - Same component vocabulary (ProfileHeroCard, SecurityChipsRow,
///     SettingsRow, SettingsSectionHeader)
///   - Same color tokens (scheme.X, extras.Y) — byte-for-byte hex with
///     Android core-ui
///   - Same Italian copy strings (canonical user-facing text from spec)
///   - Same section ordering and dp/pt values
///
/// Layout (top → bottom):
///   1. Top bar — "Impostazioni" title + ⋯ menu (placeholder)
///   2. ProfileHeroCard — avatar + display name + handle + status + EDIT
///   3. SecurityChipsRow — PSK / PQC / VOICE / OTA badges
///   4. ACCOUNT — Profilo / Numero di telefono / Dispositivi / Esci
///   5. SICUREZZA — Security / Voice-as-Key / Gestione chiavi /
///                  Trasporto / Scambio NFC
///   6. PRIVACY — Privacy / Chat / Notifiche / Chiamate
///   7. DATI — Backup
///   8. INFO — Info app
///   9. SVILUPPATORE — Call Design Showcase (TestFlight QA entry)
///
/// Existing iOS sub-screens (AccountSettingsScreen, PrivacySettingsScreen,
/// CallsSettingsScreen, ChatSettingsScreen, NotificationsSettingsScreen,
/// BackupSettingsScreen, KeyManagementScreen, TransportSettingsScreen,
/// AboutSettingsScreen, SecurityDashboardScreen, DeviceManagementScreen)
/// remain untouched — they're reachable via NavigationLink destinations
/// from this root. Internal toggles (Deepfake Guard, Read Receipts, etc.)
/// stay inside their respective sub-screens; lifting them to root is
/// deferred until the engine surfaces a unified `SettingsUiState`.
struct SettingsScreen: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    var body: some View {
        NavigationStack {
            ZStack {
                scheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        ProfileHeroCard(
                            displayName: profileDisplayName,
                            handle: profileHandle,
                            statusMessage: "Disponibile per chiamate sicure.",
                            avatarUrl: nil,
                            onEditTap: { /* navigation handled via row below */ }
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                        SecurityChipsRow()
                            .padding(.top, 8)

                        accountSection
                        sicurezzaSection
                        privacySection
                        datiSection
                        infoSection
                        sviluppatoreSection

                        Spacer().frame(height: 24)
                        signOutButton
                            .padding(.horizontal, 16)
                            .padding(.bottom, 32)
                    }
                }
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Text("Impostazioni")
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Button(action: { /* TODO: header menu */ }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Altro")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: - Sections

    private var accountSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("ACCOUNT")
            NavigationLink {
                AccountSettingsScreen(appState: appState)
            } label: {
                SettingsRow(icon: "person",
                            iconColor: scheme.primary,
                            title: "Profilo",
                            subtitle: profileDisplayName)
            }
            .buttonStyle(.plain)

            NavigationLink {
                DeviceManagementScreen(state: appState)
            } label: {
                SettingsRow(icon: "iphone",
                            iconColor: scheme.primary,
                            title: "Dispositivi collegati",
                            subtitle: "Gestisci i dispositivi attivi")
            }
            .buttonStyle(.plain)

            // W44: I miei numeri (multi-phone management) — 1:1 port del
            // blocco "I MIEI NUMERI" di Android `ProfileScreen.kt`. Permette
            // di registrare multipli E.164 sull'account così i peer ti
            // raggiungono via uno qualsiasi (engine wiring per
            // POST /contacts/phones pending).
            NavigationLink {
                MyPhonesScreen()
            } label: {
                SettingsRow(icon: "phone.badge.plus",
                            iconColor: scheme.primary,
                            title: "I miei numeri",
                            subtitle: "Interno · numeri di telefono")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var sicurezzaSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("SICUREZZA")
            NavigationLink {
                SecurityDashboardScreen(state: appState)
            } label: {
                SettingsRow(icon: "shield.lefthalf.filled",
                            iconColor: scheme.primary,
                            title: "Security Dashboard",
                            subtitle: "Confidence · trust · eventi")
            }
            .buttonStyle(.plain)

            NavigationLink {
                KeyManagementScreen(state: appState)
            } label: {
                SettingsRow(icon: "key.fill",
                            iconColor: extras.pqcAccent,
                            title: "Gestione chiavi",
                            subtitle: "PSK · PQC · rotazione")
            }
            .buttonStyle(.plain)

            NavigationLink {
                VoiceEnrollmentScreen()
            } label: {
                SettingsRow(icon: "waveform.badge.mic",
                            iconColor: extras.pqcAccent,
                            title: "Voice-as-Key",
                            subtitle: "Registra voiceprint · 5 campioni")
            }
            .buttonStyle(.plain)

            NavigationLink {
                TransportSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "arrow.left.arrow.right",
                            iconColor: scheme.primary,
                            title: "Protocollo di trasporto",
                            subtitle: "P2P · TURN · Relay")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var privacySection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("PRIVACY E COMUNICAZIONI")
            NavigationLink {
                PrivacySettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "hand.raised.fill",
                            iconColor: scheme.primary,
                            title: "Controlli privacy",
                            subtitle: "Conferme · ultimo accesso · scopribilità")
            }
            .buttonStyle(.plain)

            NavigationLink {
                CallsSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "phone.fill",
                            iconColor: scheme.primary,
                            title: "Chiamate",
                            subtitle: "Codec · qualità · echo cancellation")
            }
            .buttonStyle(.plain)

            NavigationLink {
                ChatSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "bubble.right",
                            iconColor: scheme.primary,
                            title: "Chat",
                            subtitle: "Cifratura · scadenza messaggi")
            }
            .buttonStyle(.plain)

            NavigationLink {
                NotificationsSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "bell.fill",
                            iconColor: scheme.primary,
                            title: "Notifiche",
                            subtitle: "VoIP push · banner · suoni")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var datiSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("DATI")
            NavigationLink {
                BackupSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "externaldrive.fill",
                            iconColor: scheme.primary,
                            title: "Backup cifrato",
                            subtitle: "SCRYPT(N=2¹⁷) · AES-256-GCM")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var infoSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("INFO")
            NavigationLink {
                AboutSettingsScreen(state: appState)
            } label: {
                SettingsRow(icon: "info.circle",
                            iconColor: scheme.primary,
                            title: "Informazioni",
                            subtitle: "Versione · protocollo · OSS")
            }
            .buttonStyle(.plain)

            // W42: Aggiornamento firmato OTA. Stub UI con mock catalog —
            // l'engine wirerà il vero fetch + Ed25519 verify quando lands.
            // 1:1 visual port di Android `OtaUpdateScreen.kt`.
            NavigationLink {
                OtaUpdateScreen()
            } label: {
                SettingsRow(icon: "arrow.triangle.2.circlepath.icloud",
                            iconColor: extras.pqcAccent,
                            title: "Aggiornamento OTA",
                            subtitle: "Catalogo firmato · Ed25519 · canali")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var sviluppatoreSection: some View {
        VStack(spacing: 8) {
            SettingsSectionHeader("SVILUPPATORE")
            NavigationLink {
                CallDesignShowcase()
            } label: {
                SettingsRow(icon: "paintbrush.fill",
                            iconColor: .orange,
                            title: "Call Design Showcase",
                            subtitle: "Anteprima Incoming · Outgoing · InCall · Group")
            }
            .buttonStyle(.plain)

            // W43: dev-only network simulator. UI-only stub today; will
            // wire to engine `NetworkConditionSimulator` when surfaced
            // on iOS. 1:1 port of Android `NetworkSimulatorScreen.kt`.
            NavigationLink {
                NetworkSimulatorScreen()
            } label: {
                SettingsRow(icon: "antenna.radiowaves.left.and.right",
                            iconColor: .orange,
                            title: "Simulatore rete (dev)",
                            subtitle: "Latenza · perdita · offline · presets")
            }
            .buttonStyle(.plain)

            // W46: Reset dati locali (UserDefaults wipe non-credenziale).
            // Utile per QA TestFlight per ripartire pulito senza
            // reinstallare l'app o forzare logout.
            NavigationLink {
                DevResetScreen()
            } label: {
                SettingsRow(icon: "trash.slash.fill",
                            iconColor: .orange,
                            title: "Reset dati locali",
                            subtitle: "UserDefaults wipe · auth preservata")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Sign-out destructive button

    private var signOutButton: some View {
        Button {
            // AppState.logout() is sync (clears token + flips
            // isAuthenticated to false). ContentView's reactive Group
            // routing handles re-presenting the OnboardingRoot once
            // isAuthenticated == false. We push a snackbar BEFORE
            // logout so the host (still mounted on ContentView) gets
            // the message before isAuthenticated flips and the entire
            // SettingsScreen is torn down.
            snackbar?.show(.init(text: "Sessione chiusa.", severity: .info,
                                 durationSeconds: 3))
            appState.logout()
        } label: {
            HStack {
                // SF Symbol that semantically reads as "log out" rather
                // than "hide". OpenRouter review on v1.0.65 flagged
                // `eye.slash.fill` as misleading for sign-out.
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .regular))
                Text("Esci")
                    .qaudionStyle(type.bodyMedium)
            }
            .foregroundStyle(extras.riskHigh)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(extras.riskHigh.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(extras.riskHigh.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var profileDisplayName: String {
        // Pull display name from AppState if available, else show userId
        // prefix or a friendly fallback. The legacy AppState exposes
        // `currentUserId`; richer profile data lives in
        // AccountSettingsContainer (lazy-loaded). The hero card pulls
        // that fuller profile internally when navigated to.
        if let userId = appState.currentUserId, !userId.isEmpty {
            return userId.hasPrefix("user-")
                ? String(userId.dropFirst(5)).capitalized
                : userId
        }
        return "Q-Audion User"
    }

    private var profileHandle: String? {
        guard let userId = appState.currentUserId else { return nil }
        // Show first 8 + ellipsis + last 4 of the user-id (typically a
        // sha256 hex of the phone number) so peers can fingerprint-match.
        if userId.count > 12 {
            return "Int. — · \(userId.prefix(8))…\(userId.suffix(4))"
        }
        return "Int. — · \(userId)"
    }
}

#Preview {
    SettingsScreen()
        .environmentObject(AppState())
        .qAudionTheme(dark: true)
}
