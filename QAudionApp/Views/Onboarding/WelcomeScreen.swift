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
    /// For users who cannot present a QR image.
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
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    Spacer().frame(height: 56)

                    Text("Benvenuto a Q-Audion.")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(scheme.onBackground)
                        .lineLimit(2)
                        // A word never runs past the edge: on a narrow cover display or at a large text size the
                        // headline shrinks (down to half) and wraps instead.
                        .minimumScaleFactor(0.5)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer().frame(height: 12)

                    Text("La voce è la tua chiave.")
                        .qaudionStyle(type.titleMedium)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer().frame(height: 32)

                    // Feature pills (PQC accent token from extras)
                    AnyLayout(FeatureFlowLayout(spacing: 8)) {
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
                            label: "Registrati con interno e email (senza numero)",
                            variant: .text
                        )
                        QAudionButton(
                            action: onStartRecoveryRestore,
                            label: "Ho già una frase di recupero",
                            variant: .text
                        )
                    }

                    Spacer().frame(height: 12)

                    // App Store 5.1.1(i) — privacy policy reachable before
                    // any account is created, not only from Settings.
                    Button {
                        LegalLinks.open(LegalLinks.privacyPolicy())
                    } label: {
                        Text("Continuando accetti l'Informativa privacy")
                            .qaudionStyle(type.labelSmall)
                            .underline()
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Spacer().frame(height: 12)

                    Text("Hybrid PQC · Voice-first · Deepfake Guard")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.5)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer().frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                // The column keeps a readable width on the large inner display of a foldable iPhone and on tablets, and
                // takes exactly the width it is given on a phone: the content never has a width of its own.
                .qaudionReadableWidth()
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

/// Places the feature pills in rows: a pill that does not fit on the current row
/// moves to the next one. A pill is never split (see `FeaturePill`), so the text of
/// a token like "ML-KEM 1024" keeps its line at every text size.
private struct FeatureFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                widest = max(widest, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widest, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
            .fixedSize(horizontal: true, vertical: false)
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
