import SwiftUI

/// Small "PRO" pill shown next to the Q-Audion wordmark when the account is
/// unlocked — perpetual Pro or an active Pro trial alike (design doc
/// docs/superpowers/specs/2026-08-17-client-pro-badge-trial-banner-design.md
/// §2: "a trial is functionally full Pro access for its duration"). Purely
/// visual, not tappable — same non-interactive convention as `RiskPill`.
struct ProBadge: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        Text("PRO")
            .qaudionStyle(type.labelSmall)
            .tracking(1.2)
            .foregroundStyle(scheme.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(scheme.primary.opacity(0.18)))
            .overlay(Capsule().stroke(scheme.primary.opacity(0.55), lineWidth: 1))
    }
}

#Preview {
    ProBadge()
        .padding()
        .background(Color.black)
        .qAudionTheme(dark: true)
}
