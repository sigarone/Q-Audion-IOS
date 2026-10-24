import SwiftUI

/// The strip above the composer while the user shares their position live in this conversation: "Stai condividendo la posizione fino alle
/// HH:MM" with "Interrompi" (docs/LOCATION_SHARING.md 1.4). Stopping is one tap, with no confirmation. Nothing is drawn when no share runs
/// here, so the screen carries no trace of the feature.
struct LocationLiveStrip: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var center: LocationShareCenter = LocationShareCenter.shared

    let peerUserId: String

    var body: some View {
        if let share = center.activeShare(forPeer: peerUserId) {
            strip(share)
        }
    }

    private var floatsAsGlass: Bool {
        QAudionGlassStyle.resolve(
            osSupportsGlass: QAudionGlassStyle.osSupportsGlass,
            reduceTransparency: reduceTransparency,
            increaseContrast: contrast == .increased) == .glass
    }

    private func strip(_ share: LocationShareCenter.ActiveShare) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "location.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(extras.success)
            Text(verbatim: LocationCardStrings.stripText(until: LocationCardFormat.clock(share.endAt)))
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.success)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button(action: { center.stopFromUser(peerUserId: peerUserId) }) {
                Text(verbatim: LocationCardStrings.stop)
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.onError)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(scheme.error))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // Floats above the composer as a rounded Liquid Glass card (untinted, so the green text keeps its contrast);
        // where glass is not used it stays the full-width tinted band it was.
        .qaudionGlassSurface(in: RoundedRectangle(cornerRadius: floatsAsGlass ? 16 : 0),
                             fallback: extras.success.opacity(0.12))
        .padding(.horizontal, floatsAsGlass ? 12 : 0)
        .padding(.vertical, floatsAsGlass ? 4 : 0)
        .accessibilityElement(children: .combine)
    }
}
