import SwiftUI
import CryptoKit
import QAudionEngine

// MARK: - Container

@MainActor
final class SecurityDashboardContainer: ObservableObject {
    @Published private(set) var viewModel: SecurityDashboardViewModel
    @Published var errorMessage: String?

    private let appState: AppState

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
                    // Placeholder: threat report list not yet wired to server.
                    ThreatReportPlaceholderView(count: container.viewModel.activeThreatReports)
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
        .navigationTitle("Security")
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

// MARK: - Threat Report Placeholder

private struct ThreatReportPlaceholderView: View {
    let count: Int

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: count > 0 ? "shield.slash.fill" : "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(count > 0 ? Color.red : Color.green)
            Text(count > 0 ? "\(count) active threat report(s)" : "No active threats")
                .font(.headline)
            Text("Full threat report list requires server-side wiring.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Active Threats")
    }
}
