import SwiftUI
import CryptoKit
import QAudionEngine

// MARK: - Container

@MainActor
final class SecurityDashboardContainer: ObservableObject {
    @Published private(set) var viewModel: SecurityDashboardViewModel
    @Published var errorMessage: String?

    /// Internal-scope so sibling views in the Settings stack (W16.B
    /// `ThreatReportListView`) can re-use the same AppState reference
    /// without forcing the caller to pass it down twice. The container
    /// already owns the AppState so re-exposing it adds no new authority.
    let appState: AppState

    init(appState: AppState, initial: SecurityDashboardViewModel = .mock) {
        self.appState = appState
        self.viewModel = initial
        loadLocalState()
    }

    func loadLocalState() {
        // Derive a stable display pubkey from the user id (SHA-256 of userId bytes).
        // This is a placeholder until SovereignKeyVault exposes a public API.
        // NOTE: Not cryptographic — display purposes only.
        let pubkey = deriveDisplayPubkey()
        let fingerprint = (try? Fingerprint.format(pubkey: pubkey))
            ?? "????.????.????.????"

        // Pull unverifiedContacts count from local ContactsStore (W15.B).
        let storedContacts = ContactsStore().load()
        let unverifiedCount = storedContacts.filter { !$0.isVerified }.count

        viewModel = SecurityDashboardViewModel(
            identityFingerprint: fingerprint,
            keyHealth: viewModel.keyHealth,
            lastKeyRotation: viewModel.lastKeyRotation,
            pqcAlgorithm: "ML-KEM-1024",
            unverifiedContacts: unverifiedCount,
            activeThreatReports: viewModel.activeThreatReports,
            wipeRequestPending: viewModel.wipeRequestPending
        )
    }

    func refresh() {
        loadLocalState()
        // Future: fetch activeThreatReports from server endpoint,
        // wipeRequestPending from incoming PushKit events.
    }

    private func deriveDisplayPubkey() -> Data {
        // Hash of userId gives a stable 32-byte seed for fingerprint display.
        let userId = appState.currentUserId ?? "unknown-user"
        return Data(SHA256.hash(data: Data(userId.utf8)))
    }
}

// MARK: - Screen

struct SecurityDashboardScreen: View {
    @StateObject private var container: SecurityDashboardContainer

    init(state: AppState) {
        _container = StateObject(wrappedValue: SecurityDashboardContainer(appState: state))
    }

    private var keyHealthColor: Color {
        switch container.viewModel.keyHealth {
        case .healthy: return .green
        case .rotationDue: return .orange
        case .compromised: return .red
        }
    }

    private var keyHealthLabel: String {
        switch container.viewModel.keyHealth {
        case .healthy: return "Healthy"
        case .rotationDue: return "Rotation Due"
        case .compromised: return "COMPROMISED"
        }
    }

    private var lastRotationText: String {
        guard let date = container.viewModel.lastKeyRotation else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        Form {
            // MARK: Identity

            Section("Identity") {
                LabeledContent("Fingerprint") {
                    Text(container.viewModel.identityFingerprint)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Algorithm") {
                    Text(container.viewModel.pqcAlgorithm)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Key Health

            Section("Key Health") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(keyHealthColor)
                            .frame(width: 8, height: 8)
                        Text(keyHealthLabel)
                            .foregroundStyle(keyHealthColor)
                    }
                }
                LabeledContent("Last Rotation") {
                    Text(lastRotationText)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Threat Summary

            Section("Threat Summary") {
                NavigationLink {
                    ContactsListView()
                } label: {
                    LabeledContent("Unverified Contacts") {
                        Text("\(container.viewModel.unverifiedContacts)")
                            .foregroundStyle(
                                container.viewModel.unverifiedContacts > 0 ? .orange : .secondary
                            )
                    }
                }

                NavigationLink {
                    // W16.B: real list view of historic threat reports +
                    // empty state + "+" toolbar to file a new one. Reads
                    // local UserDefaults via ThreatReportLogStore.
                    // The `activeThreatReports` count below still comes
                    // from the SecurityDashboardViewModel mock — server-
                    // side incoming-threat fan-out is separate work.
                    ThreatReportListView(appState: container.appState)
                } label: {
                    LabeledContent("Active Threats") {
                        Text("\(container.viewModel.activeThreatReports)")
                            .foregroundStyle(
                                container.viewModel.activeThreatReports > 0 ? .red : .secondary
                            )
                    }
                }

                if container.viewModel.wipeRequestPending {
                    Label("Remote wipe request pending", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Sicurezza")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    container.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            container.loadLocalState()
        }
        .alert("Error", isPresented: .constant(container.errorMessage != nil)) {
            Button("OK") { container.errorMessage = nil }
        } message: {
            Text(container.errorMessage ?? "")
        }
    }
}

// MARK: - Threat Report Placeholder (removed in W16.B)
// The previous private `ThreatReportPlaceholderView` has been replaced by
// the real `ThreatReportListView` (App-layer, file `ThreatReportListView.swift`)
// which consumes `ThreatReportLogStore` and supports filing new reports
// via a "+" toolbar. The placeholder was a yellow stop-gap noting that
// the full list "requires server-side wiring"; that wiring is still
// pending for *incoming* server-side threat events but the local
// submitted-report history is now functional.
