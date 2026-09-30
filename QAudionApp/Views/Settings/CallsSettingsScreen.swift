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

                    // W-SRTPALWAYSON (2026-09-29/30, owner decision after
                    // M150 verification) — the "Audio SRTP standard
                    // (WebRTC)" A/B toggle that used to live here
                    // (W-CODECMENUSRTP) is removed: native SRTP audio is now
                    // the unconditional default on every build
                    // (`CallCapabilities.audioSrtpSendEnabled == true`),
                    // with no local, manual way left to turn it off — only
                    // the remote `calls.native_srtp_kill` switch or the
                    // local crash-streak safety net
                    // (`CallCapabilities.registerNativeSrtpCrashAndMaybeAutoReset`)
                    // can still disable it. This read-only row replaces the
                    // toggle so the choice of transport stays visible
                    // (dev/diagnostic visibility kept, per the same
                    // principle as the "nsnap"/"admgate" RTLog lines this
                    // never touched) without offering a control that no
                    // longer does anything a user could rely on.
                    //
                    // REVIEW FIX (2026-09-30) — bound to
                    // `CallCapabilities.isNativeSrtpEnabledLocally` instead
                    // of a hardcoded "Attivo": a hardcoded value would keep
                    // claiming the path is active even on a device where the
                    // remote kill switch or the crash-streak safety net has
                    // actually turned it off, which is exactly the
                    // diagnostic visibility this row exists to preserve.
                    // `statusRow` re-reads this on every body evaluation
                    // (e.g. re-entering this screen), same as the old
                    // toggle's own seeded `@State` did.
                    statusRow(label: "Audio SRTP standard (WebRTC)",
                              active: CallCapabilities.isNativeSrtpEnabledLocally)
                    Text("Protocollo predefinito su tutti i dispositivi aggiornati. Con un dispositivo meno recente che non lo supporta ancora, o se il percorso e' stato disattivato da remoto o da una protezione automatica anti-crash, la chiamata passa automaticamente al protocollo Q-Audion.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)

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
