import SwiftUI
import CryptoKit
import QAudionEngine

// MARK: - Container

@MainActor
final class SecurityDashboardContainer: ObservableObject {
    @Published private(set) var viewModel: SecurityDashboardViewModel
    @Published var errorMessage: String?

    let appState: AppState

    init(appState: AppState, initial: SecurityDashboardViewModel = .mock) {
        self.appState = appState
        self.viewModel = initial
        loadLocalState()
    }

    func loadLocalState() {
        let pubkey = deriveDisplayPubkey()
        let fingerprint = (try? Fingerprint.format(pubkey: pubkey))
            ?? "????.????.????.????"

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
    }

    private func deriveDisplayPubkey() -> Data {
        let userId = appState.currentUserId ?? "unknown-user"
        return Data(SHA256.hash(data: Data(userId.utf8)))
    }
}

// MARK: - Screen

/// Security dashboard sub-screen. W31 design-token refactor.
struct SecurityDashboardScreen: View {
    @StateObject private var container: SecurityDashboardContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        _container = StateObject(wrappedValue: SecurityDashboardContainer(appState: state))
    }

    private var keyHealthColor: Color {
        switch container.viewModel.keyHealth {
        case .healthy:     return extras.success
        case .rotationDue: return extras.warning
        case .compromised: return extras.riskHigh
        }
    }

    private var keyHealthLabel: String {
        switch container.viewModel.keyHealth {
        case .healthy:     return "Operativa"
        case .rotationDue: return "Rotazione consigliata"
        case .compromised: return "COMPROMESSA"
        }
    }

    private var lastRotationText: String {
        guard let date = container.viewModel.lastKeyRotation else { return "Mai" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("IDENTITÀ")
                    VStack(spacing: 8) {
                        kvRow(label: "Fingerprint",
                              value: container.viewModel.identityFingerprint,
                              mono: true)
                        kvRow(label: "Algoritmo",
                              value: container.viewModel.pqcAlgorithm,
                              mono: true)
                    }

                    SettingsSectionHeader("STATO CHIAVI")
                    VStack(spacing: 8) {
                        statusRow(label: "Stato",
                                  value: keyHealthLabel,
                                  tone: keyHealthColor)
                        kvRow(label: "Ultima rotazione",
                              value: lastRotationText,
                              mono: false)
                    }

                    SettingsSectionHeader("MINACCE")
                    VStack(spacing: 8) {
                        NavigationLink {
                            ContactsListView()
                        } label: {
                            countRow(label: "Contatti non verificati",
                                     count: container.viewModel.unverifiedContacts,
                                     warningColor: extras.warning)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ThreatReportListView(appState: container.appState)
                        } label: {
                            countRow(label: "Minacce attive",
                                     count: container.viewModel.activeThreatReports,
                                     warningColor: extras.riskHigh)
                        }
                        .buttonStyle(.plain)

                        if container.viewModel.wipeRequestPending {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(extras.riskHigh)
                                Text("Richiesta di wipe remoto in sospeso")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(extras.riskHigh)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(extras.riskHigh.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(extras.riskHigh.opacity(0.45), lineWidth: 1)
                            )
                        }
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Sicurezza")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { container.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(scheme.primary)
                }
            }
        }
        .onAppear { container.loadLocalState() }
        .alert("Errore", isPresented: .constant(container.errorMessage != nil)) {
            Button("OK") { container.errorMessage = nil }
        } message: {
            Text(container.errorMessage ?? "")
        }
    }

    // MARK: - Rows

    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededS(mono: mono))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func statusRow(label: String, value: String, tone: Color) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(tone).frame(width: 8, height: 8)
                Text(value)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(tone)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func countRow(label: String, count: Int, warningColor: Color) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text("\(count)")
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(count > 0 ? warningColor : scheme.onSurfaceVariant)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}

private struct MonoIfNeededS: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
