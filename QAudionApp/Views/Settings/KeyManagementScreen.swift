import SwiftUI
import QAudionEngine

@MainActor
final class KeyManagementContainer: ObservableObject {
    @Published var viewModel: KeyManagementViewModel
    init(initial: KeyManagementViewModel = .mock) { self.viewModel = initial }
}

struct KeyManagementScreen: View {
    @ObservedObject var container: KeyManagementContainer

    init(state: AppState) {
        let c = KeyManagementContainer()
        self._container = ObservedObject(wrappedValue: c)
    }

    private var lastRotationText: String {
        guard let date = container.viewModel.lastKeyRotation else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        Form {
            Section("Identity Key") {
                LabeledContent("User ID") {
                    Text(container.viewModel.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Fingerprint") {
                    Text(container.viewModel.fingerprint)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last Rotation") {
                    Text(lastRotationText)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Linked Devices") {
                ForEach(container.viewModel.linkedDevices, id: \.deviceId) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(device.deviceName)
                                if device.isCurrentDevice {
                                    Text("This device")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue, in: Capsule())
                                }
                            }
                            Text(device.deviceId)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
            }

            Section("Actions") {
                NavigationLink("Manage Keys (Advanced)") {
                    KeyManagementView()
                }
            }
        }
        .navigationTitle("Key Management")
    }
}
