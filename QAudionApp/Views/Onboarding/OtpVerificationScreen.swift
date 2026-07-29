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
    /// Only meaningful for `.register`; always nil for `.login`.
    let inviteCode: String?
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
                    Text(isVerifying ? "Verifica in corso…" : "Verifica")
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
        }
        .task {
            await requestCode()
        }
        .onDisappear {
            resendTask?.cancel()
        }
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
        do {
            let result = try await provider.accountApi.verifyOtp(
                phoneNumber: e164,
                code: trimmedCode,
                purpose: purpose,
                deviceName: deviceName,
                inviteCode: inviteCode,
                displayName: nil
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
        if let bcryptoError = error as? BCryptoError, case .httpError(let statusCode) = bcryptoError {
            switch statusCode {
            case 404:
                return mode == .login
                    ? "Nessun account trovato per questo numero. Prova a registrarti."
                    : "Richiesta non valida."
            case 409:
                return mode == .register
                    ? "Questo numero risulta già registrato. Prova ad accedere invece."
                    : "Codice non valido o scaduto."
            case 429:
                return "Troppi tentativi. Riprova tra qualche minuto."
            case 503:
                return "Servizio SMS temporaneamente non disponibile. Riprova più tardi."
            default:
                return "Errore del server (\(statusCode))."
            }
        }
        return error.localizedDescription
    }
}
