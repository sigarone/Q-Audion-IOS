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

/// Calls settings sub-screen. W26 design-token refactor — replaces
/// stock `Form` with the new vocabulary. Codec is read-only,
/// quality uses a segmented Picker that adapts to dark scheme,
/// AEC/NS/AGC are SettingsToggleRow.
struct CallsSettingsScreen: View {
    @StateObject private var container: CallsSettingsContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        _container = StateObject(wrappedValue: CallsSettingsContainer())
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("CODEC")
                    kvRow(label: "Audio Codec",
                          value: container.viewModel.codecPreference.rawValue.capitalized,
                          mono: false)

                    SettingsSectionHeader("QUALITÀ CHIAMATA")
                    qualityPicker

                    SettingsSectionHeader("ELABORAZIONE AUDIO")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Echo Cancellation (AEC)",
                            subtitle: "Riduce l'eco quando si usa l'altoparlante",
                            isOn: Binding(
                                get: { container.viewModel.isAecEnabled },
                                set: { container.toggleAec($0) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Noise Suppression (NS)",
                            subtitle: "Filtra i rumori di sottofondo",
                            isOn: Binding(
                                get: { container.viewModel.isNsEnabled },
                                set: { container.toggleNs($0) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Auto Gain Control (AGC)",
                            subtitle: "Normalizza il livello del microfono",
                            isOn: Binding(
                                get: { container.viewModel.isAgcEnabled },
                                set: { container.toggleAgc($0) }
                            )
                        )
                        if anyAudioProcDisabled {
                            warningHint("Disabilitare l'elaborazione audio peggiora la qualità della chiamata.")
                        }
                    }

                    SettingsSectionHeader("BACKGROUND")
                    statusRow(
                        label: "Modalità VoIP background",
                        active: container.viewModel.isVoipBackgroundModeActive
                    )
                    Text("La modalità background è controllata dall'entitlement UIBackgroundModes.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Chiamate")
    }

    private var anyAudioProcDisabled: Bool {
        !container.viewModel.isAecEnabled
            || !container.viewModel.isNsEnabled
            || !container.viewModel.isAgcEnabled
    }

    // MARK: - Quality picker

    private var qualityPicker: some View {
        Picker("", selection: Binding(
            get: { container.viewModel.preferredCallQuality },
            set: { container.setCallQuality($0) }
        )) {
            ForEach(CallsSettingsViewModel.CallQuality.allCases, id: \.self) { quality in
                Text(quality.rawValue.capitalized).tag(quality)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    // MARK: - kvRow + statusRow + warningHint helpers

    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededC(mono: mono))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func statusRow(label: String, active: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? extras.success : extras.riskHigh)
                    .frame(width: 8, height: 8)
                Text(active ? "Attivo" : "Inattivo")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(active ? extras.success : extras.riskHigh)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private func warningHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.warning)
                .padding(.top, 1)
            Text(text)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.warning)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.warning.opacity(0.12))
        )
    }
}

private struct MonoIfNeededC: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
