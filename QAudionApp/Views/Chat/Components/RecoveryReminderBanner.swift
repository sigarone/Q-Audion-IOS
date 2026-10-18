import SwiftUI

/// Dismissable chat-list reminder to set up the recovery phrase, for an
/// account the onboarding reveal let in without one (see
/// `RecoveryEnrollmentStatus`). A row of `ChatListScreen`'s `List`.
///
/// Reminder of the same fact the Settings banner states non-dismissably —
/// this one CAN be dismissed, because Settings remains reachable as the
/// non-dismissable backstop. Primary-tinted, not the risk-red the Settings
/// version uses: this is a nudge on the app's main surface, not a warning
/// about something already wrong.
///
/// Both buttons use `.buttonStyle(.plain)`, like the admin banner's close
/// button. Inside a `List` row a button with the default style makes the
/// WHOLE row its tap target, so two default-style buttons in one row both
/// fire on any tap: pressing "Configura" would also run the dismissal and
/// store the user's refusal before the sheet even opened. A plain style
/// limits each tap to its own label.
///
/// Takes closures only, not `AppState` (CLAUDE.md "Hard-won lesson 16"): the
/// owning screen decides what configure and dismiss do. It lives in its own
/// file because the block was long enough to count against the host
/// screen's compile budget (lesson 14).
struct RecoveryReminderBanner: View {
    let onConfigure: () -> Void
    let onDismiss: () -> Void

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(scheme.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Configura la frase di recupero")
                    .qaudionStyle(type.labelMedium)
                    .foregroundStyle(scheme.primary)
                Text("12 parole · l'unica via per non perdere l'account.")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Button(action: onConfigure) {
                    Text("Configura")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.primary)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ignora promemoria frase di recupero")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(scheme.primary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
