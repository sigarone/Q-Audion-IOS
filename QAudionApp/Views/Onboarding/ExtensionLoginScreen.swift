import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Typed login: PBX extension number + password, for accounts an
/// administrator created for the user.
///
/// "Fill in from a photo or file" only copies the two values into the fields
/// (read on the device, nothing is uploaded); the user then taps "Accedi".
///
/// Server-side restricted to administrator-created accounts (`POST
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

    @State private var showSourceDialog = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isReading = false
    @State private var fillMessage: String?

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

                    Text(String(localized: "extension_login.helper", defaultValue: "Per gli account creati per te dall'amministratore della tua organizzazione. Inserisci l'interno e la password che hai ricevuto.", comment: "Extension + password sign-in screen: who this sign-in is for."))
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

                    fillButton
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    if let msg = fillMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                    }

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
                        Text(isSubmitting ? String(localized: "Accesso in corso…") : String(localized: "onboarding.action.login", defaultValue: "Accedi", comment: "Sign-in button / screen title in onboarding."))
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
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onCapture: { data in
                    showCamera = false
                    Task { await fill(from: await CredentialImageReader.read(imageData: data)) }
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            photoItem = nil
            Task { await fill(fromPhoto: item) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image, .pdf, .plainText],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await fill(fromFile: url) }
        }
    }

    // MARK: - Fill in from a photo or file

    private var fillButton: some View {
        Button {
            showSourceDialog = true
        } label: {
            Label(
                isReading
                    ? String(localized: "extension_login.fill.reading", defaultValue: "Lettura in corso…", comment: "Extension + password sign-in screen: label of the fill-in button while a photo or file is being read.")
                    : String(localized: "extension_login.fill.button", defaultValue: "Compila da foto o file", comment: "Extension + password sign-in screen: button that fills the extension and password fields from a photo or a file."),
                systemImage: isReading ? "hourglass" : "doc.text.viewfinder"
            )
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.3), lineWidth: 1.2)
            )
        }
        .disabled(isReading || isSubmitting)
        .accessibilityIdentifier("extension-login-fill-button")
        .confirmationDialog(
            String(localized: "extension_login.fill.button", defaultValue: "Compila da foto o file", comment: "Extension + password sign-in screen: button that fills the extension and password fields from a photo or a file."),
            isPresented: $showSourceDialog,
            titleVisibility: .hidden
        ) {
            Button(String(localized: "extension_login.fill.camera", defaultValue: "Scatta una foto", comment: "Extension + password sign-in screen, fill-in options: take a photo with the camera.")) {
                showCamera = true
            }
            Button(String(localized: "extension_login.fill.library", defaultValue: "Scegli dalla libreria foto", comment: "Extension + password sign-in screen, fill-in options: choose an image from the photo library.")) {
                showPhotoPicker = true
            }
            Button(String(localized: "extension_login.fill.file", defaultValue: "Scegli un file", comment: "Extension + password sign-in screen, fill-in options: choose an image, PDF or text file.")) {
                showFileImporter = true
            }
            Button("Annulla", role: .cancel) {}
        }
    }

    @MainActor
    private func fill(fromPhoto item: PhotosPickerItem) async {
        isReading = true
        fillMessage = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            isReading = false
            fillMessage = String(localized: "extension_login.fill.error_load", defaultValue: "Impossibile leggere il file scelto.", comment: "Extension + password sign-in screen: the chosen photo or file could not be read.")
            return
        }
        await fill(from: await CredentialImageReader.read(imageData: data))
    }

    @MainActor
    private func fill(fromFile url: URL) async {
        isReading = true
        fillMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await fill(from: await CredentialImageReader.read(fileURL: url))
    }

    /// Copies what was found into the two fields. Never signs in: the user taps "Accedi".
    @MainActor
    private func fill(from result: CredentialExtraction) async {
        isReading = false
        errorText = nil
        switch result {
        case .found(let creds):
            extensionText = creds.extensionNumber
            password = creds.password
            fillMessage = nil
        case .notPinned(let server):
            fillMessage = String(localized: "qr.fast_setup.error.server_not_pinned",
                                 defaultValue: "Il server nel QR (\(server)) non risulta tra gli indirizzi noti per \(PinnedServerHost.host) (controllo DNS + allowlist). Verifica che il QR sia stato emesso dal server di produzione e riprova; se il problema persiste contatta l'amministratore.",
                                 comment: "Error on the quick-setup screen: the server named in the scanned QR code is not one of the known addresses of the official server. First %@ is the server found in the QR code, second %@ is the official host name; keep 'DNS' and 'allowlist' as they are")
        case .notFound:
            fillMessage = String(localized: "extension_login.fill.not_found", defaultValue: "Non ho trovato interno e password. Inseriscili a mano.", comment: "Extension + password sign-in screen: nothing usable was found in the chosen photo or file.")
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
