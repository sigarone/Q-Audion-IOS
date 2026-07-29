import SwiftUI

/// Phone-entry screen — visual replica of Android
/// `qaudion-android-new/feature/feature-auth/ui/PhoneEntryScreen.kt`.
///
/// 2026-07-29: the server now has a real SMS-OTP register/login flow
/// (`POST /api/v1/auth/otp/request` + `/otp/verify`). This screen collects
/// + validates the phone number (unchanged) and, for `.register`, an
/// optional invite code; `OnboardingRoot` routes `onContinue`'s output to
/// `OtpVerificationScreen`, which requests the code and completes the
/// register/login itself. This screen stays a pure input screen — it does
/// not touch the network.
struct PhoneEntryScreen: View {

    enum Mode: String {
        case register
        case login

        var title: String {
            switch self {
            case .register: return "Crea un account"
            case .login: return "Accedi"
            }
        }

        var ctaLabel: String {
            switch self {
            case .register: return "Continua con la registrazione"
            case .login: return "Continua con l'accesso"
            }
        }
    }

    let mode: Mode
    let onBack: () -> Void
    /// Receives `(phoneHash, e164, inviteCode)` once the user submits a
    /// valid number. `inviteCode` is always nil for `.login`; for
    /// `.register` it's nil unless the user typed one. `OnboardingRoot`
    /// routes this to `OtpVerificationScreen` to request + verify the SMS
    /// code and complete registration/login.
    let onContinue: (_ phoneHash: String, _ e164: String, _ inviteCode: String?) -> Void

    @State private var raw: String = "+39 "
    @State private var inviteCode: String = ""
    @State private var validationError: String?
    // W315 — track last submit attempt to give the user feedback that
    // their tap was registered (server flow is stubbed today).
    @State private var lastAttemptAt: Date? = nil

    // W315 — formatter pre-built once. Avoids multi-segment interpolation
    // in body per SWIFT6_PATTERNS.md §1.
    private static let attemptFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "it_IT")
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    private static func formatLastAttempt(_ date: Date) -> String {
        let stamp: String = attemptFormatter.string(from: date)
        return "Ultimo tentativo: " + stamp
    }

    private var isValid: Bool {
        PhoneHashHelper.isValid(raw)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {

                // Custom top bar
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    Text(mode.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer().frame(height: 16)

                Text("Inserisci il tuo numero")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)

                Spacer().frame(height: 8)

                Text("Lo useremo solo per identificare l'account: non lo mostreremo mai ad altri utenti.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 24)

                Spacer().frame(height: 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Numero di telefono")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                    TextField("+39 333 1234567", text: $raw)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(validationError != nil ? Color.red : .white.opacity(0.3),
                                        lineWidth: 1.2)
                        )
                        .onChange(of: raw) { _ in
                            validationError = nil
                        }
                    if let err = validationError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Formato E.164: deve iniziare con + e il prefisso paese.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 24)

                if mode == .register {
                    Spacer().frame(height: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Codice invito (opzionale)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                        TextField("Codice invito", text: $inviteCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.white.opacity(0.3), lineWidth: 1.2)
                            )
                    }
                    .padding(.horizontal, 24)
                }

                Spacer().frame(height: 32)

                Button {
                    submit()
                } label: {
                    Text(mode.ctaLabel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(isValid ? .black : .white.opacity(0.4))
                        .background(isValid ? Color.white : Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!isValid)
                .padding(.horizontal, 24)

                // W315 — last-attempt timestamp (helps testers verify the
                // tap landed even though server OTP isn't wired).
                if let last = lastAttemptAt {
                    Text(Self.formatLastAttempt(last))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }

                Spacer().frame(height: 16)

                // Info banner — explains what happens next (SMS code),
                // not a "not implemented yet" disclaimer anymore.
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "message.fill")
                        .foregroundStyle(.blue)
                    Text("Ti invieremo un codice via SMS per verificare questo numero.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.05))
                )
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }

    private func submit() {
        // W315 — record attempt so the user sees visible feedback that
        // their tap registered before the OTP screen's own network call
        // resolves.
        lastAttemptAt = Date()
        do {
            let e164 = try PhoneHashHelper.normalizeE164(raw)
            let hash = PhoneHashHelper.sha256Hex(e164)
            let trimmedInvite = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let invite: String? = (mode == .register && !trimmedInvite.isEmpty) ? trimmedInvite : nil
            onContinue(hash, e164, invite)
        } catch {
            validationError = error.localizedDescription
        }
    }
}

#Preview {
    PhoneEntryScreen(mode: .register, onBack: {}, onContinue: { _, _, _ in })
}
