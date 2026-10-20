import SwiftUI
import QAudionEngine

/// In-person pairing, displayer side: shows the rotating QR while the phone
/// advertises over Bluetooth; the other phone scans it from Contatti →
/// Associa di persona → Scansiona un codice. A screen of the chooser's
/// navigation stack (`ProximityPairingChooserSheet`), which owns the close
/// button and the first-use explanation. Protocol:
/// docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md.
///
/// Primitives and closures only — never AppState (CLAUDE.md §16).
struct ProximityPairingDisplayScreen: View {
    let localUserId: String
    /// Published identity keys of an account (`ContactsListContainer.publishedIdentityKeys`).
    let serverIdentityKeys: ((String) async -> Set<Data>)?
    let onCompleted: (ProximityPairingSummary) -> Void
    /// Privacy-safe lifecycle telemetry — see `ProximityPairingTelemetry`.
    var onTelemetryEvent: ((ProximityPairingTelemetryEvent) -> Void)? = ProximityPairingTelemetry.emit

    var body: some View {
        ProximityPairingDisplayerView(
            localUserId: localUserId,
            displayName: ProximityPairingNames.resolve,
            serverIdentityKeys: serverIdentityKeys,
            onCompleted: onCompleted,
            onTelemetryEvent: onTelemetryEvent
        )
        .navigationTitle("Mostra il mio codice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ProximityHowItWorksButton()
            }
        }
        // Defense in depth only. `ScreenshotLockService` blanks its own secure
        // layer in a capture, not a sibling view like the QR, so the real
        // protection is in the engine driver: the code is hidden and the
        // session stopped while the screen is recorded, mirrored or shared,
        // and a screenshot replaces the session (spec §6).
        .onAppear { ScreenshotLockService.lock() }
        .onDisappear { ScreenshotLockService.unlock() }
    }
}

/// In-person pairing, scanner side, entered from the chooser: the camera,
/// restricted to pairing codes. A valid code goes straight to the Bluetooth
/// exchange; any other text says why it was not accepted and offers another
/// try. Hosted in the chooser's `NavigationStack`, like the displayer screen.
struct ProximityPairingScanScreen: View {
    let localUserId: String
    let serverIdentityKeys: ((String) async -> Set<Data>)?
    let onCompleted: (ProximityPairingSummary) -> Void
    /// Privacy-safe lifecycle telemetry — see `ProximityPairingTelemetry`.
    var onTelemetryEvent: ((ProximityPairingTelemetryEvent) -> Void)? = ProximityPairingTelemetry.emit

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .scanning

    private enum Phase {
        case scanning
        case pairing(ProximityQrPayload)
        /// The text was not accepted; the sentence says why.
        case rejected(String)
    }

    private var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var body: some View {
        Group {
            switch phase {
            case .scanning:
                QrScannerView(
                    onScanned: { raw in handleScanned(raw) },
                    onCancel: { dismiss() },
                    hint: "Inquadra il codice mostrato sull'altro telefono."
                )
            case .pairing(let payload):
                ProximityPairingScanContent(payload: payload,
                                            localUserId: localUserId,
                                            serverIdentityKeys: serverIdentityKeys,
                                            onCompleted: onCompleted,
                                            onRescan: { phase = .scanning },
                                            onTelemetryEvent: onTelemetryEvent)
            case .rejected(let message):
                ProximityPairingInvalidCodeView(message: message, onScanAgain: { phase = .scanning })
            }
        }
        .navigationTitle("Scansiona un codice")
        .navigationBarTitleDisplayMode(.inline)
        // The camera fills the screen and brings its own close button.
        .toolbar(isScanning ? .hidden : .visible, for: .navigationBar)
        // The one-time Bluetooth prompt is answered while the camera is still
        // framing the code: answered after the scan, it would count against
        // the code's 8 s window and the very first pairing would expire.
        .onAppear { ProximityBluetoothPermission.requestIfNeeded() }
    }

    private func handleScanned(_ raw: String) {
        switch ProximityScanOutcome.classify(raw) {
        case .pairing(let payload):
            phase = .pairing(payload)
        case .notPairing:
            ProximityScanReport.notPairing(textLength: raw.utf16.count)
            phase = .rejected(ProximityScanMessages.notPairing)
        case .invalid(let reason):
            ProximityScanReport.invalid(reason, textLength: raw.utf16.count)
            phase = .rejected(ProximityScanMessages.invalid)
        }
    }
}

/// Scanner side, hosted by `QrScannerSheet` and by `ProximityPairingScanScreen`
/// once they have a valid `qaudion://pair/` code.
struct ProximityPairingScanContent: View {
    let payload: ProximityQrPayload
    let localUserId: String?
    let serverIdentityKeys: ((String) async -> Set<Data>)?
    let onCompleted: (ProximityPairingSummary) -> Void
    let onRescan: () -> Void
    /// Privacy-safe lifecycle telemetry — see `ProximityPairingTelemetry`.
    var onTelemetryEvent: ((ProximityPairingTelemetryEvent) -> Void)? = ProximityPairingTelemetry.emit

    /// W-PAIRFB — shown once, automatically, the first time ANY pairing
    /// screen appears (`ProximityHowItWorks.presentOnFirstUse`); reachable
    /// again any time via the toolbar info button. This screen is hosted
    /// inside its parent's `NavigationStack`, so only the toolbar item +
    /// auto-presented sheet are added here; the title/cancel button stay
    /// owned by the parent.
    @State private var showingHowItWorksAuto = false

    var body: some View {
        Group {
            if let userId = localUserId, !userId.isEmpty {
                ProximityPairingScannerView(
                    payload: payload,
                    localUserId: userId,
                    displayName: ProximityPairingNames.resolve,
                    serverIdentityKeys: serverIdentityKeys,
                    onCompleted: onCompleted,
                    onRescan: onRescan,
                    onTelemetryEvent: onTelemetryEvent
                )
            } else {
                ProximityPairingUnavailableView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ProximityHowItWorksButton()
            }
        }
        .sheet(isPresented: $showingHowItWorksAuto) {
            ProximityHowItWorksSheet()
        }
        .onAppear {
            ProximityEntryPointHint.markSeen()
            if ProximityHowItWorks.presentOnFirstUse {
                ProximityHowItWorks.markSeen()
                showingHowItWorksAuto = true
            }
        }
    }
}

/// A scanned text that is not a usable pairing code: another kind of QR, or a
/// `qaudion://pair/` code that did not pass strict decoding.
struct ProximityPairingInvalidCodeView: View {
    let message: String
    let onScanAgain: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(action: onScanAgain) {
                Label("Scansiona di nuovo", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct ProximityPairingUnavailableView: View {
    var body: some View {
        Text(ProximityPairingError.identityUnavailable.userMessage)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding()
    }
}

/// `DisplayName.forUser` has defaulted parameters, so it cannot be passed
/// where a plain `(String) -> String` is expected.
enum ProximityPairingNames {
    static func resolve(_ userId: String) -> String {
        return DisplayName.forUser(userId)
    }
}
