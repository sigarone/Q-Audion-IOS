import SwiftUI

/// Profile hero card rendered at the top of the new `SettingsScreen`
/// root. 1:1 port of Android `ProfileHero` from
/// `qaudion-android-new/feature/feature-settings/.../SettingsUi.kt`.
///
/// Layout (left → right):
///   - 72pt `QAudionAvatar` with the user's display name + image
///   - column, claiming the rest of the row: display name (titleLarge,
///     semibold) + identity line (mono `labelSmall`, e.g.
///     "#103 · +393331234567") + status (italic `bodySmall`, optional) +
///     the "MODIFICA" pill
///
/// The pill sits UNDER the text, not beside it. As a trailing sibling it
/// took roughly 100pt off a `.lineLimit(1)` identity line — invisible while
/// that line was a short "103 · …d2e9", and immediately a truncation the
/// moment it carries a real phone number.
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

                Spacer().frame(height: 6)

                Button(action: onEditTap) {
                    Text("MODIFICA")
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
            // Claims the width the trailing Spacer used to take. Deleting
            // that Spacer is not optional: it and this VStack are both
            // flexible along the HStack axis, so SwiftUI would have split
            // the freed width between them and the identity line would have
            // gained only half of what the move intends.
            .frame(maxWidth: .infinity, alignment: .leading)
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
    VStack(spacing: 12) {
        ProfileHeroCard(
            displayName: "Mario Rossi",
            handle: "#103 · +393331234567",
            statusMessage: "In riunione fino alle 18"
        )
        // The no-status case is a real state now that the canned
        // "Disponibile per chiamate sicure." default is gone, so it gets
        // its own preview rather than being invisible until runtime.
        ProfileHeroCard(
            displayName: "Anna Bianchi",
            handle: "#104 · +393337654321"
        )
        Spacer()
    }
    .padding()
    .background(Color.black)
    .qAudionTheme(dark: true)
}
