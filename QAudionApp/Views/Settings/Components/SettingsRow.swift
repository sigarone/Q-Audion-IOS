import SwiftUI

/// Single navigation / action row used inside `SettingsScreen` and any
/// other Settings sub-screen that adopts the design tokens. 1:1 port
/// of Android `SettingsRow` from
/// `qaudion-android-new/feature/feature-settings/.../SettingsUi.kt`.
///
/// Layout (left → right):
///   - 22pt leading icon (SF Symbol), `iconColor` tint
///   - Title (`bodyMedium` medium weight, `onSurface`)
///   - Optional subtitle (`labelSmall`, `onSurfaceVariant`,
///     `.monospaced` if `mono == true`)
///   - Optional trailing badge text (uppercase, success-colored)
///   - Trailing chevron `chevron.right` 13pt `onSurfaceVariant`
///     (suppressed when `destructive == true`)
///
/// Background = `scheme.surfaceVariant @ 0.4α`, 12pt corner. Min height
/// 56pt. Tap closes via `action`.
///
/// Set `destructive = true` for "Esci" / "Cancellazione remota": tints
/// the icon + title with `extras.riskHigh` and removes the chevron.
struct SettingsRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let icon: String
    let iconColor: Color?
    let title: String
    let subtitle: String?
    let mono: Bool
    let trailingBadge: String?
    let trailingBadgeColor: Color?
    let destructive: Bool
    let action: () -> Void

    init(icon: String,
         iconColor: Color? = nil,
         title: String,
         subtitle: String? = nil,
         mono: Bool = false,
         trailingBadge: String? = nil,
         trailingBadgeColor: Color? = nil,
         destructive: Bool = false,
         action: @escaping () -> Void) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.mono = mono
        self.trailingBadge = trailingBadge
        self.trailingBadgeColor = trailingBadgeColor
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(destructive ? extras.riskHigh
                                                  : (iconColor ?? scheme.onSurfaceVariant))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(destructive ? extras.riskHigh : scheme.onSurface)
                    if let subtitle {
                        Text(subtitle)
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .lineLimit(2)
                            .modifier(MonoIfNeeded(mono: mono))
                    }
                }

                Spacer(minLength: 6)

                if let trailingBadge {
                    Text(trailingBadge)
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.0)
                        .foregroundStyle(trailingBadgeColor ?? extras.success)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            Capsule().fill((trailingBadgeColor ?? extras.success).opacity(0.18))
                        )
                }

                if !destructive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }
}

/// Helper modifier that applies `.font(.system(.caption, design: .monospaced))`
/// when `mono == true` — needed because `.monospaced()` on Text isn't
/// available pre-iOS 16, and we want a one-line conditional.
private struct MonoIfNeeded: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        SettingsRow(icon: "person", title: "Profilo",
                    subtitle: "Mario Rossi · Int. 103", action: {})
        SettingsRow(icon: "iphone", iconColor: .blue, title: "Dispositivi collegati",
                    subtitle: "1 dispositivo", action: {})
        SettingsRow(icon: "key.fill", iconColor: .purple,
                    title: "Gestione chiavi",
                    subtitle: "PSK rotazione attiva",
                    trailingBadge: "ATTIVO", action: {})
        SettingsRow(icon: "info.circle", title: "Versione",
                    subtitle: "1.0.60 · build 121",
                    mono: true, action: {})
        SettingsRow(icon: "eye.slash.fill", title: "Esci",
                    destructive: true, action: {})
    }
    .padding()
    .background(Color.black)
    .qAudionTheme(dark: true)
}
