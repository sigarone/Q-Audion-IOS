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

struct NotificationsSettingsScreen: View {
    @StateObject private var container: NotificationsSettingsContainer

    private let availableRingtones = ["qaudion-default", "classic", "pulse", "silent"]

    init(state: AppState) {
        _container = StateObject(wrappedValue: NotificationsSettingsContainer())
    }

    private var quietHoursRange: String {
        let qh = container.viewModel.quietHours
        return String(format: "%02d:%02d – %02d:%02d",
                      qh.startHour, qh.startMinute, qh.endHour, qh.endMinute)
    }

    var body: some View {
        Form {
            Section("Sounds") {
                Picker("Ringtone", selection: Binding(
                    get: { container.viewModel.ringtoneId },
                    set: { container.setRingtone($0) }
                )) {
                    ForEach(availableRingtones, id: \.self) { tone in
                        Text(tone).tag(tone)
                    }
                }
                Toggle("In-App Sound", isOn: Binding(
                    get: { container.viewModel.inAppSoundEnabled },
                    set: { container.toggleInAppSound($0) }
                ))
                Toggle("Vibration", isOn: Binding(
                    get: { container.viewModel.vibrationEnabled },
                    set: { container.toggleVibration($0) }
                ))
            }

            Section("Quiet Hours") {
                Toggle("Enable Quiet Hours", isOn: Binding(
                    get: { container.viewModel.quietHours.enabled },
                    set: { container.toggleQuietHours($0) }
                ))
                if container.viewModel.quietHours.enabled {
                    LabeledContent("Window") {
                        Text(quietHoursRange)
                            .foregroundStyle(.secondary)
                    }
                    Text("Incoming call and message sounds are muted during this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if container.viewModel.mutedContactsCount > 0 {
                Section("Muted") {
                    LabeledContent("Muted Contacts") {
                        Text("\(container.viewModel.mutedContactsCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Notifiche")
    }
}
