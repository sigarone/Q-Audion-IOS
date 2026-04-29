import SwiftUI
import QAudionEngine

@MainActor
final class TransportSettingsContainer: ObservableObject {
    @Published var viewModel: TransportSettingsViewModel
    @Published var diagnostics: TransportDiagnostics
    @Published var draftMode: TransportSettingsViewModel.Mode
    @Published var draftTorEnabled: Bool
    @Published var draftPreferredUrlString: String

    init(state: AppState) {
        let stored = SettingsStore().loadTransport()
        self.viewModel = stored
        self.diagnostics = TransportDiagnostics(appState: state)
        self.draftMode = stored.mode
        self.draftTorEnabled = stored.torEnabled
        self.draftPreferredUrlString = stored.preferredTurnServerUrl?.absoluteString ?? ""
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

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        _container = StateObject(wrappedValue: TransportSettingsContainer(state: state))
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
                    SettingsToggleRow(
                        title: "Instrada via Tor",
                        subtitle: "Tutto il segnale e media via rete Tor",
                        isOn: $container.draftTorEnabled
                    )
                    if container.draftTorEnabled {
                        Text("Tutto il traffico di segnalazione e media è instradato via Tor. Aspettati latenza maggiore.")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.horizontal, 14).padding(.top, 6)
                    }

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
