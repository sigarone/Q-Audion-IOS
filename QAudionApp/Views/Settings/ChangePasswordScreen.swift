import SwiftUI
import UIKit
import QAudionEngine

/// Change the password of an account that signs in with extension + password. Reached from the account
/// section of Settings, which shows the row only when the profile says `password_login`.
///
/// The server answer carries the whole new session of this device; it replaces the stored pair
/// (`AppState.adoptChangedPasswordSession`). With "Disconnetti gli altri dispositivi" on (the default)
/// every other device loses its session. After a success the person is asked once whether to keep the
/// password behind Face ID / Touch ID (see `SavedLoginStore`).
///
/// Nothing typed here is logged.
struct ChangePasswordScreen: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var revokeOthers = true
    @State private var isSubmitting = false
    @State private var errorText: String?
    /// Seconds left of a wait the server asked for (429 / 503), 0 when none.
    @State private var waitSeconds = 0
    @State private var waitDeadline: Date?
    @State private var savePromptLogin: SavedLogin?
    @State private var showSavePrompt = false

    private var extensionText: String { appState.currentUserDialExtension ?? "" }

    private var newPasswordProblem: ChangePasswordError? {
        newPassword.isEmpty ? nil : PasswordPolicy.lengthProblem(newPassword)
    }

    private var mismatch: Bool { !confirmPassword.isEmpty && confirmPassword != newPassword }

    private var canSubmit: Bool {
        !currentPassword.isEmpty
            && !newPassword.isEmpty
            && PasswordPolicy.lengthProblem(newPassword) == nil
            && newPassword == confirmPassword
            && !isSubmitting
            && waitSeconds == 0
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !extensionText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            label(String(localized: "Interno"))
                            // Read only: it tells the system password manager which account the new password is for.
                            TextField("", text: .constant(extensionText))
                                .textContentType(.username)
                                .disabled(true)
                                .foregroundStyle(scheme.onSurfaceVariant)
                                .padding(14)
                                .background(fieldBorder)
                        }
                    }

                    passwordField(Self.currentLabel, text: $currentPassword,
                                  contentType: .password, id: "change-password-current-field")

                    VStack(alignment: .leading, spacing: 6) {
                        passwordField(Self.newLabel, text: $newPassword,
                                      contentType: .newPassword, id: "change-password-new-field")
                        Text(Self.hintText)
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(newPasswordProblem == nil ? scheme.onSurfaceVariant : Color.red)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        passwordField(Self.confirmLabel, text: $confirmPassword,
                                      contentType: .newPassword, id: "change-password-confirm-field")
                        if mismatch {
                            Text(Self.mismatchText)
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(Color.red)
                        }
                    }

                    Toggle(isOn: $revokeOthers) {
                        Text(Self.revokeLabel)
                            .qaudionStyle(type.bodyMedium)
                            .foregroundStyle(scheme.onSurface)
                    }
                    .accessibilityIdentifier("change-password-revoke-toggle")

                    if let errorText {
                        Text(errorText)
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(Color.red)
                            .accessibilityIdentifier("change-password-error")
                    }

                    QAudionButton(
                        action: { Task { await submit() } },
                        label: Self.submitLabel,
                        variant: .primary,
                        loading: isSubmitting,
                        enabled: canSubmit
                    )
                    .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(Self.titleText)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: waitDeadline) { await runCountdown() }
        .alert(
            SavedLoginTexts.promptTitle(SavedLoginBiometry.current().displayName),
            isPresented: $showSavePrompt
        ) {
            Button(SavedLoginTexts.promptSave) {
                if let login = savePromptLogin { SavedLoginStore.shared.save(login) }
                savePromptLogin = nil
                dismiss()
            }
            Button(SavedLoginTexts.promptDecline, role: .cancel) {
                SavedLoginStore.shared.decline()
                savePromptLogin = nil
                dismiss()
            }
        } message: {
            Text(SavedLoginTexts.promptMessage(SavedLoginBiometry.current().displayName))
        }
    }

    // MARK: - Pieces

    private func label(_ text: String) -> some View {
        Text(text)
            .qaudionStyle(type.labelMedium)
            .foregroundStyle(scheme.onSurfaceVariant)
    }

    private func passwordField(_ title: String, text: Binding<String>,
                               contentType: UITextContentType, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            SecureField("", text: text)
                .textContentType(contentType)
                .accessibilityIdentifier(id)
                .foregroundStyle(scheme.onSurface)
                .padding(14)
                .background(fieldBorder)
        }
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(scheme.onSurfaceVariant.opacity(0.4), lineWidth: 1)
    }

    // MARK: - Actions

    private func submit() async {
        guard canSubmit else { return }
        guard let provider = accountProvider() else {
            errorText = Self.sessionExpiredText
            return
        }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        let typedNew = newPassword
        do {
            let result = try await provider.accountApi.changePassword(
                current: currentPassword, new: typedNew, revokeOthers: revokeOthers)
            appState.adoptChangedPasswordSession(result)
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            snackbar?.show(.init(text: Self.doneText, severity: .info, durationSeconds: 3))
            afterSuccess(typedPassword: typedNew)
        } catch let failure as ChangePasswordError {
            apply(failure)
        } catch {
            errorText = Self.networkText
        }
    }

    /// Keeps a saved password in step with the new one, or asks the one-time question.
    private func afterSuccess(typedPassword: String) {
        let ext = extensionText
        let store = SavedLoginStore.shared
        guard !ext.isEmpty else { dismiss(); return }
        let login = SavedLogin(extensionNumber: ext, password: typedPassword)
        store.purgeIfInvalidated()
        if store.decision == .saved {
            store.updateIfSaved(login)
            dismiss()
        } else if store.shouldAsk, SavedLoginBiometry.current() != .none {
            savePromptLogin = login
            showSavePrompt = true
        } else {
            dismiss()
        }
    }

    private func apply(_ failure: ChangePasswordError) {
        switch failure {
        case .rateLimited(let sec):
            startWait(sec)
            errorText = Self.rateLimitedText(waitSeconds)
        case .serviceUnavailable(let sec):
            startWait(sec)
            errorText = Self.serviceUnavailableText(waitSeconds)
        default:
            errorText = Self.message(for: failure)
        }
    }

    private func startWait(_ sec: Int?) {
        let wait = max(0, min(sec ?? 0, 3600))
        waitSeconds = wait
        waitDeadline = wait > 0 ? Date().addingTimeInterval(TimeInterval(wait)) : nil
    }

    /// Counts the wait down once a second and keeps the message in step.
    private func runCountdown() async {
        guard let deadline = waitDeadline else { return }
        while !Task.isCancelled {
            let left = Int(deadline.timeIntervalSinceNow.rounded(.up))
            if left <= 0 {
                waitSeconds = 0
                waitDeadline = nil
                errorText = nil
                return
            }
            waitSeconds = left
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// The provider that carries the refresh machinery of the signed-in session; a one-off pinned one when
    /// the connection is not up.
    private func accountProvider() -> BCryptoBackendProvider? {
        if let live = appState.liveProvider { return live }
        guard let token = appState.authService.loadToken(), !token.isEmpty else { return nil }
        let config = BackendConfig.pinned(
            serverUrl: appState.serverUrl,
            accessToken: token,
            refreshToken: appState.authService.loadRefreshToken())
        return BCryptoBackendProvider(config: config)
    }

    // MARK: - Texts

    static var titleText: String {
        String(localized: "settings.change_password.title", defaultValue: "Cambia password",
               comment: "Settings row and screen title: change the account password.")
    }
    static var currentLabel: String {
        String(localized: "settings.change_password.current", defaultValue: "Password attuale",
               comment: "Change password screen: label of the field for the current password.")
    }
    static var newLabel: String {
        String(localized: "settings.change_password.new", defaultValue: "Nuova password",
               comment: "Change password screen: label of the field for the new password.")
    }
    static var confirmLabel: String {
        String(localized: "settings.change_password.confirm", defaultValue: "Ripeti la nuova password",
               comment: "Change password screen: label of the field that repeats the new password.")
    }
    static var hintText: String {
        String(localized: "settings.change_password.hint", defaultValue: "Almeno 8 caratteri.",
               comment: "Change password screen: the only rule for the new password.")
    }
    static var mismatchText: String {
        String(localized: "settings.change_password.mismatch", defaultValue: "Le password non coincidono.",
               comment: "Change password screen: the two new passwords differ.")
    }
    static var revokeLabel: String {
        String(localized: "settings.change_password.revoke_others", defaultValue: "Disconnetti gli altri dispositivi",
               comment: "Change password screen: switch that ends the session of every other device.")
    }
    static var submitLabel: String {
        String(localized: "settings.change_password.submit", defaultValue: "Cambia password",
               comment: "Change password screen: button that sends the change.")
    }
    static var doneText: String {
        String(localized: "settings.change_password.done", defaultValue: "Password cambiata.",
               comment: "Snackbar after the password was changed.")
    }
    static var sessionExpiredText: String {
        String(localized: "settings.change_password.error.session", defaultValue: "La sessione è scaduta. Esci e accedi di nuovo.",
               comment: "Change password screen: the session is not valid any more.")
    }
    static var networkText: String {
        String(localized: "security.error.network_retry", defaultValue: "Errore di rete — riprova.",
               comment: "Generic short error after a failed server request: network error, try again")
    }

    static func rateLimitedText(_ seconds: Int) -> String {
        if seconds > 0 {
            return String(localized: "settings.change_password.error.rate_limited",
                          defaultValue: "Troppi tentativi. Riprova tra \(seconds) s.",
                          comment: "Change password screen: too many attempts; %lld is the seconds to wait.")
        }
        return String(localized: "settings.change_password.error.rate_limited_soon",
                      defaultValue: "Troppi tentativi. Riprova tra poco.",
                      comment: "Change password screen: too many attempts, no wait time given.")
    }

    static func serviceUnavailableText(_ seconds: Int) -> String {
        if seconds > 0 {
            return String(localized: "settings.change_password.error.unavailable_wait",
                          defaultValue: "Servizio non disponibile. Riprova tra \(seconds) s.",
                          comment: "Change password screen: the service is busy; %lld is the seconds to wait.")
        }
        return String(localized: "settings.change_password.error.unavailable_soon",
                      defaultValue: "Servizio non disponibile. Riprova tra poco.",
                      comment: "Change password screen: the service is busy, no wait time given.")
    }

    /// One typed message per server answer.
    static func message(for failure: ChangePasswordError) -> String {
        switch failure {
        case .tooShort:
            return String(localized: "settings.change_password.error.short", defaultValue: "La nuova password deve avere almeno 8 caratteri.",
                          comment: "Change password screen: the new password is too short.")
        case .tooLong:
            return String(localized: "settings.change_password.error.long", defaultValue: "La nuova password è troppo lunga: al massimo 64 caratteri.",
                          comment: "Change password screen: the new password is too long.")
        case .common:
            return String(localized: "settings.change_password.error.common", defaultValue: "Questa password è troppo comune. Scegline un'altra.",
                          comment: "Change password screen: the new password is on the list of common passwords.")
        case .containsIdentity:
            return String(localized: "settings.change_password.error.identity", defaultValue: "La password non può contenere il tuo interno.",
                          comment: "Change password screen: the new password contains the account extension.")
        case .unchanged:
            return String(localized: "settings.change_password.error.unchanged", defaultValue: "La nuova password deve essere diversa da quella attuale.",
                          comment: "Change password screen: the new password equals the current one.")
        case .wrongCurrent:
            return String(localized: "settings.change_password.error.wrong_current", defaultValue: "La password attuale non è corretta.",
                          comment: "Change password screen: the current password is wrong.")
        case .sessionExpired:
            return sessionExpiredText
        case .unavailable:
            return String(localized: "settings.change_password.error.not_available", defaultValue: "Questo account non accede con la password.",
                          comment: "Change password screen: the account does not sign in with a password.")
        case .locked:
            return String(localized: "settings.change_password.error.locked", defaultValue: "Account bloccato. Contatta l'amministratore.",
                          comment: "Change password screen: the account is locked.")
        case .rateLimited(let sec):
            return rateLimitedText(sec ?? 0)
        case .serviceUnavailable(let sec):
            return serviceUnavailableText(sec ?? 0)
        case .malformedResponse:
            return String(localized: "settings.change_password.error.malformed", defaultValue: "Password cambiata, ma la sessione non è stata aggiornata. Esci e accedi di nuovo.",
                          comment: "Change password screen: the server accepted the change but its answer could not be read.")
        case .invalidRequest, .server:
            return String(localized: "settings.change_password.error.generic", defaultValue: "Impossibile cambiare la password. Riprova.",
                          comment: "Change password screen: the change failed for another reason.")
        }
    }
}
