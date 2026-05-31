import SwiftUI
import QAudionEngine

@MainActor
final class CallsSettingsContainer: ObservableObject {
    @Published var viewModel: CallsSettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        // W406: read from CallsGate so the displayed state matches the
        // value the audio pipeline will read on startCall.
        let legacy = store.loadCalls()
        self.viewModel = CallsSettingsViewModel(
            codecPreference: legacy.codecPreference,
            isAecEnabled: CallsGate.aecEnabled,
            isNsEnabled: CallsGate.nsEnabled,
            isAgcEnabled: CallsGate.agcEnabled,
            isVoipBackgroundModeActive: legacy.isVoipBackgroundModeActive,
            preferredCallQuality: legacy.preferredCallQuality
        )
    }

    func toggleAec(_ enabled: Bool) {
        viewModel = makeUpdated(aec: enabled)
        store.saveCalls(viewModel)
        CallsGate.setAec(enabled)
    }

    func toggleNs(_ enabled: Bool) {
        viewModel = makeUpdated(ns: enabled)
        store.saveCalls(viewModel)
        CallsGate.setNs(enabled)
    }

    func toggleAgc(_ enabled: Bool) {
        viewModel = makeUpdated(agc: enabled)
        store.saveCalls(viewModel)
        CallsGate.setAgc(enabled)
    }

    private func makeUpdated(
        aec: Bool? = nil,
        ns: Bool? = nil,
        agc: Bool? = nil
    ) -> CallsSettingsViewModel {
        CallsSettingsViewModel(
            codecPreference: viewModel.codecPreference,
            isAecEnabled: aec ?? viewModel.isAecEnabled,
            isNsEnabled: ns ?? viewModel.isNsEnabled,
            isAgcEnabled: agc ?? viewModel.isAgcEnabled,
            isVoipBackgroundModeActive: viewModel.isVoipBackgroundModeActive,
            preferredCallQuality: viewModel.preferredCallQuality
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

    // W443: call session security toggles — Keychain-backed via CallsGate
    // (SECURITY M-8). @AppStorage bypasses the Keychain store and breaks
    // the engine reads, so we use @State + explicit CallsGate setters.
    @State private var deepfakeGuardEnabled: Bool = false
    @State private var adaptiveRekeyingEnabled: Bool = false
    @State private var adaptivePaddingEnabled: Bool = false

    @AppStorage("qaudion.calls.metered_cap_enabled")
    private var meteredCapEnabled: Bool = false

    @AppStorage("qaudion.calls.metered_max_quality")
    private var meteredMaxQuality: MeteredQuality = .low

    enum MeteredQuality: String, CaseIterable, RawRepresentable {
        case low    = "Bassa"
        case medium = "Media"
        case high   = "Alta"
    }

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
                    kvRow(label: "Preset audio",
                          value: "32 kbps CBR · Complexity 10",
                          mono: true)
                    Text("Il bitrate è fisso a 32 kbps CBR su tutti i dispositivi (iOS, Android, firmware). Cambiarlo romperebbe la compatibilità cross-platform e la proprietà anti-fingerprinting (frame a dimensione costante).")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)

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

                    // W503: metered-network cap — parity with Android
                    // SettingsScreen root VIDEO_QUALITY / meteredNetworkCap.
                    // When enabled, caps codec quality on cellular/metered
                    // connections to reduce data usage without touching Wi-Fi.
                    SettingsSectionHeader("RETE DATI")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Risparmio dati in chiamata",
                            subtitle: "Limita qualità codec su rete cellulare",
                            isOn: $meteredCapEnabled
                        )
                        if meteredCapEnabled {
                            meteredQualityPicker
                        }
                    }

                    SettingsSectionHeader("SICUREZZA CHIAMATE")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Deepfake Guard",
                            subtitle: "Analisi deepfake live on-device durante ogni chiamata",
                            isOn: Binding(
                                get: { deepfakeGuardEnabled },
                                set: { v in deepfakeGuardEnabled = v; CallsGate.setDeepfakeGuard(v) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Re-keying adattivo",
                            subtitle: "Frequenza di rinnovo chiavi scalata con il Confidence Index",
                            isOn: Binding(
                                get: { adaptiveRekeyingEnabled },
                                set: { v in adaptiveRekeyingEnabled = v; CallsGate.setAdaptiveRekeying(v) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Adaptive Padding CBR",
                            subtitle: "Bitrate costante per resistere all'analisi del traffico",
                            isOn: Binding(
                                get: { adaptivePaddingEnabled },
                                set: { v in adaptivePaddingEnabled = v; CallsGate.setAdaptivePadding(v) }
                            )
                        )
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Chiamate")
        .onAppear {
            deepfakeGuardEnabled = CallsGate.deepfakeGuardEnabled
            adaptiveRekeyingEnabled = CallsGate.adaptiveRekeyingEnabled
            adaptivePaddingEnabled = CallsGate.adaptivePaddingEnabled
        }
    }

    // MARK: - Metered quality picker

    private var meteredQualityPicker: some View {
        HStack {
            Text("Qualità massima su cellulare")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Picker("", selection: $meteredMaxQuality) {
                ForEach(MeteredQuality.allCases, id: \.self) { q in
                    Text(q.rawValue).tag(q)
                }
            }
            .pickerStyle(.menu)
            .tint(scheme.primary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    private var anyAudioProcDisabled: Bool {
        !container.viewModel.isAecEnabled
            || !container.viewModel.isNsEnabled
            || !container.viewModel.isAgcEnabled
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
