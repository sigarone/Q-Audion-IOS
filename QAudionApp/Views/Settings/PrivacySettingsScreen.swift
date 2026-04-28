import SwiftUI
import QAudionEngine

@MainActor
final class PrivacySettingsContainer: ObservableObject {
    @Published var viewModel: PrivacySettingsViewModel
    init(initial: PrivacySettingsViewModel = .mock) { self.viewModel = initial }
}

struct PrivacySettingsScreen: View {
    @ObservedObject var container: PrivacySettingsContainer

    @State private var readReceipts: Bool
    @State private var typingIndicator: Bool
    @State private var presenceVisible: Bool
    @State private var disappearingDuration: TimeInterval
    @State private var torEnabled: Bool

    init(state: AppState) {
        let c = PrivacySettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
        self._readReceipts = State(initialValue: c.viewModel.readReceiptsEnabled)
        self._typingIndicator = State(initialValue: c.viewModel.typingIndicatorEnabled)
        self._presenceVisible = State(initialValue: c.viewModel.presenceVisibleToContacts)
        self._disappearingDuration = State(initialValue: c.viewModel.disappearingMessagesDuration)
        self._torEnabled = State(initialValue: c.viewModel.torEnabled)
    }

    private let durationOptions: [(label: String, value: TimeInterval)] = [
        ("Off", 0),
        ("1 minute", 60),
        ("1 hour", 3600),
        ("1 day", 86400),
        ("7 days", 604800)
    ]

    var body: some View {
        Form {
            Section("Messaging") {
                Toggle("Read Receipts", isOn: $readReceipts)
                Toggle("Typing Indicators", isOn: $typingIndicator)
                Toggle("Show Presence to Contacts", isOn: $presenceVisible)
            }

            Section("Disappearing Messages") {
                Picker("Duration", selection: $disappearingDuration) {
                    ForEach(durationOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Network Anonymisation") {
                Toggle("Route via Tor", isOn: $torEnabled)
                if torEnabled {
                    Text("All traffic routed through Tor. Calls may experience higher latency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !container.viewModel.blockedUserIds.isEmpty {
                Section("Blocked Users") {
                    LabeledContent("Blocked") {
                        Text("\(container.viewModel.blockedUserIds.count) user(s)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Privacy")
    }
}
