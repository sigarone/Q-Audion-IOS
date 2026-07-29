import SwiftUI
import QAudionEngine

/// Extension-only registration — no phone number at all. The server
/// assigns a PBX extension as the account's identifier; email is REQUIRED
/// here specifically because there is no phone number to fall back on for
/// account recovery / support. Matches
/// `POST /api/v1/auth/register/extension`.
///
/// 2026-07-29 — new screen; `WelcomeScreen` had no distinct entry point
/// for this path before (only fast-setup and the phone-based
/// register/login CTAs existed).
struct ExtensionOnlyRegisterScreen: View {
    let appState: AppState
    let onBack: () -> Void
    /// Fired after a successful registration — credentials are already
    /// saved via `appState.completeOtpAuth(_:)` (NOT yet activated); the
    /// caller routes straight to the mandatory recovery-phrase reveal
    /// (display name + email were already collected on THIS screen, so
    /// there's no separate profile-setup step for this path).
    let onRegistered: () -> Void

    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    /// Pragmatic sanity check, same spirit as the E.164 check on
    /// `PhoneEntryScreen` — not a full RFC 5322 validator, just enough to
    /// catch obvious typos before round-tripping to the server (which
    /// does the authoritative check and returns 400 on genuine garbage).
    private var isValidEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.firstIndex(of: "@") else { return false }
        let localPart = trimmed[trimmed.startIndex..<atIndex]
        let domainPart = trimmed[trimmed.index(after: atIndex)...]
        return !localPart.isEmpty && domainPart.contains(".") && !domainPart.hasPrefix(".") && !domainPart.hasSuffix(".")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                        }
                        Text("Registrazione solo interno")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer().frame(height: 16)

                    Text("Crea un account senza numero di telefono")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)

                    Spacer().frame(height: 8)

                    Text("Ti verrà assegnato un interno PBX come identificativo. Senza un numero di telefono l'email è l'unico canale per il recupero dell'account e per l'assistenza — per questo è obbligatoria.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 24)

                    Spacer().frame(height: 24)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email (obbligatoria)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                        TextField("nome@esempio.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.white.opacity(0.3), lineWidth: 1.2)
                            )
                    }
                    .padding(.horizontal, 24)

                    Spacer().frame(height: 16)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nome (opzionale)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                        TextField("Il tuo nome", text: $displayName)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.white.opacity(0.3), lineWidth: 1.2)
                            )
                    }
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
                        Task { await submit() }
                    } label: {
                        Text(isSubmitting ? "Creazione account…" : "Crea account")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundStyle(isValidEmail ? .black : .white.opacity(0.4))
                            .background(isValidEmail ? Color.white : Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!isValidEmail || isSubmitting)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private func submit() async {
        guard isValidEmail else { return }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unauthenticated — this IS the registration call, no token exists yet.
        let config = BackendConfig.pinned(serverUrl: appState.serverUrl)
        let provider = BCryptoBackendProvider(config: config)
        do {
            let result = try await provider.accountApi.registerExtensionOnly(
                displayName: trimmedName.isEmpty ? nil : trimmedName,
                email: trimmedEmail
            )
            appState.completeOtpAuth(result)
            onRegistered()
        } catch {
            errorText = userFacingMessage(for: error)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let bcryptoError = error as? BCryptoError, case .httpError(let statusCode) = bcryptoError {
            switch statusCode {
            case 400: return "Email mancante o non valida."
            case 409: return "Questa email risulta già registrata."
            case 429: return "Troppi tentativi. Riprova tra qualche minuto."
            case 503: return "Servizio non disponibile al momento. Riprova più tardi."
            default: return "Errore del server (\(statusCode))."
            }
        }
        return error.localizedDescription
    }
}
