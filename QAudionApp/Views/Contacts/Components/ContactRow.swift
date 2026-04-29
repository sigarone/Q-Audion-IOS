import SwiftUI
import QAudionEngine

/// Single contact row used inside `ContactsScreen`. 1:1 port of Android
/// `ContactsRow` from `qaudion-android-new/feature/feature-contacts/.../ContactsUi.kt`.
///
/// Layout (left → right):
///   - 44pt `QAudionAvatar` with optional presence dot
///   - column: display name (titleSmall) + optional "NEW" pill +
///     extension line + trust chips inline (PQC / VOICE / ENTERPRISE)
///   - trailing icons: `bubble.right` (chat), `phone` (call) — both
///     tinted `scheme.primary`
///
/// Engine truth: `ContactsListViewModel.Item` provides `displayName`,
/// `isOnline`, `isVerified`, `unreadMessageCount`, `avatarUrl`, `phoneHash`.
/// Richer fields (extension number, voice-match status, enterprise tier,
/// presence enum beyond online/offline) aren't exposed yet; the row
/// derives sensible defaults — those become real bindings as the engine
/// surfaces them.
struct ContactRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let item: ContactsListViewModel.Item
    /// Optional one-line "Int. {n}" extension caption shown under the
    /// display name. nil hides the caption.
    let extensionLabel: String?
    /// Optional override for the presence dot. nil falls back to the
    /// `isOnline` heuristic.
    let presence: PresenceDot?
    let onChatTap: () -> Void
    let onCallTap: () -> Void

    init(item: ContactsListViewModel.Item,
         extensionLabel: String? = nil,
         presence: PresenceDot? = nil,
         onChatTap: @escaping () -> Void = {},
         onCallTap: @escaping () -> Void = {}) {
        self.item = item
        self.extensionLabel = extensionLabel
        self.presence = presence
        self.onChatTap = onChatTap
        self.onCallTap = onCallTap
    }

    var body: some View {
        HStack(spacing: 12) {
            QAudionAvatar(
                displayName: item.displayName,
                imageURL: item.avatarUrl,
                size: 44,
                presenceDot: presence ?? (item.isOnline ? .online : .offline)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                        .lineLimit(1)
                    if item.unreadMessageCount > 0 {
                        TrustChip("NEW", accent: extras.success)
                    }
                    Spacer(minLength: 0)
                }
                if let ext = extensionLabel {
                    Text(ext)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                trustPills
            }

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                Button(action: onChatTap) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 17))
                        .foregroundStyle(scheme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Apri chat con \(item.displayName)")

                Button(action: onCallTap) {
                    Image(systemName: "phone")
                        .font(.system(size: 17))
                        .foregroundStyle(scheme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chiama \(item.displayName)")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trustPills: some View {
        // The engine only carries `isVerified` today — show "PQC" + (if
        // verified) "VOICE". Enterprise tier is engine-side only and
        // not exposed to the iOS UI yet, so it doesn't render.
        HStack(spacing: 6) {
            TrustChip("PQC", accent: extras.pqcAccent)
            if item.isVerified {
                TrustChip("VOICE", accent: extras.success)
            }
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        ContactRow(item: ContactsListViewModel.mock.items[0],
                   extensionLabel: "Int. 103")
        Divider().background(Color.gray.opacity(0.2))
        ContactRow(item: ContactsListViewModel.mock.items[1])
        Divider().background(Color.gray.opacity(0.2))
        ContactRow(item: ContactsListViewModel.mock.items[2],
                   extensionLabel: "Int. 207")
    }
    .padding()
    .background(Color.black)
    .qAudionTheme(dark: true)
}
