import SwiftUI
import QAudionEngine

/// Extension-only registration — no phone number at all. The server
/// assigns a PBX extension as the account's identifier; email is REQUIRED
/// here specifically because there is no phone number to fall back on for
/// account recovery / support. Registration is open: no invite code is asked. Matches
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
    @State private var ageDeclared = false
    @State private var showingTerms = false
    @State private var acceptedTerms: TermsAcceptance?
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

    /// The form is submittable only with a well-formed email and the age
    /// declaration box ticked, like on the phone flow.
    private var canSubmit: Bool {
        Self.isSubmittable(emailValid: isValidEmail, ageDeclared: ageDeclared)
    }

    /// The form's gate without the view: both conditions have to hold.
    static func isSubmittable(emailValid: Bool, ageDeclared: Bool) -> Bool {
        emailValid && ageDeclared
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
                        Text("Registrazione con interno")
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
                            .accessibilityIdentifier("register-email-field")
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

                    Spacer().frame(height: 16)

                    AgeDeclarationSection(declared: $ageDeclared)
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
                        // The acceptance screen comes first; the account is created when they are done.
                        guard canSubmit else { return }
                        acceptedTerms = nil
                        showingTerms = true
                    } label: {
                        Text(isSubmitting
                                ? String(localized: "onboarding.register.creating", defaultValue: "Creazione account…", comment: "Label of the registration submit button while the account is being created.")
                                : String(localized: "onboarding.register.create", defaultValue: "Crea account", comment: "Submit button of the extension-and-email registration screen."))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundStyle(canSubmit ? .black : .white.opacity(0.4))
                            .background(canSubmit ? Color.white : Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canSubmit || isSubmitting)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
                .qaudionReadableWidth()
            }
        }
        .fullScreenCover(isPresented: $showingTerms, onDismiss: {
            guard let acceptance = acceptedTerms else { return }
            Task { await submit(acceptance: acceptance) }
        }) {
            TermsAcceptanceLoaderView(
                api: LegalService.anonymousApi(serverUrl: appState.serverUrl),
                onAccepted: { acceptance in
                    acceptedTerms = acceptance
                    showingTerms = false
                },
                onCancel: { showingTerms = false })
        }
    }

    private func submit(acceptance: TermsAcceptance) async {
        guard canSubmit else { return }
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
                email: trimmedEmail,
                ageDeclared: ageDeclared,
                termsAcceptance: acceptance
            )
            appState.completeOtpAuth(result)
            onRegistered()
        } catch {
            errorText = userFacingMessage(for: error)
            if BCryptoTermsRefusal.from(error) != nil {
                // The acceptance is no longer valid: the screen comes back with a fresh document, the form stays filled,
                // and the registration is sent again once they are done.
                acceptedTerms = nil
                showingTerms = true
            }
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        Self.userFacingMessage(for: error)
    }

    /// Pure mapping, exposed for unit tests.
    static func userFacingMessage(for error: Error) -> String {
        if BCryptoTermsRefusal.from(error) != nil { return LegalStrings.termsUpdatedReview }
        if let bcryptoError = error as? BCryptoError, case .httpError(let statusCode) = bcryptoError {
            switch statusCode {
            case 400: return String(localized: "onboarding.error.email_invalid", defaultValue: "Email mancante o non valida.", comment: "Registration error (HTTP 400): the email is missing or not valid.")
            case 409: return String(localized: "onboarding.error.email_taken", defaultValue: "Questa email risulta già registrata.", comment: "Registration error (HTTP 409): the email is already registered.")
            case 403: return String(localized: "onboarding.error.registration_unavailable", defaultValue: "Registrazione temporaneamente non disponibile, riprova più tardi.", comment: "Registration error (HTTP 403): the server is not accepting registrations right now.")
            case 429: return String(localized: "onboarding.error.too_many_attempts", defaultValue: "Troppi tentativi. Riprova tra qualche minuto.", comment: "Onboarding error (HTTP 429): rate limit reached.")
            case 503: return String(localized: "onboarding.error.service_unavailable", defaultValue: "Servizio non disponibile al momento. Riprova più tardi.", comment: "Registration error (HTTP 503): the service is temporarily unavailable.")
            default: return String(localized: "onboarding.error.server", defaultValue: "Errore del server (\(statusCode)).", comment: "Onboarding error for any other server answer; %lld is the HTTP status code.")
            }
        }
        return error.localizedDescription
    }
}
