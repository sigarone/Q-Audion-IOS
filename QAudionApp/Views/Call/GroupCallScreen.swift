import SwiftUI

/// Group-call (multi-participant SFU) screen. Aligned 1:1 with Android
/// `qaudion-android-new/feature/feature-call/.../GroupCallScreen.kt`
/// and the desktop call-surface reference (Stitch project
/// `Q-Audion Desktop — Call Surface Variants`).
///
/// Layout:
///   - Header row: 24pt person.2 icon + "Chiamata di gruppo" titleLarge.
///   - Spacer 4pt + first 8 chars of `callId` in monospace labelSmall.
///   - LazyVGrid (adaptive minimum 96pt, 12pt spacing): each
///     `ParticipantTile` is a 72pt circle showing the first 2 chars of
///     the user id (uppercase). The local participant gets a `primary`
///     border + "Tu" label, others get an `outlineVariant` border + the
///     first 6 chars of their user id.
///   - Spacer (weight 1) → bottom action row, SpaceEvenly:
///       • Mute / Unmute  (`CircularAction` 64pt)
///       • Hangup         (`CircularAction` 64pt, riskHigh)
///
/// The `participants` array is the engine truth; the screen only
/// renders. State for local mute toggle is owned by the caller via
/// `muted`/`onToggleMute` so the engine and the screen never disagree.
struct GroupCallScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let callId: String
    let participants: [String]
    let selfUserId: String
    let muted: Bool
    let onToggleMute: () -> Void
    let onLeave: () -> Void

    init(callId: String,
         participants: [String],
         selfUserId: String,
         muted: Bool = false,
         onToggleMute: @escaping () -> Void,
         onLeave: @escaping () -> Void) {
        self.callId = callId
        self.participants = participants
        self.selfUserId = selfUserId
        self.muted = muted
        self.onToggleMute = onToggleMute
        self.onLeave = onLeave
    }

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 96), spacing: 12, alignment: .top)
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            CallMeshBackground()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 24)
                    .padding(.horizontal, 20)

                ScrollView {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
                        ForEach(participants, id: \.self) { userId in
                            participantTile(userId: userId,
                                            isSelf: userId == selfUserId)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }

                Spacer().frame(height: 120)
            }

            bottomActionRow
                .padding(.bottom, 24)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(scheme.onBackground)
                Text("Chiamata di gruppo")
                    .qaudionStyle(type.titleLarge)
                    .foregroundStyle(scheme.onBackground)
            }
            Text(String(callId.prefix(8)))
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Participant tile

    private func participantTile(userId: String, isSelf: Bool) -> some View {
        let initials = String(userId.prefix(2)).uppercased()
        let label = isSelf ? "Tu" : String(userId.prefix(6))
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isSelf
                          ? scheme.primary.opacity(0.15)
                          : scheme.surfaceVariant.opacity(0.6))
                Circle()
                    .stroke(isSelf ? scheme.primary : scheme.outline,
                            lineWidth: 2)
                Text(initials)
                    .qaudionStyle(type.titleMedium)
                    .foregroundStyle(scheme.onSurface)
            }
            .frame(width: 72, height: 72)
            Text(label)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .lineLimit(1)
                .frame(maxWidth: 88)
        }
    }

    // MARK: - Bottom action row

    private var bottomActionRow: some View {
        HStack(spacing: 56) {
            CircularAction(
                icon: muted ? "mic.slash.fill" : "mic.fill",
                action: onToggleMute,
                diameter: 64,
                background: muted ? extras.warning : scheme.surfaceVariant,
                iconColor: muted ? extras.onWarning : scheme.onSurface,
                caption: muted ? "Muto" : "Attiva",
                captionColor: muted ? extras.warning : scheme.onSurfaceVariant
            )
            CircularAction(
                icon: "phone.down.fill",
                action: onLeave,
                diameter: 64,
                background: extras.riskHigh,
                iconColor: scheme.onPrimary,
                caption: "Termina",
                captionColor: extras.riskHigh
            )
        }
    }
}

#Preview {
    GroupCallScreen(
        callId: "f3a8b07c-9d51-4f2a-87e2-a1d0f5bb1a2e",
        participants: ["user-mario", "user-anna", "user-luigi", "user-self", "user-paolo"],
        selfUserId: "user-self",
        muted: false,
        onToggleMute: {}, onLeave: {}
    )
    .qAudionTheme(dark: true)
}
