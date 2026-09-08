import SwiftUI

/// Single navigation / action row used inside `SettingsScreen` and any
/// other Settings sub-screen that adopts the design tokens. 1:1 port
/// of Android `SettingsRow` from
/// `qaudion-android-new/feature/feature-settings/.../SettingsUi.kt`.
///
/// **Important** — this row is *presentational*. It does NOT wrap its
/// content in a `Button`. Callers compose it themselves:
///
///   - **Navigation**: `NavigationLink { destination } label: { SettingsRow(...) }`
///   - **Action**:     `Button { action() } label: { SettingsRow(...) }`
///
/// Wrapping the inner HStack in a Button (the original W24 design)
/// caused the inner Button to swallow taps when the row was placed
/// inside a NavigationLink — the link never fired and the entire
/// SettingsScreen root became non-navigable. Refactor flagged by
/// OpenRouter review on v1.0.65 build verdict.
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
/// 56pt.
///
/// Set `destructive = true` for "Esci" / "Cancellazione remota": tints
/// the icon + title with `extras.riskHigh` and removes the chevron.
struct SettingsRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let icon: String
    let iconColor: Color?
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let mono: Bool
    let trailingBadge: LocalizedStringKey?
    let trailingBadgeColor: Color?
    let destructive: Bool

    // W-L10N-BATCH2 (2026-09-08) — title/subtitle/trailingBadge were plain
    // String: Text(aStringValue) always uses the verbatim StringProtocol
    // overload, never the LocalizedStringKey one, so every row using this
    // component was permanently untranslatable regardless of the String
    // Catalog or the in-app language override — confirmed by a dedicated
    // audit after real device testing. Every existing call site passes a
    // string LITERAL for title (and almost all for subtitle/trailingBadge),
    // which keeps compiling unchanged since a literal satisfies either type;
    // the handful of call sites passing a runtime String wrap it in
    // `LocalizedStringKey(value)` at the call site (verbatim display, no
    // catalog lookup surprise — correct for genuinely dynamic content like a
    // profile name or a byte count).
    init(icon: String,
         iconColor: Color? = nil,
         title: LocalizedStringKey,
         subtitle: LocalizedStringKey? = nil,
         mono: Bool = false,
         trailingBadge: LocalizedStringKey? = nil,
         trailingBadgeColor: Color? = nil,
         destructive: Bool = false) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.mono = mono
        self.trailingBadge = trailingBadge
        self.trailingBadgeColor = trailingBadgeColor
        self.destructive = destructive
    }

    var body: some View {
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
        .contentShape(Rectangle())
    }
}

/// Helper modifier that applies `.font(.system(.caption, design: .monospaced))`
/// when `mono == true`.
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
        // Navigation row example (caller wraps in NavigationLink).
        SettingsRow(icon: "person", title: "Profilo",
                    subtitle: "Mario Rossi · Int. 103")
        // Plain layout row.
        SettingsRow(icon: "iphone", iconColor: .blue, title: "Dispositivi collegati",
                    subtitle: "1 dispositivo")
        SettingsRow(icon: "key.fill", iconColor: .purple,
                    title: "Gestione chiavi",
                    subtitle: "PSK rotazione attiva",
                    trailingBadge: "ATTIVO")
        SettingsRow(icon: "info.circle", title: "Versione",
                    subtitle: "1.0.66 · build 122",
                    mono: true)
        SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Esci",
                    destructive: true)
    }
    .padding()
    .background(Color.black)
    .qAudionTheme(dark: true)
}
