import SwiftUI
import QAudionEngine

@MainActor
final class SecurityDashboardContainer: ObservableObject {
    @Published var viewModel: SecurityDashboardViewModel
    init(initial: SecurityDashboardViewModel = .mock) { self.viewModel = initial }
}

struct SecurityDashboardScreen: View {
    @ObservedObject var container: SecurityDashboardContainer

    init(state: AppState) {
        let c = SecurityDashboardContainer()
        self._container = ObservedObject(wrappedValue: c)
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

            Section("Threat Summary") {
                LabeledContent("Unverified Contacts") {
                    Text("\(container.viewModel.unverifiedContacts)")
                        .foregroundStyle(container.viewModel.unverifiedContacts > 0 ? .orange : .secondary)
                }
                LabeledContent("Active Threats") {
                    Text("\(container.viewModel.activeThreatReports)")
                        .foregroundStyle(container.viewModel.activeThreatReports > 0 ? .red : .secondary)
                }
                if container.viewModel.wipeRequestPending {
                    Label("Remote wipe request pending", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Security")
    }
}
