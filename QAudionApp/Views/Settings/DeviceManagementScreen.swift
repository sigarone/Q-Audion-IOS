import SwiftUI
import QAudionEngine

@MainActor
final class DeviceManagementContainer: ObservableObject {
    @Published var viewModel: DeviceManagementViewModel

    init(initial: DeviceManagementViewModel = .mock) { self.viewModel = initial }

    func revoke(deviceId: String) {
        // Stub: real revocation wired to backend in follow-on task
        print("[DeviceManagementContainer] revoke(deviceId: \(deviceId)) — stubbed")
    }
}

struct DeviceManagementScreen: View {
    @ObservedObject var container: DeviceManagementContainer

    init(state: AppState) {
        let c = DeviceManagementContainer()
        self._container = ObservedObject(wrappedValue: c)
    }

    var body: some View {
        List(container.viewModel.devices, id: \.deviceId) { device in
            DeviceRow(device: device) {
                container.revoke(deviceId: device.deviceId)
            }
        }
        .navigationTitle("Dispositivi")
    }
}

private struct DeviceRow: View {
    let device: DeviceManagementViewModel.Device
    let onRevoke: () -> Void

    private var platformIcon: String {
        switch device.platform {
        case .iOS: return "iphone"
        case .android: return "phone"
        case .desktop: return "laptopcomputer"
        case .unknown: return "questionmark.circle"
        }
    }

    private var lastSeenText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: device.lastSeen, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: platformIcon)
                .frame(width: 28)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(device.deviceName)
                        .font(.body)
                    if device.isCurrentDevice {
                        Text("This device")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue, in: Capsule())
                    }
                }
                Text("Last seen \(lastSeenText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(device.platform.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if device.canRevoke {
                Button(role: .destructive) {
                    onRevoke()
                } label: {
                    Text("Revoke")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
