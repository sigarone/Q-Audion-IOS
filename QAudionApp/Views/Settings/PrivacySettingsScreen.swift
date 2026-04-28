import SwiftUI
import QAudionEngine

@MainActor
final class PrivacySettingsContainer: ObservableObject {
    @Published var viewModel: PrivacySettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.viewModel = store.loadPrivacy()
    }

    func toggleReadReceipts(_ enabled: Bool) {
        viewModel = makeUpdated(readReceipts: enabled)
        store.savePrivacy(viewModel)
    }

    func toggleTypingIndicator(_ enabled: Bool) {
        viewModel = makeUpdated(typing: enabled)
        store.savePrivacy(viewModel)
    }

    func togglePresence(_ enabled: Bool) {
        viewModel = makeUpdated(presence: enabled)
        store.savePrivacy(viewModel)
    }

    func setDisappearingDuration(_ seconds: TimeInterval) {
        viewModel = makeUpdated(disappearing: seconds)
        store.savePrivacy(viewModel)
    }

    func toggleTor(_ enabled: Bool) {
        viewModel = makeUpdated(tor: enabled)
        store.savePrivacy(viewModel)
    }

    private func makeUpdated(
        readReceipts: Bool? = nil,
        typing: Bool? = nil,
        presence: Bool? = nil,
        disappearing: TimeInterval? = nil,
        tor: Bool? = nil
    ) -> PrivacySettingsViewModel {
        PrivacySettingsViewModel(
            readReceiptsEnabled: readReceipts ?? viewModel.readReceiptsEnabled,
            typingIndicatorEnabled: typing ?? viewModel.typingIndicatorEnabled,
            presenceVisibleToContacts: presence ?? viewModel.presenceVisibleToContacts,
            disappearingMessagesDuration: disappearing ?? viewModel.disappearingMessagesDuration,
            blockedUserIds: viewModel.blockedUserIds,
            torEnabled: tor ?? viewModel.torEnabled
        )
    }
}

struct PrivacySettingsScreen: View {
    @StateObject private var container: PrivacySettingsContainer

    init(state: AppState) {
        _container = StateObject(wrappedValue: PrivacySettingsContainer())
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
                Toggle("Read Receipts", isOn: Binding(
                    get: { container.viewModel.readReceiptsEnabled },
                    set: { container.toggleReadReceipts($0) }
                ))
                Toggle("Typing Indicators", isOn: Binding(
                    get: { container.viewModel.typingIndicatorEnabled },
                    set: { container.toggleTypingIndicator($0) }
                ))
                Toggle("Show Presence to Contacts", isOn: Binding(
                    get: { container.viewModel.presenceVisibleToContacts },
                    set: { container.togglePresence($0) }
                ))
            }

            Section("Disappearing Messages") {
                Picker("Duration", selection: Binding(
                    get: { container.viewModel.disappearingMessagesDuration },
                    set: { container.setDisappearingDuration($0) }
                )) {
                    ForEach(durationOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Network Anonymisation") {
                Toggle("Route via Tor", isOn: Binding(
                    get: { container.viewModel.torEnabled },
                    set: { container.toggleTor($0) }
                ))
                if container.viewModel.torEnabled {
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
