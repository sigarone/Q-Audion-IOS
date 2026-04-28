import SwiftUI
import QAudionEngine

@MainActor
final class NotificationsSettingsContainer: ObservableObject {
    @Published var viewModel: NotificationsSettingsViewModel
    init(initial: NotificationsSettingsViewModel = .mock) { self.viewModel = initial }
}

struct NotificationsSettingsScreen: View {
    @ObservedObject var container: NotificationsSettingsContainer

    @State private var ringtoneId: String
    @State private var inAppSound: Bool
    @State private var vibration: Bool
    @State private var quietHoursEnabled: Bool

    private let availableRingtones = ["qaudion-default", "classic", "pulse", "silent"]

    init(state: AppState) {
        let c = NotificationsSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
        self._ringtoneId = State(initialValue: c.viewModel.ringtoneId)
        self._inAppSound = State(initialValue: c.viewModel.inAppSoundEnabled)
        self._vibration = State(initialValue: c.viewModel.vibrationEnabled)
        self._quietHoursEnabled = State(initialValue: c.viewModel.quietHours.enabled)
    }

    private var quietHoursRange: String {
        let qh = container.viewModel.quietHours
        return String(format: "%02d:%02d – %02d:%02d",
                      qh.startHour, qh.startMinute, qh.endHour, qh.endMinute)
    }

    var body: some View {
        Form {
            Section("Sounds") {
                Picker("Ringtone", selection: $ringtoneId) {
                    ForEach(availableRingtones, id: \.self) { tone in
                        Text(tone).tag(tone)
                    }
                }
                Toggle("In-App Sound", isOn: $inAppSound)
                Toggle("Vibration", isOn: $vibration)
            }

            Section("Quiet Hours") {
                Toggle("Enable Quiet Hours", isOn: $quietHoursEnabled)
                if quietHoursEnabled {
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
        .navigationTitle("Notifications")
    }
}
