import SwiftUI

/// Small uppercase trust chip used in `ContactRow` and `ContactDetailScreen`
/// (e.g. "PQC", "VOICE", "ENTERPRISE"). 1:1 port of Android trust pill from
/// `qaudion-android-new/feature/feature-contacts/.../ContactsUi.kt`.
///
/// Capsule, monospace, 1.2sp tracking. Foreground = `accent`, fill =
/// `accent @ 0.18α`, border = `accent @ 0.55α`.
struct TrustChip: View {
    @Environment(\.qaudionType) private var type

    let label: String
    let accent: Color

    init(_ label: String, accent: Color) {
        self.label = label
        self.accent = accent
    }

    var body: some View {
        Text(label)
            .qaudionStyle(type.labelSmall)
            .tracking(1.2)
            .foregroundStyle(accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(accent.opacity(0.18)))
            .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
    }
}

#Preview {
    HStack(spacing: 6) {
        TrustChip("PQC", accent: .purple)
        TrustChip("VOICE", accent: .green)
        TrustChip("ENTERPRISE", accent: .blue)
    }
    .padding()
    .qAudionTheme(dark: true)
}
