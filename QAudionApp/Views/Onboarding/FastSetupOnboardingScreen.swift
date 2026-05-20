import SwiftUI
import AVFoundation
import PhotosUI
import Vision

/// Fast-setup onboarding (QR scan → automatic login).
///
/// Replicates `qaudion-android-new/feature/feature-auth/ui/FastSetupScreen.kt`:
///   1. Auto-prompt camera permission on first appearance.
///   2. Open the camera scanner immediately after the user grants
///      permission (no extra "Tap to scan" button).
///   3. On detection, parse the raw QR string as `FastSetupPayload`
///      (Android JSON shape).
///   4. Validate `kind == "bcrypto-fast-setup"` AND `version == 1` AND
///      `payload.server` matches `PinnedServerHost` — abort with an
///      explicit error otherwise (security: prevents redirect attacks).
///   5. Hand the validated payload to `FastSetupAuth.run(...)` which
///      performs the login + profile-push and flips
///      `appState.isAuthenticated` to true.
///   6. Show "Accesso in corso…" while the login round-trip is in
///      flight, surface any error inline with a "Riprova scansione"
///      button, and dismiss back to onboarding root on success (parent
///      ContentView routes to HomeView automatically when isAuthenticated
///      flips).
///
/// In addition to the live-camera path, a **"Carica immagine QR"** button
/// lets the user pick a screenshot or photo from their library. The QR is
/// decoded offline via `Vision.VNDetectBarcodesRequest` (no network, same
/// payload-validation path as the camera).  Mirrors the Desktop
/// `Onboarding.svelte` "Carica immagine QR" button (jsQR equivalent).
struct FastSetupOnboardingScreen: View {

    let appState: AppState
    let onCancel: () -> Void

    @State private var phase: Phase = .scanning
    @State private var lastError: String?
    /// Bound to `PhotosPicker`; set to nil after each use so the same image
    /// can be re-selected if needed.
    @State private var selectedPhotoItem: PhotosPickerItem?
    /// True while Vision is decoding the picked image (shows a spinner label).
    @State private var isDecodingPhoto = false

    private enum Phase: Equatable {
        case scanning           // camera open
        case loggingIn          // payload validated, login in flight
        case errorPending       // payload accepted but login returned error
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                // Top meta strap
                Text("Q-AUDION · FAST SETUP")
                    .font(.caption.weight(.medium))
                    .tracking(2.5)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 24)

                Spacer().frame(height: 12)

                Text("Configurazione rapida")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Scansiona il QR generato dal pannello admin del server. " +
                     "Il server nel QR viene verificato rispetto a \(PinnedServerHost.host) " +
                     "prima dell'accesso.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 8)

                switch phase {
                case .scanning:
                    // Camera scanner fills remaining space; photo-import button
                    // is overlaid at the bottom so the viewfinder stays full-size.
                    ZStack(alignment: .bottom) {
                        QrScannerView(
                            onScanned: handleScannedString,
                            onCancel: onCancel
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        photoImportButton
                            .padding(.bottom, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .loggingIn:
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                    Text("Accesso in corso…")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()

                case .errorPending:
                    errorView
                    Spacer()
                }

                if phase != .scanning {
                    Button(action: onCancel) {
                        Text("Annulla")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .disabled(phase == .loggingIn)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    @ViewBuilder
    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text(lastError ?? "Errore sconosciuto")
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                lastError = nil
                phase = .scanning
            } label: {
                Text("Riprova scansione")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(.black)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Photo import (QR from library)

    /// "Carica immagine QR" button — mirrors Desktop `Onboarding.svelte`.
    /// Uses `PhotosPicker` (PhotosUI, iOS 16+) so the app never needs the
    /// full photo-library `NSPhotoLibraryUsageDescription`; iOS shows a
    /// limited-selection picker that only requests access to the chosen image.
    @ViewBuilder
    private var photoImportButton: some View {
        PhotosPicker(
            selection: $selectedPhotoItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label(
                isDecodingPhoto ? "Analisi in corso…" : "Carica immagine QR",
                systemImage: isDecodingPhoto ? "hourglass" : "photo.on.rectangle.angled"
            )
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.white)
            .background(.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            )
        }
        .disabled(isDecodingPhoto)
        .padding(.horizontal, 24)
        // iOS 16-compatible single-arg onChange (deprecated in 17 but still supported)
        .onChange(of: selectedPhotoItem) { newItem in
            guard let newItem else { return }
            Task { await decodeQrFromPhoto(newItem) }
        }
    }

    /// Decode a QR code from a photo picked via `PhotosPicker`.
    /// Uses `Vision.VNDetectBarcodesRequest` (offline, no network).
    /// On success calls `handleScannedString` — identical path to camera.
    private func decodeQrFromPhoto(_ item: PhotosPickerItem) async {
        isDecodingPhoto = true
        defer {
            isDecodingPhoto = false
            // Reset so the same image can be re-picked if needed.
            selectedPhotoItem = nil
        }

        // 1. Load raw image data from the picker item.
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data),
              let ciImage = CIImage(image: uiImage) else {
            await MainActor.run {
                lastError = "Impossibile caricare l'immagine selezionata."
                phase = .errorPending
            }
            return
        }

        // 2. Run Vision QR detector (synchronous on current task).
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            await MainActor.run {
                lastError = "Errore analisi immagine: \(error.localizedDescription)"
                phase = .errorPending
            }
            return
        }

        guard let observation = request.results?.first as? VNBarcodeObservation,
              let payload = observation.payloadStringValue else {
            await MainActor.run {
                lastError = "Nessun QR trovato nell'immagine. Assicurati che il " +
                            "codice QR sia visibile e ben a fuoco."
                phase = .errorPending
            }
            return
        }

        // 3. Hand off to the same validation + login path as the camera.
        await MainActor.run { handleScannedString(payload) }
    }

    // MARK: - Scan handler

    private func handleScannedString(_ raw: String) {
        // Step 1: parse + validate kind/version
        let payload: FastSetupPayload
        do {
            payload = try FastSetupPayload.decode(jsonString: raw)
        } catch {
            lastError = error.localizedDescription
            phase = .errorPending
            return
        }

        // Step 2: server pinning check (W413 multi-stage acceptance —
        // hostname OR known IP allowlist OR DNS-resolved IP intersection
        // with canonical hostname).
        guard PinnedServerHost.accepts(payload.server) else {
            lastError = "Il server nel QR (\(payload.server)) non risulta tra " +
                "gli indirizzi noti per \(PinnedServerHost.host) " +
                "(controllo DNS + allowlist). Verifica che il QR sia " +
                "stato emesso dal server di produzione e riprova; se il " +
                "problema persiste contatta l'amministratore."
            phase = .errorPending
            return
        }

        // Step 3: hand off to login orchestrator
        phase = .loggingIn
        Task {
            let err = await FastSetupAuth(appState: appState).run(payload)
            await MainActor.run {
                if let err {
                    lastError = err
                    phase = .errorPending
                }
                // On success, appState.isAuthenticated = true → ContentView
                // re-evaluates and routes to HomeView. Nothing else to do
                // here; the screen will just be replaced.
            }
        }
    }
}
