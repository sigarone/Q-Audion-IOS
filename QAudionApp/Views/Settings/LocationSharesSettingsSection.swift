import SwiftUI

/// Settings > Privacy > "Posizione condivisa": the live shares this device is running, each with the contact and the time it ends, and
/// "Interrompi tutte" (docs/LOCATION_SHARING.md 1.4). Appears only while location sharing is enabled, and observes the center itself.
/// Takes no AppState (CLAUDE.md section 16).
struct LocationSharesSettingsSection: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @ObservedObject private var center: LocationShareCenter = LocationShareCenter.shared

    var body: some View {
        if LocationShareCenter.isFeatureEnabled {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(LocationCardStrings.settingsTitle.uppercased())
            VStack(alignment: .leading, spacing: 10) {
                if center.activeShares.isEmpty {
                    Text(verbatim: LocationCardStrings.settingsNone)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                } else {
                    ForEach(center.activeShares) { share in
                        Text(verbatim: rowText(share))
                            .qaudionStyle(type.bodyMedium)
                            .foregroundStyle(scheme.onSurface)
                    }
                    Button(action: { center.stopAllFromUser() }) {
                        Text(verbatim: LocationCardStrings.settingsStopAll)
                            .qaudionStyle(type.labelMedium)
                            .foregroundStyle(scheme.onError)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(scheme.error))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
    }

    private func rowText(_ share: LocationShareCenter.ActiveShare) -> String {
        let name: String = DisplayName.forUser(share.peerUserId)
        return LocationCardStrings.settingsRow(name: name, clock: LocationCardFormat.clock(share.endAt))
    }
}
