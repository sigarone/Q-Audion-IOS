import SwiftUI
import QAudionEngine

/// SMS-OTP code entry. Requests a code on first appearance
/// (`POST /api/v1/auth/otp/request`), lets the user type it back, and
/// completes register/login via `POST /api/v1/auth/otp/verify`. Includes a
/// resend timer that respects the server's `resend_after` value.
///
/// 2026-07-29 — new screen, replaces `OnboardingRoot`'s old
/// `phoneSubmittedPlaceholder` "backend not ready" stub now that the
/// server-side SMS-OTP flow is live.
struct OtpVerificationScreen: View {
    let appState: AppState
    /// Raw E.164 number collected by `PhoneEntryScreen`. Sent verbatim on
    /// the wire — the OTP endpoints identify the account by the real
    /// phone number (unlike the legacy hash-based register/login pair),
    /// since the server itself has to send the SMS.
    let e164: String
    let mode: PhoneEntryScreen.Mode
    /// True when the person ticked the age declaration box on `PhoneEntryScreen`
    /// (`.register` only; always false for `.login`). Sent with the code on verify.
    let ageDeclared: Bool
    /// What the person accepted in the three steps before the registration (nil for a login). Sent with the code.
    let termsAcceptance: TermsAcceptance?
    let onBack: () -> Void
    /// Fired after a successful REGISTER verify. Credentials are already
    /// saved (via `appState.completeOtpAuth`) but deliberately NOT yet
    /// activated — the caller routes to profile setup next.
    let onRegistered: () -> Void
    /// Fired after a successful LOGIN verify. The session is already
    /// activated (`appState.activatePendingSession()` was already called
    /// before this fires) — `ContentView` switches to `HomeView` on its
    /// own; the caller doesn't need to navigate anywhere further.
    let onLoggedIn: () -> Void

    @State private var code: String = ""
    @State private var isRequesting = false
    @State private var isVerifying = false
    @State private var errorText: String?
    @State private var resendRemaining: Int = 0
    @State private var resendTask: Task<Void, Never>?
    /// The server refused the acceptance (edition moved, boxes missing): the steps are shown again and the new
    /// acceptance replaces the one handed in. The number and the code typed stay where they are.
    @State private var acceptanceRefused = false
    @State private var renewedAcceptance: TermsAcceptance?
    @State private var showingTerms = false

    /// Only the last 4 digits, so the confirmation copy doesn't itself
    /// re-expose the full number to anyone glancing at the screen.
    private var maskedPhone: String {
        let digitsOnly = e164.filter { $0.isNumber }
        guard digitsOnly.count > 4 else { return e164 }
        return "•••• " + String(digitsOnly.suffix(4))
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
                    Text("Verifica il numero")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer().frame(height: 16)

                Text("Inserisci il codice")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)

                Spacer().frame(height: 8)

                Text("Ti abbiamo inviato un SMS al numero \(maskedPhone).")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 24)

                Spacer().frame(height: 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Codice")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                    TextField("123456", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(errorText != nil ? Color.red : .white.opacity(0.3), lineWidth: 1.2)
                        )
                        .onChange(of: code) { _ in errorText = nil }
                }
                .padding(.horizontal, 24)

                if let err = errorText {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }

                Spacer().frame(height: 16)

                resendRow

                Spacer().frame(height: 32)

                Button {
                    Task { await verify() }
                } label: {
                    Text(isVerifying
                            ? String(localized: "onboarding.otp.verifying", defaultValue: "Verifica in corso…", comment: "Label of the verify button while the SMS code is being checked.")
                            : String(localized: "onboarding.action.verify", defaultValue: "Verifica", comment: "Button that submits the SMS verification code during onboarding."))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(canVerify ? .black : .white.opacity(0.4))
                        .background(canVerify ? Color.white : Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!canVerify)
                .padding(.horizontal, 24)

                Spacer()
            }
            .qaudionReadableWidth()
            }
        }
        .task {
            await requestCode()
        }
        .onDisappear {
            resendTask?.cancel()
        }
        .fullScreenCover(isPresented: $showingTerms, onDismiss: {
            // The same registration goes on with the fresh acceptance and the code already typed.
            guard renewedAcceptance != nil else { return }
            Task { await verify() }
        }) {
            TermsAcceptanceLoaderView(
                api: LegalService.anonymousApi(serverUrl: appState.serverUrl),
                onAccepted: { acceptance in
                    renewedAcceptance = acceptance
                    showingTerms = false
                },
                onCancel: { showingTerms = false })
        }
    }

    /// What the verify request carries: the acceptance handed in, or the one made again after a refusal.
    private var effectiveAcceptance: TermsAcceptance? {
        acceptanceRefused ? renewedAcceptance : termsAcceptance
    }

    private var canVerify: Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isVerifying && !isRequesting
    }

    @ViewBuilder
    private var resendRow: some View {
        HStack(spacing: 6) {
            if isRequesting {
                ProgressView().scaleEffect(0.7)
                Text("Invio codice…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else if resendRemaining > 0 {
                Text("Puoi richiedere un nuovo codice tra \(resendRemaining)s")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Button {
                    Task { await requestCode() }
                } label: {
                    Text("Invia di nuovo il codice")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func requestCode() async {
        guard !isRequesting else { return }
        isRequesting = true
        errorText = nil
        defer { isRequesting = false }
        // Unauthenticated request — no access token exists yet at this
        // point in either register or login.
        let config = BackendConfig.pinned(serverUrl: appState.serverUrl)
        let provider = BCryptoBackendProvider(config: config)
        let purpose: OtpPurpose = (mode == .register) ? .register : .login
        do {
            let response = try await provider.accountApi.requestOtp(phoneNumber: e164, purpose: purpose)
            startResendCountdown(seconds: response.resendAfter)
        } catch {
            errorText = userFacingMessage(for: error)
        }
    }

    private func verify() async {
        guard canVerify else { return }
        isVerifying = true
        errorText = nil
        defer { isVerifying = false }
        let config = BackendConfig.pinned(serverUrl: appState.serverUrl)
        let provider = BCryptoBackendProvider(config: config)
        let purpose: OtpPurpose = (mode == .register) ? .register : .login
        let deviceName = UIDevice.current.name
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let termsAcceptance = effectiveAcceptance
        do {
            let result = try await provider.accountApi.verifyOtp(
                phoneNumber: e164,
                code: trimmedCode,
                purpose: purpose,
                deviceName: deviceName,
                displayName: nil,
                ageDeclared: ageDeclared,
                termsAcceptance: termsAcceptance
            )
            appState.completeOtpAuth(result)
            if mode == .register {
                onRegistered()
            } else {
                appState.activatePendingSession()
                onLoggedIn()
            }
        } catch {
            errorText = userFacingMessage(for: error)
            if mode == .register, BCryptoTermsRefusal.from(error) != nil {
                // The acceptance is no longer valid: it is dropped and the steps come back with a fresh document.
                acceptanceRefused = true
                renewedAcceptance = nil
                showingTerms = true
            }
        }
    }

    private func startResendCountdown(seconds: Int) {
        resendTask?.cancel()
        resendRemaining = max(0, seconds)
        guard resendRemaining > 0 else { return }
        resendTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                if resendRemaining <= 1 {
                    resendRemaining = 0
                    break
                }
                resendRemaining -= 1
            }
        }
    }

    /// Maps the 409/404/429/503 cases the task spec calls out to clear,
    /// contextual Italian copy; everything else falls back to
    /// `error.localizedDescription`.
    private func userFacingMessage(for error: Error) -> String {
        Self.userFacingMessage(for: error, mode: mode)
    }

    /// Pure mapping, exposed for unit tests.
    static func userFacingMessage(for error: Error, mode: PhoneEntryScreen.Mode) -> String {
        if BCryptoTermsRefusal.from(error) != nil { return LegalStrings.termsUpdatedReview }
        if let bcryptoError = error as? BCryptoError, case .httpError(let statusCode) = bcryptoError {
            switch statusCode {
            case 404:
                return mode == .login
                    ? String(localized: "onboarding.otp.error.no_account", defaultValue: "Nessun account trovato per questo numero. Prova a registrarti.", comment: "Sign-in error (HTTP 404): no account exists for the phone number.")
                    : String(localized: "onboarding.otp.error.invalid_request", defaultValue: "Richiesta non valida.", comment: "Registration error (HTTP 404 in registration mode): the request is not valid.")
            case 409:
                return mode == .register
                    ? String(localized: "onboarding.otp.error.already_registered", defaultValue: "Questo numero risulta già registrato. Prova ad accedere invece.", comment: "Registration error (HTTP 409): the phone number already has an account.")
                    : String(localized: "onboarding.otp.error.code_invalid", defaultValue: "Codice non valido o scaduto.", comment: "Sign-in error (HTTP 409): the SMS code is wrong or expired.")
            case 403 where mode == .register: return String(localized: "onboarding.error.registration_unavailable", defaultValue: "Registrazione temporaneamente non disponibile, riprova più tardi.", comment: "Registration error (HTTP 403): the server is not accepting registrations right now.")
            case 429:
                return String(localized: "onboarding.error.too_many_attempts", defaultValue: "Troppi tentativi. Riprova tra qualche minuto.", comment: "Onboarding error (HTTP 429): rate limit reached.")
            case 503:
                return String(localized: "onboarding.otp.error.sms_unavailable", defaultValue: "Servizio SMS temporaneamente non disponibile. Riprova più tardi.", comment: "Error (HTTP 503): the SMS provider is temporarily unavailable.")
            default:
                return String(localized: "onboarding.error.server", defaultValue: "Errore del server (\(statusCode)).", comment: "Onboarding error for any other server answer; %lld is the HTTP status code.")
            }
        }
        return error.localizedDescription
    }
}
