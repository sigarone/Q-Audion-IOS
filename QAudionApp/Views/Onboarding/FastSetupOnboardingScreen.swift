import SwiftUI
import AVFoundation

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
struct FastSetupOnboardingScreen: View {

    let appState: AppState
    let onCancel: () -> Void

    @State private var phase: Phase = .scanning
    @State private var lastError: String?

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
                    QrScannerView(
                        onScanned: handleScannedString,
                        onCancel: onCancel
                    )
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
