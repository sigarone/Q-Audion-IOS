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

// MARK: - Status badge helper

private extension TransportDiagnostics.ConnectionStatus {
    var color: Color {
        switch self {
        case .unknown:            return .secondary
        case .healthy:            return .green
        case .degraded:           return .yellow
        case .unreachable:        return .red
        }
    }

    var label: String {
        switch self {
        case .unknown:                    return "Unknown"
        case .healthy(let ms):            return "Healthy (\(ms) ms)"
        case .degraded(let ms):           return "Degraded (\(ms) ms)"
        case .unreachable:                return "Unreachable"
        }
    }
}

// MARK: - Screen

struct TransportSettingsScreen: View {
    @StateObject private var container: TransportSettingsContainer

    init(state: AppState) {
        _container = StateObject(wrappedValue: TransportSettingsContainer(state: state))
    }

    var body: some View {
        Form {
            // MARK: Connection Mode
            Section("Connection Mode") {
                Picker("Mode", selection: $container.draftMode) {
                    ForEach(TransportSettingsViewModel.Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch container.draftMode {
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

            // MARK: Anonymisation
            Section("Anonymisation") {
                Toggle("Route via Tor", isOn: $container.draftTorEnabled)
                if container.draftTorEnabled {
                    Text("All signalling and media traffic is routed through the Tor network. Expect higher latency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: TURN Server
            Section("TURN Server") {
                TextField("turn:hostname:3478", text: $container.draftPreferredUrlString)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Text("Leave empty to use the default relay pool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Diagnostics
            Section("Diagnostics") {
                // Server status badge
                LabeledContent("Server Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(container.diagnostics.serverStatus.color)
                            .frame(width: 8, height: 8)
                        Text(container.diagnostics.serverStatus.label)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                // TURN RTT (from last fetch)
                LabeledContent("Last TURN RTT") {
                    Text("\(container.diagnostics.lastTurnRoundTripMs) ms")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }

                // Stored TURN RTT from SettingsStore
                LabeledContent("Stored TURN RTT") {
                    Text("\(container.viewModel.lastTurnRoundTripMs) ms")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }

                // Last checked timestamp
                if let lastChecked = container.diagnostics.lastChecked {
                    LabeledContent("Last Checked") {
                        Text(lastChecked, style: .time)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                // Error message (if any)
                if let errMsg = container.diagnostics.errorMessage {
                    Text(errMsg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // Run check button
                Button {
                    Task { await container.runDiagnostics() }
                } label: {
                    HStack {
                        if container.diagnostics.isChecking {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 4)
                        }
                        Text(container.diagnostics.isChecking ? "Checking…" : "Run Check")
                    }
                }
                .disabled(container.diagnostics.isChecking)
            }

            // MARK: Save
            Section {
                Button("Save") {
                    container.save()
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .fontWeight(.semibold)
            }
        }
        .navigationTitle("Trasporto")
    }
}
