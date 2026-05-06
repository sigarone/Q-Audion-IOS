import SwiftUI

/// Tiny "PQC" pill that lights up in the chat top-bar when the conversation
/// is using post-quantum (ML-KEM-1024) key exchange. 1:1 port of the Android
/// `PqcBadge` from
/// `qaudion-android-new/feature/feature-chat/.../components/PqcBadge.kt`.
///
/// Visually compact: 18pt tall capsule, `pqcAccent` foreground, fill =
/// `pqcAccent @ 0.18α`, border = `pqcAccent @ 0.55α`. The label is the
/// monospace text "PQC" in `labelSmall` weight. When `active == false`
/// the badge dims to 35% opacity (it stays present so the topbar layout
/// is stable, instead of jumping when key exchange completes).
struct PqcBadge: View {
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let active: Bool

    var body: some View {
        Text("PQC")
            .qaudionStyle(type.labelSmall)
            .tracking(1.2)
            .foregroundStyle(extras.pqcAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(extras.pqcAccent.opacity(0.18)))
            .overlay(Capsule().stroke(extras.pqcAccent.opacity(0.55), lineWidth: 1))
            .opacity(active ? 1.0 : 0.35)
            .accessibilityLabel(active
                ? "Post-quantum key exchange active"
                : "Post-quantum key exchange inactive")
    }
}

#Preview {
    HStack(spacing: 12) {
        PqcBadge(active: true)
        PqcBadge(active: false)
    }
    .padding()
    .qAudionTheme(dark: true)
}
