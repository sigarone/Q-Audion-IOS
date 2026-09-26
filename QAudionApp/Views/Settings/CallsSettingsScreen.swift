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

    // W-NOCALLKIT — revert switch for the CallKit-free incoming-call mode.
    // UserDefaults-backed via CallsGate (not Keychain); read once on appear.
    @State private var callKitFreeMode: Bool = false

    /// W-AUDIOSRTPDEBUGTOGGLE / W-CODECMENUSRTP — mirrors
    /// `CallCapabilities.audioSrtpDebugOverride` (a plain static var, not
    /// itself observable) into local SwiftUI state, exactly the pattern
    /// `SettingsScreen` used before this control moved here. Seeded from
    /// whatever override is already in force (falling back to the compiled
    /// default) so re-entering this screen mid-session shows the real
    /// current state, not a stale default. Runtime-only — never persisted,
    /// resets to the compiled default on process restart.
    @State private var audioSrtpToggle: Bool =
        CallCapabilities.audioSrtpDebugOverride ?? CallCapabilities.audioSrtpSendEnabled

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

                    // W-CODECMENUSRTP — moved out of the internal-only
                    // Settings surface so the transport choice is reachable
                    // in every build, right under the codec it sits
                    // alongside. Same binding the internal toggle used:
                    // `CallCapabilities.audioSrtpDebugOverride ??
                    // audioSrtpSendEnabled`, in-memory only, per-call
                    // snapshot means a mid-call flip cannot affect the call
                    // already in progress.
                    //
                    // The row subtitle is kept short because
                    // `SettingsToggleRow` caps it at `.lineLimit(2)`; the
                    // full disclosure (and the experimental warning, same
                    // pattern as "MODALITÀ CHIAMATA (SPERIMENTALE)" below)
                    // lives in the uncapped `warningHint` underneath.
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Audio SRTP standard (WebRTC)",
                            subtitle: "Sostituisce il protocollo Q-Audion con WebRTC DTLS-SRTP standard, se attivo su entrambi i dispositivi.",
                            isOn: Binding(
                                get: { audioSrtpToggle },
                                set: { newValue in
                                    audioSrtpToggle = newValue
                                    CallCapabilities.audioSrtpDebugOverride = newValue
                                }
                            )
                        )
                        warningHint("Funzione sperimentale: se l'audio risulta assente o instabile, disattivala (ha effetto dalla prossima chiamata). Cifra i frame end-to-end; l'impostazione non è salvata e torna disattivata al riavvio dell'app.")
                    }

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
                    // W-L10N-BATCH1 (2026-09-08) — statusRow's `label:`
                    // is a plain String, not LocalizedStringKey (see
                    // its signature below), so this literal doesn't
                    // auto-localize.
                    statusRow(
                        label: String(localized: "calls_settings.status.background_voip_mode", defaultValue: "Modalità VoIP background", comment: "Calls settings, BACKGROUND section — status row label for whether VoIP background mode is active"),
                        active: container.viewModel.isVoipBackgroundModeActive
                    )
                    Text("La modalità background è controllata dall'entitlement UIBackgroundModes.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)

                    // W-NOCALLKIT — experimental: replace iOS CallKit + PushKit
                    // with a fully custom in-app incoming-call ring. Revertible:
                    // OFF restores the proven CallKit path. Requires app restart.
                    SettingsSectionHeader("MODALITÀ CHIAMATA (SPERIMENTALE)")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Interfaccia chiamata personalizzata",
                            subtitle: "Sostituisce CallKit/PushKit con la suoneria interna dell'app",
                            isOn: Binding(
                                get: { callKitFreeMode },
                                set: { v in callKitFreeMode = v; CallsGate.setCallKitFreeMode(v) }
                            )
                        )
                        warningHint("Modalità sperimentale. Riavvia l'app dopo la modifica. Con questa attiva non c'è la schermata di chiamata a tutto schermo su lock screen né integrazione CarPlay; con app chiusa la chiamata arriva come notifica con Rispondi/Rifiuta.")
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Chiamate")
        .onAppear {
            callKitFreeMode = CallsGate.callKitFreeMode
        }
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
