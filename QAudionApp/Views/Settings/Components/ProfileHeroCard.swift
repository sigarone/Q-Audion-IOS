import SwiftUI

/// Profile hero card rendered at the top of the new `SettingsScreen`
/// root. 1:1 port of Android `ProfileHero` from
/// `qaudion-android-new/feature/feature-settings/.../SettingsUi.kt`.
///
/// Layout (left → right):
///   - 72pt `QAudionAvatar` with the user's display name + image
///   - column: display name (titleLarge, semibold) + handle (mono
///     `labelSmall`, e.g. "103 · 7f3b…d2e9" — bare digits, no "Int."
///     prefix, Pavel 2026-07-29) + status (italic `bodySmall`, optional)
///   - trailing 28pt "EDIT" pill (capsule, 1pt primary border, mono)
///
/// Card surface = `scheme.surface`, 1pt `primary @ 0.5α` border,
/// 4pt corner radius.
struct ProfileHeroCard: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let displayName: String
    let handle: String?
    let statusMessage: String?
    let avatarUrl: URL?
    let onEditTap: () -> Void
    /// Numero interno PBX (es. "103") da mostrare nel cerchietto.
    /// Quando valorizzato sovrascrive le iniziali derivate dal displayName.
    let shortNumber: String?

    init(displayName: String,
         handle: String? = nil,
         statusMessage: String? = nil,
         avatarUrl: URL? = nil,
         shortNumber: String? = nil,
         onEditTap: @escaping () -> Void = {}) {
        self.displayName = displayName
        self.handle = handle
        self.statusMessage = statusMessage
        self.avatarUrl = avatarUrl
        self.shortNumber = shortNumber
        self.onEditTap = onEditTap
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            QAudionAvatar(displayName: displayName,
                          imageURL: avatarUrl,
                          size: 72,
                          shortNumber: shortNumber)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .qaudionStyle(type.titleLarge)
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                if let handle {
                    Text(handle)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .modifier(MonoCaption())
                        .lineLimit(1)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .qaudionStyle(type.bodySmall)
                        .italic()
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button(action: onEditTap) {
                Text("EDIT")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.2)
                    .foregroundStyle(scheme.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .overlay(
                        Capsule().stroke(scheme.primary, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Modifica profilo")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(scheme.primary.opacity(0.5), lineWidth: 1)
        )
    }
}

private struct MonoCaption: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(.caption, design: .monospaced))
    }
}

#Preview {
    VStack {
        ProfileHeroCard(
            displayName: "Mario Rossi",
            handle: "103 · 7f3b…d2e9",
            statusMessage: "Disponibile per chiamate sicure."
        )
        Spacer()
    }
    .padding()
    .background(Color.black)
    .qAudionTheme(dark: true)
}
