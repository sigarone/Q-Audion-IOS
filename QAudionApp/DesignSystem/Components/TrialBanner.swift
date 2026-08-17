import SwiftUI

/// Trial-countdown strip shown in Settings, next to the profile card, only
/// while the account is on an active Pro trial (design doc
/// docs/superpowers/specs/2026-08-17-client-pro-badge-trial-banner-design.md
/// §2/§3 — never shown for Base or perpetual Pro).
struct TrialBanner: View {
    let daysRemaining: Int
    let onUpgradeTap: () -> Void

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prova Pro attiva")
                    .qaudionStyle(type.titleSmall)
                    .fontWeight(.semibold)
                    .foregroundStyle(scheme.primary)
                Text(daysRemaining == 1 ? "Scade domani" : "Scade tra \(daysRemaining) giorni")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Spacer(minLength: 8)
            Button("Passa a Pro", action: onUpgradeTap)
                .buttonStyle(.borderless)
                .foregroundStyle(scheme.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.primary.opacity(0.12))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
