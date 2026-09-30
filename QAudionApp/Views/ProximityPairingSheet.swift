import SwiftUI
import QAudionEngine

/// In-person pairing, displayer side: shows the rotating QR while the phone
/// advertises over Bluetooth; the other phone scans it from Contatti →
/// Aggiungi contatto → Scansiona QR. Protocol: docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md.
///
/// Primitives and closures only — never AppState (CLAUDE.md §16).
struct ProximityPairingDisplaySheet: View {
    let localUserId: String?
    /// Published identity keys of an account (`ContactsListContainer.publishedIdentityKeys`).
    let serverIdentityKeys: ((String) async -> Set<Data>)?
    let onCompleted: (ProximityPairingSummary) -> Void
    /// Privacy-safe lifecycle telemetry — see `ProximityPairingTelemetry`.
    var onTelemetryEvent: ((ProximityPairingTelemetryEvent) -> Void)? = ProximityPairingTelemetry.emit

    @Environment(\.dismiss) private var dismiss
    /// W-PAIRFB — shown once, automatically, the first time ANY pairing
    /// screen appears (`ProximityHowItWorks.presentOnFirstUse`); reachable
    /// again any time via the toolbar info button.
    @State private var showingHowItWorksAuto = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Associa di persona")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Chiudi") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ProximityHowItWorksButton()
                    }
                }
                .sheet(isPresented: $showingHowItWorksAuto) {
                    ProximityHowItWorksSheet()
                }
        }
        // Defense in depth only. `ScreenshotLockService` blanks its own secure
        // layer in a capture, not a sibling view like the QR, so the real
        // protection is in the engine driver: the code is hidden and the
        // session stopped while the screen is recorded, mirrored or shared,
        // and a screenshot replaces the session (spec §6).
        .onAppear {
            ScreenshotLockService.lock()
            ProximityEntryPointHint.markSeen()
            if ProximityHowItWorks.presentOnFirstUse {
                ProximityHowItWorks.markSeen()
                showingHowItWorksAuto = true
            }
        }
        .onDisappear { ScreenshotLockService.unlock() }
    }

    @ViewBuilder
    private var content: some View {
        if let userId = localUserId, !userId.isEmpty {
            ProximityPairingDisplayerView(
                localUserId: userId,
                displayName: ProximityPairingNames.resolve,
                serverIdentityKeys: serverIdentityKeys,
                onCompleted: onCompleted,
                onTelemetryEvent: onTelemetryEvent
            )
        } else {
            ProximityPairingUnavailableView()
        }
    }
}

/// Scanner side, hosted by `QrScannerSheet` once it recognises a
/// `qaudion://pair/` code.
struct ProximityPairingScanContent: View {
    let payload: ProximityQrPayload
    let localUserId: String?
    let serverIdentityKeys: ((String) async -> Set<Data>)?
    let onCompleted: (ProximityPairingSummary) -> Void
    let onRescan: () -> Void
    /// Privacy-safe lifecycle telemetry — see `ProximityPairingTelemetry`.
    var onTelemetryEvent: ((ProximityPairingTelemetryEvent) -> Void)? = ProximityPairingTelemetry.emit

    /// W-PAIRFB — see `ProximityPairingDisplaySheet`'s twin state var. This
    /// screen is hosted inside `QrScannerSheet`'s own `NavigationStack`, so
    /// only the toolbar item + auto-presented sheet are added here; the
    /// title/cancel button stay owned by the parent.
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

/// A scanned `qaudion://pair/` code that did not pass strict decoding.
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

private struct ProximityPairingUnavailableView: View {
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
