import SwiftUI
import QAudionEngine

/// W46: dev-only "Reset dati locali" screen. Surfaces a one-tap action
/// to wipe the local UserDefaults state accumulated across sessions:
/// `myPhones`, `dialExtension`, `beta opt-in`, `dismissed admin banner`,
/// `recentCalls`, etc. **Does NOT** clear the auth token / device id /
/// keychain — those stay intact so the user is still logged in. To
/// re-onboard from scratch, log out from the SettingsScreen sign-out
/// button (already wipes credentials) THEN open this screen and reset.
///
/// Why this exists: TestFlight QA needs a clean slate without
/// re-installing the app. `UserDefaults` accumulates session state
/// that the design-system / engine surfaces don't expose to the user.
/// One destructive button, gated behind a confirmation alert.
@MainActor
final class DevResetContainer: ObservableObject {
    @Published var lastResetSummary: String? = nil
    @Published var resetting: Bool = false

    /// Keys we own in `UserDefaults`. Kept centralized so future code
    /// adding new persisted keys can be added here in one place; the
    /// reset action stays exhaustive.
    static let knownKeys: [String] = [
        // W44 MyPhones
        "com.qaudion.profile.myPhones",
        "com.qaudion.profile.dialExtension",
        // ChatList admin banner dismissal
        "com.qaudion.chatlist.adminBannerDismissed",
        // OTA channel opt-in (W42)
        "com.qaudion.ota.betaOptIn",
        // Conversation pin / mute state (if persisted)
        "com.qaudion.chat.pinned",
        "com.qaudion.chat.muted",
        // Recent calls history (legacy mock fallback)
        "com.qaudion.calls.recent",
        // Voice enrollment skip flag
        "com.qaudion.voice.enrollmentSkipped",
        // W58 Contacts sort mode
        "com.qaudion.contacts.sortMode",
        // W68a CallHistory deletion tombstones
        "com.qaudion.callHistory.deletedIds",
        // W68b ChatList read-mark per conversation
        "com.qaudion.chat.markedReadAt",
        // W68c Pending group-invite replay queue
        "com.qaudion.groupInvite.pending"
    ]

    /// Auth-related keys that we DO NOT touch in this reset. Listed
    /// here for documentation — the user must explicitly sign out to
    /// clear these. Wiping them silently from a dev tool would log the
    /// user out unexpectedly.
    static let authKeys: [String] = [
        "com.qaudion.auth.token",
        "com.qaudion.auth.refresh_token",
        "com.qaudion.auth.user_id",
        "com.qaudion.auth.device_id"
    ]

    func reset() async {
        resetting = true
        lastResetSummary = nil
        var wiped: Int = 0
        for key in Self.knownKeys {
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
                wiped += 1
            }
        }
        // UX: brief artificial delay so the spinner is visible.
        try? await Task.sleep(nanoseconds: 400_000_000)
        lastResetSummary = wiped > 0
            ? "Wipe completato — \(wiped) chiavi rimosse."
            : "Nessun dato locale da rimuovere."
        resetting = false
    }
}

struct DevResetScreen: View {
    @StateObject private var container = DevResetContainer()
    @State private var showingConfirmation: Bool = false

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    introCard
                    keysCard
                    if let summary = container.lastResetSummary {
                        summaryBanner(summary)
                    }
                    resetButton
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Reset dati locali")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Conferma reset",
               isPresented: $showingConfirmation) {
            Button("Annulla", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task { await container.reset() }
            }
        } message: {
            Text("Verranno rimossi numeri salvati, opt-in beta, banner dismessi, e tutto lo stato non-credenziale. La sessione di login resta attiva — usa Esci nelle Impostazioni se vuoi anche fare logout.")
        }
    }

    // MARK: - Intro

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEVTOOL")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(extras.warning)
            Text("Wipe di tutto lo stato locale non-credenziale (UserDefaults). Utile per QA TestFlight: ripulisce numeri, opt-in beta, banner dismessi, senza fare logout. La sessione e i token restano intatti.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(extras.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(extras.warning.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Keys list

    private var keysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHIAVI INTERESSATE (\(DevResetContainer.knownKeys.count))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            ForEach(DevResetContainer.knownKeys, id: \.self) { key in
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Text(key)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(scheme.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer().frame(height: 8)
            Text("PRESERVATE (auth)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(extras.success)
            ForEach(DevResetContainer.authKeys, id: \.self) { key in
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(extras.success)
                    Text(key)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Summary banner (post-reset)

    private func summaryBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(extras.success)
            Text(msg)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(extras.success.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(extras.success.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Reset button

    private var resetButton: some View {
        Button {
            showingConfirmation = true
        } label: {
            HStack(spacing: 8) {
                if container.resetting {
                    ProgressView().progressViewStyle(.circular)
                        .tint(extras.riskHigh)
                } else {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(container.resetting ? "Reset in corso…" : "Reset dati locali")
                    .qaudionStyle(type.labelLarge)
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
                    .stroke(extras.riskHigh.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(container.resetting)
    }
}

#Preview {
    NavigationStack {
        DevResetScreen()
    }
    .qAudionTheme(dark: true)
}
