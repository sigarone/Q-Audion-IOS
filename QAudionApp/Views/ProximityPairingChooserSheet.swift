import SwiftUI
import QAudionEngine

/// Entry of in-person pairing (Contatti → Associa di persona): the person says
/// whether this phone shows its code or scans the other phone's. Both ways
/// then run in this sheet's own navigation stack — `ProximityPairingDisplayScreen`
/// and `ProximityPairingScanScreen` — and a finished pairing is reported to the
/// caller, which closes the sheet. Protocol: docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md.
///
/// Primitives and closures only — never AppState (CLAUDE.md §16).
struct ProximityPairingChooserSheet: View {
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
    @State private var showingCode = false
    @State private var scanningCode = false

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
        .onAppear {
            ProximityEntryPointHint.markSeen()
            if ProximityHowItWorks.presentOnFirstUse {
                ProximityHowItWorks.markSeen()
                showingHowItWorksAuto = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let userId = localUserId, !userId.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    ChooserCard(systemImage: "qrcode",
                                title: "Mostra il mio codice",
                                hint: "L'altra persona inquadra il codice con il suo telefono.") {
                        showingCode = true
                    }
                    ChooserCard(systemImage: "qrcode.viewfinder",
                                title: "Scansiona un codice",
                                hint: "Inquadra il codice mostrato sull'altro telefono.") {
                        scanningCode = true
                    }
                }
                .padding(20)
            }
            .navigationDestination(isPresented: $showingCode) {
                ProximityPairingDisplayScreen(localUserId: userId,
                                              serverIdentityKeys: serverIdentityKeys,
                                              onCompleted: onCompleted,
                                              onTelemetryEvent: onTelemetryEvent)
            }
            .navigationDestination(isPresented: $scanningCode) {
                ProximityPairingScanScreen(localUserId: userId,
                                           serverIdentityKeys: serverIdentityKeys,
                                           onCompleted: onCompleted,
                                           onTelemetryEvent: onTelemetryEvent)
            }
        } else {
            ProximityPairingUnavailableView()
        }
    }
}

/// One of the two ways to start: an icon, what it does, and a one-line hint.
private struct ChooserCard: View {
    let systemImage: String
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}
