import SwiftUI
import QAudionEngine

/// The two rows of the account section that belong to a password account: change the password, and
/// keep it behind Face ID / Touch ID. Nothing is drawn unless the profile says `password_login`
/// (an account that signs in with extension + password); the profile is read when the section appears.
struct PasswordSettingsRows: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme

    @State private var passwordLogin = false
    @State private var biometry: SavedLoginBiometry = .none
    @State private var keepSaved = true
    @State private var hasSaved = false

    var body: some View {
        VStack(spacing: 8) {
            if passwordLogin {
                changePasswordRow
                recoveryContactsRow
                if biometry != .none {
                    SettingsToggleRow(
                        title: SavedLoginTexts.settingsTitle(biometry.displayName),
                        subtitle: savedSubtitle,
                        isOn: savedBinding
                    )
                }
            }
        }
        .task { await load() }
    }

    private var changePasswordRow: some View {
        NavigationLink {
            LazyView { ChangePasswordScreen() }
        } label: {
            SettingsRow(icon: "key",
                        iconColor: scheme.primary,
                        title: "settings.change_password.title",
                        subtitle: "settings.change_password.subtitle")
        }
        .buttonStyle(.plain)
    }

    /// Optional email and phone number that let the person approve a new sign-in with a code.
    private var recoveryContactsRow: some View {
        NavigationLink {
            LazyView { RecoveryContactsScreen(model: appState.recoveryContacts) }
        } label: {
            SettingsRow(icon: "envelope.badge.shield.half.filled",
                        iconColor: scheme.primary,
                        title: "settings.recovery_contacts.title",
                        subtitle: "settings.recovery_contacts.subtitle")
        }
        .buttonStyle(.plain)
    }

    private var savedSubtitle: String {
        if hasSaved { return SavedLoginTexts.settingsStored }
        return keepSaved ? SavedLoginTexts.settingsPending : SavedLoginTexts.settingsOff
    }

    private var savedBinding: Binding<Bool> {
        Binding(
            get: { keepSaved },
            set: { on in
                let store = SavedLoginStore.shared
                if on { store.resetDecision() } else { store.decline() }
                keepSaved = on
                hasSaved = store.hasSavedLogin
            }
        )
    }

    private func load() async {
        let store = SavedLoginStore.shared
        biometry = SavedLoginBiometry.current()
        hasSaved = store.hasSavedLogin
        keepSaved = store.decision != .declined
        guard let provider = appState.liveProvider else { return }
        if let profile = try? await provider.accountApi.getProfile() {
            passwordLogin = profile.passwordLogin == true
        }
    }
}
