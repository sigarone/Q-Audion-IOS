import SwiftUI
import QAudionEngine

@MainActor
final class CallsSettingsContainer: ObservableObject {
    @Published var viewModel: CallsSettingsViewModel
    init(initial: CallsSettingsViewModel = .mock) { self.viewModel = initial }
}

struct CallsSettingsScreen: View {
    @ObservedObject var container: CallsSettingsContainer

    @State private var aecEnabled: Bool
    @State private var nsEnabled: Bool
    @State private var agcEnabled: Bool
    @State private var callQuality: CallsSettingsViewModel.CallQuality

    init(state: AppState) {
        let c = CallsSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
        self._aecEnabled = State(initialValue: c.viewModel.isAecEnabled)
        self._nsEnabled = State(initialValue: c.viewModel.isNsEnabled)
        self._agcEnabled = State(initialValue: c.viewModel.isAgcEnabled)
        self._callQuality = State(initialValue: c.viewModel.preferredCallQuality)
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
                Picker("Quality", selection: $callQuality) {
                    ForEach(CallsSettingsViewModel.CallQuality.allCases, id: \.self) { quality in
                        Text(quality.rawValue.capitalized).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Audio Processing") {
                Toggle("Echo Cancellation (AEC)", isOn: $aecEnabled)
                Toggle("Noise Suppression (NS)", isOn: $nsEnabled)
                Toggle("Auto Gain Control (AGC)", isOn: $agcEnabled)
                if !aecEnabled || !nsEnabled || !agcEnabled {
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
        .navigationTitle("Calls")
    }
}
