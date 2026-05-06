import SwiftUI

/// Small monospace pill used everywhere in the call UI to surface a
/// status or meta value (e.g. "PQC ACTIVE", "RE-KEY 4m 12s",
/// "VOICE VERIFIED", "RELAY"). 1:1 port of Android
/// `qaudion-android-new/feature/feature-call/.../components/MetaPill.kt`.
///
/// Two visual states:
///   - `filled = false` (default) — transparent fill, 1pt border at
///     `accent @ 0.55α`, label at `accent`.
///   - `filled = true`             — soft fill `accent @ 0.18α`,
///     same border, same label color.
///
/// Padding 10pt h / 4pt v. Shape: full pill (capsule). Letter spacing
/// 1.3sp matches the Compose source.
struct MetaPill: View {
    @Environment(\.qaudionType) private var type

    let label: String
    let accent: Color
    let filled: Bool

    init(_ label: String, accent: Color, filled: Bool = false) {
        self.label = label
        self.accent = accent
        self.filled = filled
    }

    var body: some View {
        Text(label)
            .qaudionStyle(type.labelSmall)
            .tracking(1.3)
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(filled ? accent.opacity(0.18) : Color.clear))
            .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            MetaPill("PQC ACTIVE", accent: .purple)
            MetaPill("VOICE VERIFIED", accent: .green, filled: true)
            MetaPill("LOW RISK · C=0.94", accent: .green)
        }
        HStack(spacing: 8) {
            MetaPill("RE-KEY 4m 12s", accent: .purple)
            MetaPill("LIVENESS OK", accent: .green, filled: true)
            MetaPill("PSK ROTATION OK", accent: .green)
        }
        HStack(spacing: 8) {
            MetaPill("P2P SRTP", accent: .green, filled: true)
            MetaPill("TURN", accent: .green)
            MetaPill("RELAY", accent: .green)
            MetaPill("CONNECTING…", accent: .gray)
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .qAudionTheme(dark: true)
}
