import SwiftUI
import QAudionEngine

@MainActor
final class TransportSettingsContainer: ObservableObject {
    @Published var viewModel: TransportSettingsViewModel
    init(initial: TransportSettingsViewModel = .mock) { self.viewModel = initial }
}

struct TransportSettingsScreen: View {
    @ObservedObject var container: TransportSettingsContainer

    @State private var selectedMode: TransportSettingsViewModel.Mode
    @State private var torEnabled: Bool

    init(state: AppState) {
        let c = TransportSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
        self._selectedMode = State(initialValue: c.viewModel.mode)
        self._torEnabled = State(initialValue: c.viewModel.torEnabled)
    }

    var body: some View {
        Form {
            Section("Connection Mode") {
                Picker("Mode", selection: $selectedMode) {
                    ForEach(TransportSettingsViewModel.Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch selectedMode {
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
                Toggle("Route via Tor", isOn: $torEnabled)
                if torEnabled {
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
