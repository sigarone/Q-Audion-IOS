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

/// Device management sub-screen. W31 design-token refactor.
/// Replaces stock `List` with a sectioned ScrollView using the new
/// design vocabulary.
struct DeviceManagementScreen: View {
    @ObservedObject var container: DeviceManagementContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        let c = DeviceManagementContainer()
        self._container = ObservedObject(wrappedValue: c)
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("DISPOSITIVI COLLEGATI")
                    VStack(spacing: 8) {
                        ForEach(container.viewModel.devices, id: \.deviceId) { device in
                            DeviceRow(device: device) {
                                container.revoke(deviceId: device.deviceId)
                            }
                        }
                    }
                    if container.viewModel.devices.isEmpty {
                        Text("Nessun dispositivo collegato.")
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.horizontal, 14).padding(.top, 12)
                    }
                    Spacer().frame(height: 16)
                    Text("Revocare un dispositivo lo disconnetterà immediatamente. Le chiavi di sessione di quel dispositivo saranno invalidate.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14)
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Dispositivi")
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let device: DeviceManagementViewModel.Device
    let onRevoke: () -> Void

    private var platformIcon: String {
        switch device.platform {
        case .iOS:     return "iphone"
        case .android: return "phone.connection"
        case .desktop: return "laptopcomputer"
        case .unknown: return "questionmark.circle"
        }
    }

    private var lastSeenText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: device.lastSeen, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: platformIcon)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(scheme.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.deviceName)
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                        .lineLimit(1)
                    if device.isCurrentDevice {
                        Text("ATTUALE")
                            .qaudionStyle(type.labelSmall)
                            .tracking(1.0)
                            .foregroundStyle(scheme.onPrimary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(scheme.primary))
                    }
                }
                Text("Visto \(lastSeenText)")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Text(device.platform.rawValue)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .modifier(MonoIfNeededD(mono: true))
            }

            Spacer(minLength: 8)

            if device.canRevoke {
                Button(action: onRevoke) {
                    Text("Revoca")
                        .qaudionStyle(type.labelMedium)
                        .foregroundStyle(extras.riskHigh)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(
                            Capsule().stroke(extras.riskHigh.opacity(0.55), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}

private struct MonoIfNeededD: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
