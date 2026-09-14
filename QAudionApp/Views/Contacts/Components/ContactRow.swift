import SwiftUI
import QAudionEngine

struct ContactRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let item: ContactsListViewModel.Item
    /// Sub-label under the name: the peer's PBX short number. Wired by
    /// ContactsScreen through `DisplayName.formatExtension`, the one
    /// canonical formatter.
    ///
    /// Must stay BARE DIGITS — no "Int."/"Phone"/etc. prefix (Pavel rule,
    /// 2026-07-29) — because the same value is also handed to
    /// `QAudionAvatar.shortNumber`, which paints it inside the placeholder
    /// circle.
    let extensionLabel: String?
    let presence: PresenceDot?
    let onChatTap: () -> Void
    let onCallTap: () -> Void
    let onVideoCallTap: () -> Void

    @State private var pulsing = false

    init(item: ContactsListViewModel.Item,
         extensionLabel: String? = nil,
         presence: PresenceDot? = nil,
         onChatTap: @escaping () -> Void = {},
         onCallTap: @escaping () -> Void = {},
         onVideoCallTap: @escaping () -> Void = {}) {
        self.item = item
        self.extensionLabel = extensionLabel
        self.presence = presence
        self.onChatTap = onChatTap
        self.onCallTap = onCallTap
        self.onVideoCallTap = onVideoCallTap
    }

    private var resolvedPresence: PresenceDot {
        presence ?? (item.isOnline ? .online : .offline)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar + presence dot
            ZStack(alignment: .bottomTrailing) {
                QAudionAvatar(
                    displayName: item.displayName,
                    imageURL: item.avatarUrl,
                    size: 44,
                    presenceDot: resolvedPresence,
                    // Already formatted by the caller — no second
                    // formatting path. Only reaches the placeholder circle:
                    // a contact with a real photo or an sficon avatar keeps
                    // it, so this does not clobber pictures.
                    shortNumber: extensionLabel
                )
                // Pulse ring sui contatti online
                if resolvedPresence == .online {
                    Circle()
                        .stroke(Color(hex: 0x3DD598).opacity(pulsing ? 0 : 0.5),
                                lineWidth: pulsing ? 6 : 1)
                        .frame(width: pulsing ? 22 : 12, height: pulsing ? 22 : 12)
                        .offset(x: 2, y: 2)
                        .animation(
                            .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                            value: pulsing
                        )
                }
            }
            .onAppear { if resolvedPresence == .online { pulsing = true } }
            .onChange(of: resolvedPresence) { newVal in pulsing = (newVal == .online) }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Unread badge numerico (max 99)
                    if item.unreadMessageCount > 0 {
                        Text(item.unreadMessageCount > 99 ? "99+" : "\(item.unreadMessageCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(extras.success))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                // Suppressed when it would merely repeat the name: a peer
                // with no name is already DISPLAYED by extension, via
                // DisplayName's last fallback tier, so without this guard
                // the row would read "103" twice.
                if let ext = extensionLabel, ext != item.displayName {
                    Text(ext)
                        .qaudionStyle(type.labelSmall)
                        .monospacedDigit()
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

                Button(action: onVideoCallTap) {
                    Image(systemName: "video")
                        .font(.system(size: 17))
                        .foregroundStyle(scheme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Videochiama \(item.displayName)")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trustPills: some View {
        // The PQC chip that used to open this row is gone. It read no field
        // of `item` at all — a bare string literal, so not merely true in
        // practice but structurally unconditional, identical on every
        // contact forever. Post-quantum key agreement is unchanged; only the
        // per-contact badge claiming it is gone, because a chip that is true
        // for everyone teaches the user to stop reading chips.
        //
        // VOICE stays: `isVerified` is a real per-contact field, written
        // only by actual verification paths, so it is genuinely false for
        // most contacts. An unverified contact now renders an empty HStack
        // that collapses to zero height, which is what Android does too —
        // do not add a spacer or a minHeight to even the rows out.
        HStack(spacing: 6) {
            if item.isVerified {
                TrustChip("VOICE", accent: extras.success)
            }
        }
    }
}


#Preview {
    VStack(spacing: 0) {
        ContactRow(item: ContactsListViewModel.mock.items[0],
                   extensionLabel: "103")
        Divider().background(Color.gray.opacity(0.2))
        ContactRow(item: ContactsListViewModel.mock.items[1])
        Divider().background(Color.gray.opacity(0.2))
        ContactRow(item: ContactsListViewModel.mock.items[2],
                   extensionLabel: "207")
    }
    .padding()
    .background(Color.black)
    .qAudionTheme(dark: true)
}
