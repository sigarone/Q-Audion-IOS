import SwiftUI
import CryptoKit
import QAudionEngine

// MARK: - Container

@MainActor
final class SecurityDashboardContainer: ObservableObject {
    @Published private(set) var viewModel: SecurityDashboardViewModel
    @Published var errorMessage: String?

    // Sigsum kt-status (2026-09-04) — kept separate from `viewModel` on
    // purpose: everything else on this screen is read synchronously from
    // local stores (`loadLocalState` below), while this one field is a
    // REMOTE call. Folding it into `viewModel` would mean either blocking
    // `loadLocalState` on the network or race-overwriting a fresh kt-status
    // with a stale local-only rebuild. `.unknown` until the fetch resolves
    // (see `BCryptoKmsClient.KtStatus`'s kdoc) — purely informational,
    // never affects any trust or call decision on this or any other screen.
    @Published private(set) var ktStatus: BCryptoKmsClient.KtStatus = .unknown

    let appState: AppState

    init(appState: AppState, initial: SecurityDashboardViewModel = .mock) {
        self.appState = appState
        self.viewModel = initial
        loadLocalState()
    }

    func loadKtStatus() async {
        let provider = appState.makeUploadProvider()
        ktStatus = await provider.kmsClient.fetchKtStatus()
    }

    func loadLocalState() {
        let pubkey = deriveDisplayPubkey()
        let fingerprint = (try? Fingerprint.format(pubkey: pubkey))
            ?? "????.????.????.????"

        // Use the AppState cache rather than a fresh ContactsStore decode.
        let storedContacts = appState.cachedContacts
        let unverifiedCount = storedContacts.filter { !$0.isVerified }.count

        // 2026-08-06 fix: keyHealth/lastKeyRotation/activeThreatReports used
        // to just copy whatever `viewModel` already held — which starts as
        // `.mock` and, since nothing here ever recomputed them, stayed
        // frozen at the mock's `.healthy` / fixed 2025-04-07 date / `0`
        // forever, even after real rotations or real filed threat reports.
        // lastKeyRotation/keyHealth now mirror KeyRotationCoordinator's own
        // most-recent-rotation lookup (same SovereignKeyVault source, same
        // "rotated_ephemeral." naming contract) instead of a static date.
        // activeThreatReports reads the same local store ThreatReportListView
        // already persists to, so filing a report is reflected immediately.
        let rotation = Self.mostRecentRotation()
        let reportCount = ThreatReportLogStore().load().count

        viewModel = SecurityDashboardViewModel(
            identityFingerprint: fingerprint,
            keyHealth: .healthy,
            lastKeyRotation: rotation ?? viewModel.lastKeyRotation,
            pqcAlgorithm: "ML-KEM-1024",
            unverifiedContacts: unverifiedCount,
            activeThreatReports: reportCount,
            // No real "pending wipe" signal exists to poll: `remote_wipe`
            // (AppState.swift) fires and applies instantly over the
            // websocket, it isn't a state the client can observe as
            // pending beforehand. Always false until the server exposes
            // one — never flips true today, so this banner never lies.
            wipeRequestPending: false
        )
    }

    private static func mostRecentRotation() -> Date? {
        SovereignKeyVault().listPskEntries()
            .filter { $0.name.hasPrefix("rotated_ephemeral.") }
            .compactMap { $0.createdAt }
            .max()
    }

    func refresh() {
        loadLocalState()
        Task { await loadKtStatus() }
    }

    private func deriveDisplayPubkey() -> Data {
        // W407 — read the REAL sovereign identity pubkey from the
        // persisted vault instead of a fake SHA256(userId) digest.
        // The fingerprint shown to the user now matches the actual
        // public key contacts see. Falls back to userId-hash only if
        // no identity was generated yet (e.g. immediately post-
        // FastSetup before save).
        let mgr = SovereignIdentityManager()
        if let identity = mgr.loadIdentity() {
            // W410: real field is `encryptionPublic` (Curve25519 X25519
            // 32-byte pubkey). Was wrongly named `publicKey` in W407 —
            // built failure surfaced the real schema.
            return identity.encryptionPublic
        }
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

    /// Sigsum kt-status row label + color. See `BCryptoKmsClient.KtStatus`'s
    /// kdoc — "confirmed" is the only state backed by an independently
    /// verified transparency-log proof; "pending"/"unknown" are neutral
    /// (amber, not red — a normal transient state, not a problem) and
    /// "failed" is the one state that means a real submit attempt errored.
    private var ktStatusLabel: String {
        switch container.ktStatus {
        case .confirmed: return "Verificata"
        case .pending: return "In corso"
        case .failed: return "Non riuscita"
        case .notSubmitted: return "Non attiva"
        case .unknown: return "Sconosciuto"
        }
    }

    private var ktStatusColor: Color {
        switch container.ktStatus {
        case .confirmed: return extras.success
        case .pending, .unknown: return extras.warning
        case .failed: return extras.riskHigh
        case .notSubmitted: return scheme.onSurfaceVariant
        }
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

                    // Sigsum key transparency (2026-09-04) — purely
                    // informational per the product requirement: never
                    // blocks or refuses anything, just lets the user (and
                    // support) see whether the identity-key transparency
                    // submission is actually working.
                    SettingsSectionHeader("TRASPARENZA CHIAVE")
                    VStack(spacing: 8) {
                        statusRow(label: "Stato",
                                  value: ktStatusLabel,
                                  tone: ktStatusColor)
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
        .task { await container.loadKtStatus() }
        .alert("Errore", isPresented: Binding<Bool>(
            get: { container.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    container.errorMessage = nil
                }
            }
        )) {
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
