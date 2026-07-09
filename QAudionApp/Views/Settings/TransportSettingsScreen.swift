import SwiftUI
import QAudionEngine

@MainActor
final class TransportSettingsContainer: ObservableObject {
    @Published var viewModel: TransportSettingsViewModel
    @Published var diagnostics: TransportDiagnostics
    @Published var draftMode: TransportSettingsViewModel.Mode
    @Published var draftTorEnabled: Bool
    @Published var draftPreferredUrlString: String

    // VPN exit-node picker. Reuses the same VpnService + access token the
    // HomeView VpnToggleChip uses, and the SAME `vpn.preferredNodeId`
    // UserDefaults key, so a choice made here and one made via the chip's
    // long-press picker stay in sync. Primitives/refs only (no AppState type
    // stored), so the build-landmine guard is not tripped.
    @Published var vpnNodes: [VpnNode] = []
    @Published var vpnNodesLoading = false
    private let vpnService: VpnService
    private let vpnTokenProvider: () -> String

    /// Manual force-Reality applier. Captures `state` as a closure (NOT a
    /// stored AppState property — same build-landmine avoidance as
    /// `vpnTokenProvider`) so flipping the toggle activates / reverts the
    /// Reality tunnel live via `AppState.setForceRealityTransport(_:)`.
    private let forceRealityApplier: (Bool) -> Void

    init(state: AppState) {
        let stored = SettingsStore().loadTransport()
        self.viewModel = stored
        self.diagnostics = TransportDiagnostics(appState: state)
        self.draftMode = stored.mode
        self.draftTorEnabled = stored.torEnabled
        self.draftPreferredUrlString = stored.preferredTurnServerUrl?.absoluteString ?? ""
        self.vpnService = state.vpnService
        self.vpnTokenProvider = { state.currentAccessToken ?? "" }
        self.forceRealityApplier = { [weak state] on in state?.setForceRealityTransport(on) }
    }

    /// Apply the manual Reality force toggle. Persists + activates/reverts now.
    func applyForceReality(_ on: Bool) { forceRealityApplier(on) }

    /// Fetch the live exit-node list (Helsinki, Milano, …) for the picker.
    /// Best-effort: a failure leaves the list empty (the row still shows
    /// "Auto"); never throws to the UI.
    func loadVpnNodes() async {
        let token = vpnTokenProvider()
        guard !token.isEmpty else { return }
        vpnNodesLoading = true
        defer { vpnNodesLoading = false }
        vpnNodes = (try? await vpnService.fetchNodes(accessToken: token)) ?? []
    }

    func runDiagnostics() async {
        await diagnostics.checkServer()
        await diagnostics.fetchTurnRelays()
    }

    func save() {
        let url = URL(string: draftPreferredUrlString)
        diagnostics.saveTransport(mode: draftMode, torEnabled: draftTorEnabled, preferredUrl: url)
        viewModel = SettingsStore().loadTransport()
    }
}

// MARK: - Status helpers

private extension TransportDiagnostics.ConnectionStatus {
    func tone(extras: QAudionColorsExtra) -> Color {
        switch self {
        case .unknown:     return Color.gray
        case .healthy:     return extras.success
        case .degraded:    return extras.warning
        case .unreachable: return extras.riskHigh
        }
    }

    var label: String {
        switch self {
        case .unknown:                    return "Sconosciuto"
        case .healthy(let ms):            return "Operativo (\(ms) ms)"
        case .degraded(let ms):           return "Degradato (\(ms) ms)"
        case .unreachable:                return "Non raggiungibile"
        }
    }
}

private extension TransportSettingsViewModel.Mode {
    var localizedLabel: String {
        switch self {
        case .auto:  return "Auto"
        case .p2p:   return "P2P"
        case .turn:  return "TURN"
        case .relay: return "Relay"
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            return "Sceglie automaticamente la rotta migliore (P2P preferito, relay fallback)."
        case .p2p:
            return "Connessione diretta peer-to-peer. Entrambi gli endpoint devono essere raggiungibili."
        case .turn:
            return "Instrada via TURN relay. Aumenta la latenza ma migliora il NAT traversal."
        case .relay:
            return "Forza il relay via server BCrypto. Nasconde gli IP a costo di latenza maggiore."
        }
    }
}

// MARK: - Screen

/// Transport settings sub-screen. W31 design-token refactor.
/// Replaces stock `Form` with the new design vocabulary.
struct TransportSettingsScreen: View {
    @StateObject private var container: TransportSettingsContainer
    // REALITY_PIN fix: observed directly (not via a closure, like `container`'s
    // other AppState reads) so the `realityKeyChanged` advisory below updates
    // live when `activateRealityFallback` flips it.
    @ObservedObject private var appState: AppState

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    /// Manual VPN exit choice. '' = Auto (NodePicker best). SAME UserDefaults
    /// key as the HomeView VpnToggleChip long-press picker, so both stay in sync.
    @AppStorage("vpn.preferredNodeId") private var preferredVpnNodeId: String = ""

    /// Manual force-Reality toggle. SAME UserDefaults key the connect path
    /// reads (`AppState.forceRealityEnabled`), so a flip here and the connect
    /// decision stay in sync. Default off — clearnet-first.
    @AppStorage(AppState.forceRealityDefaultsKey) private var forceReality: Bool = false

    init(state: AppState) {
        _container = StateObject(wrappedValue: TransportSettingsContainer(state: state))
        _appState = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("MODALITÀ DI CONNESSIONE")
                    modePicker
                    Text(container.draftMode.explanation)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)

                    SettingsSectionHeader("ANONIMIZZAZIONE")
                    // W409: honest UI for the Tor toggle. iOS does not
                    // expose system-wide SOCKS proxy support, so even
                    // with the toggle ON the URLSession used by the
                    // app's REST/WS transport would still go direct.
                    // Until a bundled Tor client (e.g. Onion-based
                    // CFNetwork hook) ships, the row is rendered in
                    // a disabled state with an explicit "non
                    // disponibile su iOS" hint so the user isn't
                    // misled into thinking they're anonymized.
                    SettingsToggleRow(
                        title: "Instrada via Tor",
                        subtitle: "Tutto il segnale e media via rete Tor",
                        isOn: .constant(false)
                    )
                    .opacity(0.45)
                    .disabled(true)
                    Text("Non disponibile su iOS in questa versione: la piattaforma non espone un proxy SOCKS di sistema. Verrà riattivato quando l'app integrerà un client Tor bundled.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14).padding(.top, 6)

                    SettingsSectionHeader("ANTI-CENSURA (REALITY)")
                    // commit 54f0a2e wired Reality.xcframework as a real
                    // conditional .binaryTarget (QAudionEngine/Package.swift),
                    // so RealityManager's real `#if canImport(Reality)` branch
                    // now compiles in CI-built binaries — this row was left
                    // disabled behind the old "not wired yet" copy after the
                    // backend went live. Live now: bind the toggle.
                    SettingsToggleRow(
                        title: "Forza tunnel Reality",
                        subtitle: "Instrada il segnale nel tunnel anti-censura (test)",
                        isOn: $forceReality
                    )
                    .onChange(of: forceReality) { newValue in
                        container.applyForceReality(newValue)
                    }
                    Text("Instrada segnale e media nel tunnel Reality (VLESS+Reality) invece che in chiaro. Sperimentale.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14).padding(.top, 6)
                    // REALITY_PIN fix: non-blocking advisory when the server-
                    // issued Reality front public key changed since we last
                    // pinned it (RealityPinStore) — the tunnel still connects
                    // under the new key (signal-not-kill); this just surfaces it.
                    if appState.realityKeyChanged {
                        errorBanner("La chiave pubblica del front Reality è CAMBIATA rispetto all'ultima connessione. Il tunnel è stato ri-associato alla nuova chiave e la connessione prosegue.")
                            .padding(.top, 6)
                    }

                    SettingsSectionHeader("NODO VPN (USCITA)")
                    vpnNodeSection

                    SettingsSectionHeader("SERVER TURN")
                    turnInputRow
                    Text("Lascia vuoto per usare il pool di relay predefinito.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14).padding(.top, 6)

                    SettingsSectionHeader("DIAGNOSTICA")
                    VStack(spacing: 8) {
                        statusRow(label: "Stato server",
                                  value: container.diagnostics.serverStatus.label,
                                  tone: container.diagnostics.serverStatus.tone(extras: extras))
                        kvRow(label: "Ultimo TURN RTT",
                              value: "\(container.diagnostics.lastTurnRoundTripMs) ms",
                              mono: true)
                        kvRow(label: "TURN RTT salvato",
                              value: "\(container.viewModel.lastTurnRoundTripMs) ms",
                              mono: true)
                        if let lastChecked = container.diagnostics.lastChecked {
                            kvRow(label: "Ultimo controllo",
                                  value: lastChecked.formatted(date: .omitted, time: .standard),
                                  mono: true)
                        }
                        if let errMsg = container.diagnostics.errorMessage {
                            errorBanner(errMsg)
                        }
                        runCheckButton
                    }

                    Spacer().frame(height: 16)
                    saveButton
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Trasporto")
        .task { await container.loadVpnNodes() }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("", selection: $container.draftMode) {
            ForEach(TransportSettingsViewModel.Mode.allCases, id: \.self) { mode in
                Text(mode.localizedLabel).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    // MARK: - VPN exit node

    @ViewBuilder
    private var vpnNodeSection: some View {
        VStack(spacing: 8) {
            vpnNodeRow(id: "", title: "Auto", subtitle: "Nodo migliore · latenza + carico")
            ForEach(container.vpnNodes) { n in
                let loadPct: Int = Int((n.loadPct * 100).rounded())
                let sub: String = n.country + " · " + String(loadPct) + "% carico"
                let ttl: String = n.city.isEmpty ? n.id : n.city
                vpnNodeRow(id: n.id, title: ttl, subtitle: sub)
            }
            if container.vpnNodesLoading && container.vpnNodes.isEmpty {
                Text("Caricamento nodi…")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }
        Text("Scegli da quale paese esce il traffico VPN. \"Auto\" sceglie il nodo migliore. La scelta vale dalla prossima connessione VPN.")
            .qaudionStyle(type.labelSmall)
            .foregroundStyle(scheme.onSurfaceVariant)
            .padding(.horizontal, 14).padding(.top, 6)
    }

    private func vpnNodeRow(id: String, title: String, subtitle: String) -> some View {
        Button {
            preferredVpnNodeId = id
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurface)
                    Text(subtitle)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer()
                if preferredVpnNodeId == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(extras.success)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - TURN URL input

    private var turnInputRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 22)

            TextField("", text: $container.draftPreferredUrlString,
                      prompt: Text("turn:hostname:3478")
                          .foregroundColor(scheme.onSurfaceVariant))
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(scheme.primary)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    // MARK: - Diagnostic rows

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
                    .modifier(MonoIfNeededT(mono: true))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededT(mono: mono))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.riskHigh)
                .padding(.top, 1)
            Text(msg)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }

    // MARK: - Buttons

    private var runCheckButton: some View {
        Button {
            Task { await container.runDiagnostics() }
        } label: {
            HStack {
                if container.diagnostics.isChecking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(scheme.onSurface)
                }
                Text(container.diagnostics.isChecking ? "Verifica in corso…" : "Esegui controllo")
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onSurface)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .disabled(container.diagnostics.isChecking)
    }

    private var saveButton: some View {
        Button { container.save() } label: {
            Text("Salva")
                .qaudionStyle(type.labelLarge)
                .tracking(0.8)
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(scheme.primary)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct MonoIfNeededT: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
