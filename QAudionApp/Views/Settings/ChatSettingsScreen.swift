import SwiftUI
import QAudionEngine

@MainActor
final class ChatSettingsContainer: ObservableObject {
    @Published var viewModel: ChatSettingsViewModel
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.viewModel = store.loadChat()
    }

    func toggleReadReceipts(_ enabled: Bool) {
        viewModel = makeUpdated(readReceipts: enabled)
        store.saveChat(viewModel)
    }

    func toggleTypingIndicators(_ enabled: Bool) {
        viewModel = makeUpdated(typing: enabled)
        store.saveChat(viewModel)
    }

    func toggleMessagePreview(_ enabled: Bool) {
        viewModel = makeUpdated(preview: enabled)
        store.saveChat(viewModel)
    }

    private func makeUpdated(
        readReceipts: Bool? = nil,
        typing: Bool? = nil,
        preview: Bool? = nil
    ) -> ChatSettingsViewModel {
        ChatSettingsViewModel(
            readReceiptsEnabled: readReceipts ?? viewModel.readReceiptsEnabled,
            typingIndicatorsEnabled: typing ?? viewModel.typingIndicatorsEnabled,
            messagePreviewInNotifications: preview ?? viewModel.messagePreviewInNotifications
        )
    }
}

struct ChatSettingsScreen: View {
    @StateObject private var container: ChatSettingsContainer

    init(state: AppState) {
        _container = StateObject(wrappedValue: ChatSettingsContainer())
    }

    var body: some View {
        Form {
            Section("Interaction") {
                Toggle("Read Receipts", isOn: Binding(
                    get: { container.viewModel.readReceiptsEnabled },
                    set: { container.toggleReadReceipts($0) }
                ))
                Toggle("Typing Indicators", isOn: Binding(
                    get: { container.viewModel.typingIndicatorsEnabled },
                    set: { container.toggleTypingIndicators($0) }
                ))
            }

            Section("Notifications") {
                Toggle("Message Preview in Notifications", isOn: Binding(
                    get: { container.viewModel.messagePreviewInNotifications },
                    set: { container.toggleMessagePreview($0) }
                ))
                if container.viewModel.messagePreviewInNotifications {
                    Label("Message content will be visible on lock screen.", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Content hidden on lock screen — recommended for security.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Chat")
    }
}
