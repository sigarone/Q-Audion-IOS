import SwiftUI

/// Manual-entry login for a Fast Setup account: PBX extension number +
/// password, instead of scanning/uploading the QR image. Added so App
/// Store / Google Play reviewers (and anyone else without the QR) can log
/// into a Fast Setup account by typing two short values.
///
/// Server-side restricted to Fast Setup accounts (`POST
/// /api/v1/auth/login/extension`) — an ordinary phone-registered account
/// cannot use this path. Wrong extension, wrong password, and "extension
/// belongs to a non-Fast-Setup account" all return the same generic error,
/// so this screen never distinguishes them either.
struct ExtensionLoginScreen: View {
    let appState: AppState
    let onBack: () -> Void
    let onLoggedIn: () -> Void

    @State private var extensionText: String = ""
    @State private var password: String = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    private var extensionValue: Int64? {
        Int64(extensionText.trimmingCharacters(in: .whitespaces))
    }

    private var canSubmit: Bool {
        guard let ext = extensionValue, ext > 0 else { return false }
        return !password.isEmpty
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
                        Text("Accedi con estensione")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer().frame(height: 16)

                    Text("Accedi con estensione e password")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)

                    Spacer().frame(height: 8)

                    Text("Solo per account configurati con Configurazione rapida (QR). Se non hai un interno e una password assegnati, usa la scansione del QR o un'altra modalità di accesso.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 24)

                    Spacer().frame(height: 24)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Interno")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                        TextField("es. 176", text: $extensionText)
                            .keyboardType(.numberPad)
                            .textContentType(.username)
                            .accessibilityIdentifier("extension-login-ext-field")
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
                        Text("Password")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("extension-login-password-field")
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
                        Text(isSubmitting ? "Accesso in corso…" : "Accedi")
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
            }
        }
    }

    private func submit() async {
        guard let ext = extensionValue else { return }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        appState.errorMessage = nil
        await appState.loginWithExtension(extension: ext, credential: password)
        if let err = appState.errorMessage {
            errorText = err
            return
        }
        onLoggedIn()
    }
}
