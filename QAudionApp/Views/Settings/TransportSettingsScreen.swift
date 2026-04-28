import SwiftUI
import QAudionEngine

@MainActor
final class TransportSettingsContainer: ObservableObject {
    @Published var viewModel: TransportSettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.viewModel = store.loadTransport()
    }

    func setMode(_ mode: TransportSettingsViewModel.Mode) {
        viewModel = makeUpdated(mode: mode)
        store.saveTransport(viewModel)
    }

    func toggleTor(_ enabled: Bool) {
        viewModel = makeUpdated(tor: enabled)
        store.saveTransport(viewModel)
    }

    private func makeUpdated(
        mode: TransportSettingsViewModel.Mode? = nil,
        tor: Bool? = nil
    ) -> TransportSettingsViewModel {
        TransportSettingsViewModel(
            mode: mode ?? viewModel.mode,
            torEnabled: tor ?? viewModel.torEnabled,
            preferredTurnServerUrl: viewModel.preferredTurnServerUrl,
            lastConnectionMs: viewModel.lastConnectionMs,
            lastTurnRoundTripMs: viewModel.lastTurnRoundTripMs
        )
    }
}

struct TransportSettingsScreen: View {
    @StateObject private var container: TransportSettingsContainer

    init(state: AppState) {
        _container = StateObject(wrappedValue: TransportSettingsContainer())
    }

    var body: some View {
        Form {
            Section("Connection Mode") {
                Picker("Mode", selection: Binding(
                    get: { container.viewModel.mode },
                    set: { container.setMode($0) }
                )) {
                    ForEach(TransportSettingsViewModel.Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch container.viewModel.mode {
                case .auto:
                    Text("Automatically choose the best path (P2P preferred, relay fallback).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .p2p:
                    Text("Direct peer-to-peer connection. Both endpoints must be reachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .turn:
                    Text("Route media through a TURN relay. Increases latency but improves NAT traversal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .relay:
                    Text("Force relay through BCrypto server. Hides peer IPs at the cost of higher latency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Anonymisation") {
                Toggle("Route via Tor", isOn: Binding(
                    get: { container.viewModel.torEnabled },
                    set: { container.toggleTor($0) }
                ))
                if container.viewModel.torEnabled {
                    Text("All signalling and media traffic is routed through the Tor network. Expect higher latency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                LabeledContent("Last Connection RTT") {
                    Text("\(container.viewModel.lastConnectionMs) ms")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last TURN RTT") {
                    Text("\(container.viewModel.lastTurnRoundTripMs) ms")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let turnUrl = container.viewModel.preferredTurnServerUrl {
                    LabeledContent("TURN Server") {
                        Text(turnUrl.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Transport")
    }
}
