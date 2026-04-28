import SwiftUI

/// Device Management view matching Android's DeviceManagementScreen.
/// Shows linked devices, allows revoking, and device key management.
public struct DeviceManagementView: View {
    public let viewModel: DeviceManagementViewModel
    public var onRevoke: ((String) -> Void)?

    public init(viewModel: DeviceManagementViewModel = .mock,
                onRevoke: ((String) -> Void)? = nil) {
        self.viewModel = viewModel
        self.onRevoke = onRevoke
    }

    public var body: some View {
        List {
            ForEach(viewModel.devices, id: \.deviceId) { d in
                deviceRow(d)
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Link new", systemImage: "plus") {
                    /* TODO: open NFC pairing flow */
                }
            }
        }
    }

    @ViewBuilder
    private func deviceRow(_ d: DeviceManagementViewModel.Device) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: platformIcon(d.platform))
                .font(.title2)
                .foregroundStyle(d.isCurrentDevice ? .green : .blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(d.deviceName).font(.body.weight(.medium))
                    if d.isCurrentDevice {
                        Text("Current").font(.caption).foregroundStyle(.green)
                    }
                }
                Text("Linked \(d.linkedAt, style: .date)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Last seen \(d.lastSeen, style: .relative)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if d.canRevoke {
                Button("Revoke", role: .destructive) {
                    onRevoke?(d.deviceId)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func platformIcon(_ p: DeviceManagementViewModel.Device.Platform) -> String {
        switch p {
        case .iOS: return "apple.logo"
        case .android: return "circle.grid.2x2.fill"
        case .desktop: return "desktopcomputer"
        case .unknown: return "questionmark.app"
        }
    }
}

#Preview {
    NavigationStack { DeviceManagementView() }
}
