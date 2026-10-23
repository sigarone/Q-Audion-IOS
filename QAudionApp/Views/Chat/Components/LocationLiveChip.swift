import SwiftUI

/// The "Live" chip on a conversation of the list while the user shares their position there (docs/LOCATION_SHARING.md 1.4). A view of
/// its own, observing the center itself, so that the list does not redraw for every frame of a share. Nothing is drawn when no share runs.
struct LocationLiveChip: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @ObservedObject private var center: LocationShareCenter = LocationShareCenter.shared

    let peerUserId: String

    var body: some View {
        if center.activeShare(forPeer: peerUserId) != nil {
            HStack(spacing: 3) {
                Image(systemName: "location.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(verbatim: LocationCardStrings.chipLive)
                    .qaudionStyle(type.labelSmall)
            }
            .foregroundStyle(extras.success)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(extras.success.opacity(0.15)))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The notice shown once when a share of a previous run was found at launch and ended (WIRE_SPEC 14.6.1 rule 10).
struct LocationInterruptedAlertModifier: ViewModifier {
    @ObservedObject private var center: LocationShareCenter = LocationShareCenter.shared

    func body(content: Content) -> some View {
        content.alert(
            Text(verbatim: LocationCardStrings.interruptedTitle),
            isPresented: Binding(
                get: { center.interruptedNotice },
                set: { newValue in
                    if !newValue { center.interruptedNotice = false }
                }),
            actions: {
                Button(LocationCardStrings.interruptedOk, role: .cancel) { }
            },
            message: {
                Text(verbatim: LocationCardStrings.interruptedBody)
            })
    }
}

extension View {
    /// Tells the user, once, that a live share was ended because the app had been closed.
    func locationInterruptedAlert() -> some View {
        modifier(LocationInterruptedAlertModifier())
    }
}
