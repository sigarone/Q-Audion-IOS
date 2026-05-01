import SwiftUI
import QAudionEngine

@MainActor
final class NotificationsSettingsContainer: ObservableObject {
    @Published var viewModel: NotificationsSettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.viewModel = store.loadNotifications()
    }

    func setRingtone(_ id: String) {
        viewModel = makeUpdated(ringtoneId: id)
        store.saveNotifications(viewModel)
    }

    func toggleInAppSound(_ enabled: Bool) {
        viewModel = makeUpdated(inAppSound: enabled)
        store.saveNotifications(viewModel)
    }

    func toggleVibration(_ enabled: Bool) {
        viewModel = makeUpdated(vibration: enabled)
        store.saveNotifications(viewModel)
    }

    func setQuietHours(_ quietHours: NotificationsSettingsViewModel.QuietHours) {
        viewModel = makeUpdated(quietHours: quietHours)
        store.saveNotifications(viewModel)
    }

    func toggleQuietHours(_ enabled: Bool) {
        let updated = NotificationsSettingsViewModel.QuietHours(
            startHour: viewModel.quietHours.startHour,
            startMinute: viewModel.quietHours.startMinute,
            endHour: viewModel.quietHours.endHour,
            endMinute: viewModel.quietHours.endMinute,
            enabled: enabled
        )
        setQuietHours(updated)
    }

    private func makeUpdated(
        ringtoneId: String? = nil,
        inAppSound: Bool? = nil,
        vibration: Bool? = nil,
        quietHours: NotificationsSettingsViewModel.QuietHours? = nil
    ) -> NotificationsSettingsViewModel {
        NotificationsSettingsViewModel(
            ringtoneId: ringtoneId ?? viewModel.ringtoneId,
            inAppSoundEnabled: inAppSound ?? viewModel.inAppSoundEnabled,
            vibrationEnabled: vibration ?? viewModel.vibrationEnabled,
            quietHours: quietHours ?? viewModel.quietHours,
            mutedContactsCount: viewModel.mutedContactsCount
        )
    }
}

/// Notifications settings sub-screen. W26 design-token refactor —
/// migrates from stock SwiftUI `Form` to the new design vocabulary
/// (`SettingsSectionHeader` + `SettingsToggleRow` + custom picker
/// row with surfaceVariant background).
struct NotificationsSettingsScreen: View {
    @StateObject private var container: NotificationsSettingsContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    private let availableRingtones = ["qaudion-default", "classic", "pulse", "silent"]

    init(state: AppState) {
        _container = StateObject(wrappedValue: NotificationsSettingsContainer())
    }

    private var quietHoursRange: String {
        let qh = container.viewModel.quietHours
        return String(format: "%02d:%02d – %02d:%02d",
                      qh.startHour, qh.startMinute, qh.endHour, qh.endMinute)
    }

    /// W96: master switch for chat-message banners. Read by
    /// AppState.handleIncomingMessage before scheduling a UN
    /// notification. Persisted in UserDefaults so the preference
    /// sticks across launches; @AppStorage gives us automatic
    /// view re-render when the toggle changes.
    @AppStorage("qaudion.notifications.banners_enabled")
    private var bannersEnabled: Bool = true

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("BANNER")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Notifiche messaggi",
                            subtitle: "Mostra banner per i messaggi ricevuti",
                            isOn: $bannersEnabled
                        )
                    }
                    SettingsSectionHeader("SUONI")
                    VStack(spacing: 8) {
                        ringtonePickerRow
                        SettingsToggleRow(
                            title: "Suoni in-app",
                            subtitle: "Effetti sonori dentro l'app",
                            isOn: Binding(
                                get: { container.viewModel.inAppSoundEnabled },
                                set: { container.toggleInAppSound($0) }
                            )
                        )
                        SettingsToggleRow(
                            title: "Vibrazione",
                            subtitle: "Vibra alla ricezione di chiamate / messaggi",
                            isOn: Binding(
                                get: { container.viewModel.vibrationEnabled },
                                set: { container.toggleVibration($0) }
                            )
                        )
                    }

                    SettingsSectionHeader("MODALITÀ NON DISTURBARE")
                    VStack(spacing: 8) {
                        SettingsToggleRow(
                            title: "Attiva non disturbare",
                            subtitle: "Silenzia notifiche in fascia oraria",
                            isOn: Binding(
                                get: { container.viewModel.quietHours.enabled },
                                set: { container.toggleQuietHours($0) }
                            )
                        )
                        if container.viewModel.quietHours.enabled {
                            kvRow(label: "Fascia oraria",
                                  value: quietHoursRange,
                                  mono: true)
                            Text("Le chiamate in entrata e i messaggi sono silenziati durante questa fascia.")
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.onSurfaceVariant)
                                .padding(.horizontal, 14)
                        }
                    }

                    if container.viewModel.mutedContactsCount > 0 {
                        SettingsSectionHeader("CONTATTI SILENZIATI")
                        kvRow(label: "Contatti silenziati",
                              value: "\(container.viewModel.mutedContactsCount)",
                              mono: false)
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Notifiche")
    }

    // MARK: - Ringtone picker row

    private var ringtonePickerRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 22)

            Text("Suoneria")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)

            Spacer(minLength: 6)

            Picker("Suoneria", selection: Binding(
                get: { container.viewModel.ringtoneId },
                set: { container.setRingtone($0) }
            )) {
                ForEach(availableRingtones, id: \.self) { tone in
                    Text(tone.capitalized).tag(tone)
                }
            }
            .pickerStyle(.menu)
            .tint(scheme.primary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    // MARK: - kvRow helper

    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededN(mono: mono))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}

private struct MonoIfNeededN: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
