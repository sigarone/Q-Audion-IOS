import SwiftUI

/// Device Management view matching Android's DeviceManagementScreen.
/// Shows linked devices, allows unlinking, and device key management.
public struct DeviceManagementView: View {

    public struct DeviceInfo: Identifiable {
        public let id: String
        public let name: String
        public let lastSeen: Date
        public let isCurrent: Bool
        public let hasPublicKey: Bool

        public init(id: String, name: String, lastSeen: Date, isCurrent: Bool, hasPublicKey: Bool) {
            self.id = id; self.name = name; self.lastSeen = lastSeen
            self.isCurrent = isCurrent; self.hasPublicKey = hasPublicKey
        }
    }

    @State private var devices: [DeviceInfo] = []
    @State private var isLoading = false

    public let onUnlinkDevice: (String) -> Void
    public let onRegisterKey: () -> Void
    public let loadDevices: () async -> [DeviceInfo]

    public init(onUnlinkDevice: @escaping (String) -> Void = { _ in },
                onRegisterKey: @escaping () -> Void = {},
                loadDevices: @escaping () async -> [DeviceInfo] = { [] }) {
        self.onUnlinkDevice = onUnlinkDevice
        self.onRegisterKey = onRegisterKey
        self.loadDevices = loadDevices
    }

    public var body: some View {
        List {
            Section("This Device") {
                if let current = devices.first(where: { $0.isCurrent }) {
                    deviceRow(current)
                }

                Button(action: onRegisterKey) {
                    Label("Register Device Key", systemImage: "key.fill")
                }
            }

            Section("Linked Devices") {
                if devices.filter({ !$0.isCurrent }).isEmpty {
                    Text("No other devices linked")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(devices.filter { !$0.isCurrent }) { device in
                        deviceRow(device)
                            .swipeActions {
                                Button("Unlink", role: .destructive) {
                                    onUnlinkDevice(device.id)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .refreshable {
            devices = await loadDevices()
        }
        .task {
            devices = await loadDevices()
        }
    }

    private func deviceRow(_ device: DeviceInfo) -> some View {
        HStack {
            Image(systemName: device.isCurrent ? "iphone" : "desktopcomputer")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading) {
                HStack {
                    Text(device.name)
                        .font(.body)
                    if device.isCurrent {
                        Text("Current")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                Text("Last seen: \(device.lastSeen, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if device.hasPublicKey {
                Image(systemName: "key.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
    }
}
