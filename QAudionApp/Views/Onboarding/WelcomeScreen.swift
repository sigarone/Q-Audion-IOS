import SwiftUI
import PhotosUI
import Vision

/// Onboarding landing screen. Visual + copy replica of the Android
/// canonical source `qaudion-android-new/feature/feature-auth/ui/WelcomeScreen.kt`.
///
/// Dark editorial layout:
///   - top meta strap "Q-AUDION · SECURE COMMUNICATIONS"
///   - large headline "Benvenuto a Q-Audion."
///   - subtitle "La voce è la tua chiave."
///   - 3 feature pills (ML-KEM 1024 / Voice-as-Key / Deepfake Guard)
///   - CTA hierarchy:
///       1. **Primary** "Configurazione rapida (QR)" — fast-setup, the
///          zero-friction path the admin panel pushes by default
///       2. **Secondary** "Inizia con un codice invito" — SMS-OTP
///          registration (`PhoneEntryScreen` → `OtpVerificationScreen`)
///       3. **Text** "Accedi con un account esistente" — SMS-OTP login,
///          same phone-entry screen in `.login` mode
///       4. **Text** "Registrati senza numero" — extension-only
///          registration (email required, no phone at all)
///       5. **Text** "Ho già una frase di recupero" — restores an
///          existing account's session from a previously-enrolled
///          mnemonic (fresh-install recovery path)
///   - footer "Hybrid PQC · Voice-first · Deepfake Guard"
///
/// 2026-07-29: the server now has a real SMS-OTP register/login flow plus
/// extension-only registration and recovery-phrase restore — all 5 CTAs
/// above are live. (Previously only Fast Setup was wired; the other two
/// were disclaimed stubs because the server had no phone-OTP path yet.)
struct WelcomeScreen: View {

    let onStartFastSetup: () -> Void
    let onStartRegister: () -> Void
    let onStartLogin: () -> Void
    /// 2026-08-20 — manual-entry login (extension + password) for Fast
    /// Setup accounts, as an alternative to scanning/uploading the QR.
    /// Added for App Store / Google Play reviewers who cannot present a
    /// QR image.
    let onStartExtensionLogin: () -> Void
    /// 2026-07-29 — extension-only registration (no phone number, email
    /// required). Previously there was no distinct CTA for this path.
    let onStartExtensionOnlyRegister: () -> Void
    /// 2026-07-29 — restores an existing account's session from a
    /// previously-enrolled recovery mnemonic. Previously
    /// `RecoverySeedContainer(mode: .verify)` had zero call sites
    /// anywhere in the shipped app, so a fresh install had no way to
    /// actually use a saved mnemonic.
    let onStartRecoveryRestore: () -> Void
    /// W459 — mirrors Android's `onGalleryQrDecoded` callback. When
    /// non-nil a "Carica immagine QR" PhotosPicker button is shown
    /// directly on this screen (above the secondary CTA). The caller
    /// (OnboardingRoot) navigates to FastSetupOnboardingScreen with the
    /// decoded QR text so payload validation happens in one place.
    /// Nil in previews / test hosts where no gallery is wired.
    var onGalleryQrDecoded: ((String) -> Void)? = nil

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    @State private var selectedGalleryItem: PhotosPickerItem?
    @State private var galleryBusy = false
    @State private var galleryError: String?

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    Text("Q-AUDION · SECURE COMMUNICATIONS")
                        .qaudionStyle(type.labelSmall)
                        .tracking(2.5)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.top, 8)

                    Spacer().frame(height: 56)

                    Text("Benvenuto a Q-Audion.")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(scheme.onBackground)
                        .lineLimit(2)

                    Spacer().frame(height: 12)

                    Text("La voce è la tua chiave.")
                        .qaudionStyle(type.titleMedium)
                        .foregroundStyle(scheme.onSurfaceVariant)

                    Spacer().frame(height: 32)

                    // Feature pills (PQC accent token from extras)
                    HStack(spacing: 8) {
                        FeaturePill(label: "ML-KEM 1024", accent: extras.pqcAccent)
                        FeaturePill(label: "Voice-as-Key", accent: extras.pqcAccent)
                        FeaturePill(label: "Deepfake Guard", accent: extras.pqcAccent)
                    }

                    Spacer().frame(height: 32)

                    // CTAs — using the QAudionButton design-system component
                    VStack(spacing: 12) {
                        QAudionButton(
                            action: onStartFastSetup,
                            label: "Configurazione rapida (QR)",
                            variant: .primary
                        )
                        // W459 — gallery QR shortcut, shown only when
                        // OnboardingRoot wires onGalleryQrDecoded.
                        // Uses PhotosPicker (no full library permission).
                        if onGalleryQrDecoded != nil {
                            PhotosPicker(
                                selection: $selectedGalleryItem,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                Label(
                                    galleryBusy ? "Analisi in corso…" : "Carica immagine QR",
                                    systemImage: galleryBusy ? "hourglass" : "photo.on.rectangle.angled"
                                )
                                .font(.body.weight(.medium))
                                .foregroundStyle(extras.pqcAccent)
                                .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .disabled(galleryBusy)
                            .onChange(of: selectedGalleryItem) { newItem in
                                guard let newItem else { return }
                                galleryBusy = true
                                galleryError = nil
                                Task { await decodeGalleryQr(from: newItem) }
                            }
                            if let err = galleryError {
                                Text(err)
                                    .qaudionStyle(type.bodySmall)
                                    .foregroundStyle(scheme.error)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        QAudionButton(
                            action: onStartRegister,
                            label: "Inizia con un codice invito",
                            variant: .secondary
                        )
                        QAudionButton(
                            action: onStartLogin,
                            label: "Accedi con un account esistente",
                            variant: .text
                        )
                        QAudionButton(
                            action: onStartExtensionLogin,
                            label: "Accedi con estensione e password",
                            variant: .text
                        )
                        QAudionButton(
                            action: onStartExtensionOnlyRegister,
                            label: "Registrati senza numero (solo interno)",
                            variant: .text
                        )
                        QAudionButton(
                            action: onStartRecoveryRestore,
                            label: "Ho già una frase di recupero",
                            variant: .text
                        )
                    }

                    Spacer().frame(height: 24)

                    Text("Hybrid PQC · Voice-first · Deepfake Guard")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.5)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer().frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
        }
    }

    // MARK: - Gallery QR decode (Vision)

    /// Decode a QR code from a photo selected via PhotosPicker.
    /// Mirrors `FastSetupOnboardingScreen.decodeQrFromPhoto(_:)`.
    /// Uses Vision's `VNDetectBarcodesRequest` — offline, no network.
    private func decodeGalleryQr(from item: PhotosPickerItem) async {
        defer {
            galleryBusy = false
            selectedGalleryItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data),
              let ciImage = CIImage(image: uiImage) else {
            galleryError = "Impossibile caricare l'immagine selezionata."
            return
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            galleryError = "Errore analisi immagine: \(error.localizedDescription)"
            return
        }
        guard let observation = request.results?.first as? VNBarcodeObservation,
              let payload = observation.payloadStringValue else {
            galleryError = "Nessun QR trovato nell'immagine. Assicurati che il codice QR sia visibile e ben a fuoco."
            return
        }
        onGalleryQrDecoded?(payload)
    }
}

/// Feature pill rendered with the design-system `pqcAccent` color (no
/// more hardcoded `Color(red: 0.40, green: 0.80, blue: 1.0)`). 12% fill
/// + full-color label matches Android's `extras.pqcAccent.copy(alpha=0.12f)`.
private struct FeaturePill: View {
    @Environment(\.qaudionType) private var type
    let label: String
    let accent: Color

    var body: some View {
        Text(label)
            .qaudionStyle(type.labelSmall)
            .tracking(1.0)
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.12)))
    }
}

#Preview {
    WelcomeScreen(
        onStartFastSetup: {},
        onStartRegister: {},
        onStartLogin: {},
        onStartExtensionLogin: {},
        onStartExtensionOnlyRegister: {},
        onStartRecoveryRestore: {}
    )
}
