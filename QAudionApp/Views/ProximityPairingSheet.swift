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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Associa di persona")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Chiudi") { dismiss() }
                    }
                }
        }
        // The rotating code is only meant for the phone physically in front of
        // this one: keep it out of screenshots, recordings and AirPlay mirrors.
        .onAppear { ScreenshotLockService.lock() }
        .onDisappear { ScreenshotLockService.unlock() }
    }

    @ViewBuilder
    private var content: some View {
        if let userId = localUserId, !userId.isEmpty {
            ProximityPairingDisplayerView(
                localUserId: userId,
                displayName: ProximityPairingNames.resolve,
                serverIdentityKeys: serverIdentityKeys,
                onCompleted: onCompleted
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

    var body: some View {
        if let userId = localUserId, !userId.isEmpty {
            ProximityPairingScannerView(
                payload: payload,
                localUserId: userId,
                displayName: ProximityPairingNames.resolve,
                serverIdentityKeys: serverIdentityKeys,
                onCompleted: onCompleted,
                onRescan: onRescan
            )
        } else {
            ProximityPairingUnavailableView()
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
