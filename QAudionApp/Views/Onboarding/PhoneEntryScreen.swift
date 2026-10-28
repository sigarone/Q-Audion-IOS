import SwiftUI
import QAudionEngine

/// Phone-entry screen — visual replica of Android
/// `qaudion-android-new/feature/feature-auth/ui/PhoneEntryScreen.kt`.
///
/// 2026-07-29: the server now has a real SMS-OTP register/login flow
/// (`POST /api/v1/auth/otp/request` + `/otp/verify`). This screen collects
/// + validates the phone number (unchanged) and, for `.register`, the age
/// declaration. Registration is open: no invite code is asked
/// (2026-10-27); `OnboardingRoot` routes `onContinue`'s output to
/// `OtpVerificationScreen`, which requests the code and completes the
/// register/login itself. This screen stays a pure input screen — it does
/// not touch the network.
struct PhoneEntryScreen: View {

    enum Mode: String {
        case register
        case login

        var title: String {
            switch self {
            case .register: return String(localized: "onboarding.phone.title_register", defaultValue: "Crea un account", comment: "Title of the phone number screen when the user is creating a new account.")
            case .login: return String(localized: "onboarding.action.login", defaultValue: "Accedi", comment: "Sign-in button / screen title in onboarding.")
            }
        }

        var ctaLabel: String {
            switch self {
            case .register: return String(localized: "onboarding.phone.cta_register", defaultValue: "Continua con la registrazione", comment: "Main button of the phone number screen in registration mode.")
            case .login: return String(localized: "onboarding.phone.cta_login", defaultValue: "Continua con l'accesso", comment: "Main button of the phone number screen in sign-in mode.")
            }
        }
    }

    let mode: Mode
    let onBack: () -> Void
    /// Receives `(phoneHash, e164, ageDeclared, termsAcceptance)` once the user
    /// submits a valid number. `ageDeclared` is true
    /// only for `.register` with the age declaration box ticked, and false
    /// for `.login`. `termsAcceptance` is what the person accepted on the acceptance screen that
    /// come before a registration, and nil for `.login`. `OnboardingRoot` routes this to
    /// `OtpVerificationScreen` to request + verify the SMS code and complete registration/login.
    let onContinue: (_ phoneHash: String, _ e164: String, _ ageDeclared: Bool, _ termsAcceptance: TermsAcceptance?) -> Void

    /// The number checked at submit, held while the acceptance screen is up.
    private struct PendingNumber {
        let hash: String
        let e164: String
    }

    @State private var raw: String = "+39 "
    @State private var ageDeclared = false
    @State private var showingTerms = false
    @State private var pendingNumber: PendingNumber?
    @State private var acceptedTerms: TermsAcceptance?
    @State private var validationError: String?
    // W315 — track last submit attempt to give the user feedback that
    // their tap was registered (server flow is stubbed today).
    @State private var lastAttemptAt: Date? = nil

    // W315 — formatter pre-built once. Avoids multi-segment interpolation
    // in body per SWIFT6_PATTERNS.md §1.
    private static let attemptFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: AppLanguageManager.effectiveLanguageCode)
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    private static func formatLastAttempt(_ date: Date) -> String {
        let stamp: String = attemptFormatter.string(from: date)
        return String(localized: "onboarding.phone.last_attempt", defaultValue: "Ultimo tentativo: \(stamp)", comment: "Small caption on the phone number screen after an attempt; %@ is the time of day (HH:mm:ss).")
    }

    /// Registration needs the age declaration box ticked, so the button stays off
    /// until it is; login does not show the box and never needs it.
    static func ageOk(mode: Mode, ageDeclared: Bool) -> Bool {
        mode != .register || ageDeclared
    }

    /// The `ageDeclared` handed to the OTP step: true only for `.register` with the
    /// box ticked. A login never carries the declaration.
    static func ageWireValue(mode: Mode, ageDeclared: Bool) -> Bool {
        mode == .register && ageDeclared
    }

    /// The whole gate of the submit button without the view: the number has to be
    /// valid, and for `.register` the age box as well.
    static func isSubmittable(phoneValid: Bool, mode: Mode, ageDeclared: Bool) -> Bool {
        phoneValid && ageOk(mode: mode, ageDeclared: ageDeclared)
    }

    private var isValid: Bool {
        Self.isSubmittable(phoneValid: PhoneHashHelper.isValid(raw), mode: mode, ageDeclared: ageDeclared)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
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
                        AgeDeclarationSection(declared: $ageDeclared)
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
                .qaudionReadableWidth()
            }
        }
        .fullScreenCover(isPresented: $showingTerms, onDismiss: {
            // Moves on only after the screen is gone, and only with a complete acceptance.
            guard let acceptance = acceptedTerms, let number = pendingNumber else { return }
            onContinue(number.hash, number.e164, true, acceptance)
        }) {
            TermsAcceptanceLoaderView(
                api: LegalService.anonymousApi(serverUrl: PinnedServerHost.url),
                onAccepted: { acceptance in
                    acceptedTerms = acceptance
                    showingTerms = false
                },
                onCancel: { showingTerms = false })
        }
    }

    private func submit() {
        // Same gate as `.disabled(!isValid)` on the button: without a valid number,
        // and (for `.register`) the ticked age box nothing may start,
        // even if the button were reachable by some other route.
        guard isValid else { return }
        // W315 — record attempt so the user sees visible feedback that
        // their tap registered before the OTP screen's own network call
        // resolves.
        lastAttemptAt = Date()
        do {
            let e164 = try PhoneHashHelper.normalizeE164(raw)
            let hash = PhoneHashHelper.sha256Hex(e164)
            if Self.ageWireValue(mode: mode, ageDeclared: ageDeclared) {
                // A registration goes through the acceptance screen before anything is requested.
                pendingNumber = PendingNumber(hash: hash, e164: e164)
                acceptedTerms = nil
                showingTerms = true
            } else {
                onContinue(hash, e164, false, nil)
            }
        } catch {
            validationError = error.localizedDescription
        }
    }
}

#Preview {
    PhoneEntryScreen(mode: .register, onBack: {}, onContinue: { _, _, _, _ in })
}
