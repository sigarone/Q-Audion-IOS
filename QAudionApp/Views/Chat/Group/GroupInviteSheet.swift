import SwiftUI
import QAudionEngine

/// W400 — modal sheet that prompts the user when an inbound
/// `qa_grp:1, t:"group_invite"` arrives.
///
/// Subscription point: ContentView observes
/// `AppState.groupInviteReceivedNotification` and presents this
/// sheet with the invite payload. On Accept, calls
/// `AppState.acceptGroupInvite(...)`. On Decline, ships
/// `group_invite_decline` back via 1:1 ratchet (AppState.declineGroupInvite).
struct GroupInviteSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionExtras) private var extras
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let groupId: String
    let groupName: String
    let members: [String]
    let admins: [String]
    let fromAdmin: String

    var body: some View {
        VStack(spacing: 0) {
            // Top handle
            Capsule()
                .fill(scheme.outline.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(scheme.primary)
                        .frame(width: 36, height: 36)
                        .background(scheme.primary.opacity(0.15))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invito a un gruppo")
                            .qaudionStyle(type.titleSmall)
                            .foregroundStyle(scheme.onSurface)
                        Text("da \(displayName(for: fromAdmin))")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }
                    Spacer()
                }

                Divider().background(scheme.outline.opacity(0.3))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Nome")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                        Spacer()
                        Text(groupName)
                            .qaudionStyle(type.bodyMedium)
                            .foregroundStyle(scheme.onSurface)
                    }
                    HStack {
                        Text("Membri")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                        Spacer()
                        Text("\(members.count)")
                            .qaudionStyle(type.bodyMedium)
                            .foregroundStyle(scheme.onSurface)
                    }
                    HStack {
                        Text("Admin")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                        Spacer()
                        Text("\(admins.count)")
                            .qaudionStyle(type.bodyMedium)
                            .foregroundStyle(scheme.onSurface)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(scheme.surfaceVariant.opacity(0.6))
                )

                Text("Accettando, riceverai i messaggi del gruppo e potrai inviare. Il tuo numero di telefono e l'identificativo verranno mostrati agli altri membri.")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button {
                    appState.declineGroupInvite(groupId: groupId, fromAdmin: fromAdmin)
                    dismiss()
                } label: {
                    Text("Rifiuta")
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(scheme.surfaceVariant.opacity(0.8))
                        )
                }

                Button {
                    appState.acceptGroupInvite(
                        groupId: groupId,
                        name: groupName,
                        members: members,
                        admins: admins)
                    dismiss()
                } label: {
                    Text("Accetta")
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(scheme.primary)
                        )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(scheme.surface.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func displayName(for userId: String) -> String {
        // Best-effort: show the userId prefix if no contact resolves.
        // A future ContactsStore lookup can replace this.
        if userId.count > 16 {
            return String(userId.prefix(8)) + "…"
        }
        return userId
    }
}

// MARK: - Pending invite payload (carried via NotificationCenter)

struct PendingGroupInvite: Identifiable, Equatable {
    let id: String   // groupId
    let name: String
    let members: [String]
    let admins: [String]
    let fromAdmin: String
}
