import SwiftUI
import QAudionEngine

/// Post-registration profile setup — collects an optional display name
/// right after a successful SMS-OTP registration, before the mandatory
/// recovery-phrase reveal step. Uses the EXISTING `updateProfile`
/// endpoint (already wired app-wide) — no new server contract needed.
///
/// The credentials saved by `AppState.completeOtpAuth(_:)` are already in
/// the Keychain at this point (even though `appState.isAuthenticated` is
/// still deliberately false — activation is deferred until the
/// recovery-reveal step completes, see the doc comment on
/// `AppState.completeOtpAuth`), so `appState.authService.loadToken()`
/// already works here.
struct ProfileSetupScreen: View {
    let appState: AppState
    /// Fired whether the user saved a name or tapped "Salta" (skip) — the
    /// display name is optional server-side. Caller routes to the
    /// mandatory recovery-phrase reveal next.
    let onDone: () -> Void

    @State private var displayName: String = ""
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 32)

                Text("Come vuoi chiamarti?")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)

                Spacer().frame(height: 8)

                Text("Il tuo nome sarà visibile ai tuoi contatti. Puoi cambiarlo in qualsiasi momento dalle impostazioni.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 24)

                Spacer().frame(height: 24)

                TextField("Il tuo nome", text: $displayName)
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.3), lineWidth: 1.2)
                    )
                    .padding(.horizontal, 24)

                if let err = errorText {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }

                Spacer().frame(height: 24)

                Button {
                    Task { await save() }
                } label: {
                    Text(isSaving ? "Salvataggio…" : "Continua")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(.black)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isSaving)
                .padding(.horizontal, 24)

                Button {
                    onDone()
                } label: {
                    Text("Salta")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(isSaving)
                .padding(.horizontal, 24)
                .padding(.top, 4)

                Spacer()
            }
        }
    }

    private func save() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing typed — same as tapping "Salta".
            onDone()
            return
        }
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        guard let token = appState.authService.loadToken() else {
            // Should not happen — completeOtpAuth() always saves a token
            // before this screen is reachable — but fail soft rather than
            // stranding the user on a screen with no way forward.
            onDone()
            return
        }
        let config = BackendConfig.pinned(serverUrl: appState.serverUrl, accessToken: token)
        let provider = BCryptoBackendProvider(config: config)
        do {
            try await provider.accountApi.updateProfile(displayName: trimmed, statusMessage: nil, avatarUrl: nil)
            onDone()
        } catch {
            errorText = "Impossibile salvare il nome: \(error.localizedDescription). Puoi riprovare più tardi dalle impostazioni."
        }
    }
}
