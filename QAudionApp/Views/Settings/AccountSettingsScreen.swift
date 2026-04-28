import SwiftUI
import QAudionEngine

@MainActor
final class AccountSettingsContainer: ObservableObject {
    @Published var viewModel: AccountSettingsViewModel
    init(initial: AccountSettingsViewModel = .mock) { self.viewModel = initial }
}

struct AccountSettingsScreen: View {
    @ObservedObject var container: AccountSettingsContainer
    @State private var draftDisplayName: String

    init(state: AppState) {
        let c = AccountSettingsContainer()
        self._container = ObservedObject(wrappedValue: c)
        self._draftDisplayName = State(initialValue: c.viewModel.displayName ?? "")
    }

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("User ID") {
                    Text(container.viewModel.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Phone Hash") {
                    Text(String(container.viewModel.phoneHash.prefix(16)) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let ext = container.viewModel.dialExtension {
                    LabeledContent("Extension") {
                        Text(ext)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Profile") {
                TextField("Display name", text: $draftDisplayName)
                if let status = container.viewModel.statusMessage {
                    LabeledContent("Status") {
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Status") {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Account")
    }
}
