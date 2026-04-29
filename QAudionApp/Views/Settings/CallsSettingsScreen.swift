import SwiftUI
import QAudionEngine

@MainActor
final class CallsSettingsContainer: ObservableObject {
    @Published var viewModel: CallsSettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.viewModel = store.loadCalls()
    }

    func toggleAec(_ enabled: Bool) {
        viewModel = makeUpdated(aec: enabled)
        store.saveCalls(viewModel)
    }

    func toggleNs(_ enabled: Bool) {
        viewModel = makeUpdated(ns: enabled)
        store.saveCalls(viewModel)
    }

    func toggleAgc(_ enabled: Bool) {
        viewModel = makeUpdated(agc: enabled)
        store.saveCalls(viewModel)
    }

    func setCallQuality(_ quality: CallsSettingsViewModel.CallQuality) {
        viewModel = makeUpdated(quality: quality)
        store.saveCalls(viewModel)
    }

    private func makeUpdated(
        aec: Bool? = nil,
        ns: Bool? = nil,
        agc: Bool? = nil,
        quality: CallsSettingsViewModel.CallQuality? = nil
    ) -> CallsSettingsViewModel {
        CallsSettingsViewModel(
            codecPreference: viewModel.codecPreference,
            isAecEnabled: aec ?? viewModel.isAecEnabled,
            isNsEnabled: ns ?? viewModel.isNsEnabled,
            isAgcEnabled: agc ?? viewModel.isAgcEnabled,
            isVoipBackgroundModeActive: viewModel.isVoipBackgroundModeActive,
            preferredCallQuality: quality ?? viewModel.preferredCallQuality
        )
    }
}

struct CallsSettingsScreen: View {
    @StateObject private var container: CallsSettingsContainer

    init(state: AppState) {
        _container = StateObject(wrappedValue: CallsSettingsContainer())
    }

    var body: some View {
        Form {
            Section("Codec") {
                LabeledContent("Audio Codec") {
                    Text(container.viewModel.codecPreference.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Call Quality") {
                Picker("Quality", selection: Binding(
                    get: { container.viewModel.preferredCallQuality },
                    set: { container.setCallQuality($0) }
                )) {
                    ForEach(CallsSettingsViewModel.CallQuality.allCases, id: \.self) { quality in
                        Text(quality.rawValue.capitalized).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Audio Processing") {
                Toggle("Echo Cancellation (AEC)", isOn: Binding(
                    get: { container.viewModel.isAecEnabled },
                    set: { container.toggleAec($0) }
                ))
                Toggle("Noise Suppression (NS)", isOn: Binding(
                    get: { container.viewModel.isNsEnabled },
                    set: { container.toggleNs($0) }
                ))
                Toggle("Auto Gain Control (AGC)", isOn: Binding(
                    get: { container.viewModel.isAgcEnabled },
                    set: { container.toggleAgc($0) }
                ))
                if !container.viewModel.isAecEnabled || !container.viewModel.isNsEnabled || !container.viewModel.isAgcEnabled {
                    Text("Disabling audio processing degrades call quality.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Background") {
                LabeledContent("VoIP Background Mode") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(container.viewModel.isVoipBackgroundModeActive ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(container.viewModel.isVoipBackgroundModeActive ? "Active" : "Inactive")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Background mode is controlled by the UIBackgroundModes entitlement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Chiamate")
    }
}
