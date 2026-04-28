import SwiftUI
import QAudionEngine

@MainActor
final class ChatSettingsContainer: ObservableObject {
    @Published var viewModel: ChatSettingsViewModel
    init(initial: ChatSettingsViewModel = .mock) { self.viewModel = initial }
}

struct ChatSettingsScreen: View {
    @ObservedObject var container: ChatSettingsContainer

    @State private var readReceipts: Bool
    @State private var typingIndicators: Bool
    @State private var messagePreview: Bool

    init(state: AppState) {
        let c = ChatSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
        self._readReceipts = State(initialValue: c.viewModel.readReceiptsEnabled)
        self._typingIndicators = State(initialValue: c.viewModel.typingIndicatorsEnabled)
        self._messagePreview = State(initialValue: c.viewModel.messagePreviewInNotifications)
    }

    var body: some View {
        Form {
            Section("Interaction") {
                Toggle("Read Receipts", isOn: $readReceipts)
                Toggle("Typing Indicators", isOn: $typingIndicators)
            }

            Section("Notifications") {
                Toggle("Message Preview in Notifications", isOn: $messagePreview)
                if messagePreview {
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
