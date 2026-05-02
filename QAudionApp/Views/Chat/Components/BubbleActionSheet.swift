import SwiftUI

/// Long-press action sheet for a chat bubble. 1:1 port of Android
/// `qaudion-android-new/feature/feature-chat/.../components/BubbleActionSheet.kt`.
///
/// Layout (top → bottom):
///   - 6 fixed reaction emojis "👍 ❤️ 😂 😮 😢 🙏" + a disabled "+" stub
///     (the "more" emoji picker lands in a later wave per Android Phase 32).
///   - Action rows, conditionally shown:
///       • "Modifica"             — only if the message is own AND text-only
///       • "Copia testo"          — only if text-only
///       • "Elimina per tutti"    — only if own (danger tint)
///       • "Elimina solo per me"  — always (danger tint)
///
/// Designed to be embedded inside a `.sheet` with `.presentationDetents([.height(...)])`
/// so the sheet sizes itself to its content. The "+" emoji button is
/// rendered disabled (50% opacity, no callback) — not removed, so the
/// row layout matches the Android layout pixel-for-pixel.
struct BubbleActionSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    let isOwn: Bool
    let isText: Bool
    let onReact: (String) -> Void
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onDeleteForAll: () -> Void
    let onDeleteForMe: () -> Void
    /// W141: edit eligibility window. When the message was sent more
    /// than `editWindowSeconds` ago, "Modifica" is hidden — Telegram
    /// uses 48h, WhatsApp 15min; we follow WhatsApp by default.
    /// Caller passes the message's `sentAt` (or nil to disable the
    /// gate, useful for tests / messages without a sentAt).
    var sentAt: Date? = nil
    var editWindowSeconds: TimeInterval = 15 * 60

    /// True when `sentAt` is set AND the elapsed time is within the
    /// window. nil sentAt → grandfathered (true), preserves the old
    /// behaviour for any caller that hasn't migrated.
    private var withinEditWindow: Bool {
        guard let sentAt else { return true }
        return Date().timeIntervalSince(sentAt) <= editWindowSeconds
    }

    private let emojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// W325: visibility flag for the "Picker emoji in arrivo" hint
    /// shown when the disabled "+" stub is tapped. Auto-hides after
    /// `Self.plusHintAutoDismissSeconds`.
    @State private var showPlusHint: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            reactionRow
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            // W325: tooltip-style hint surfaced when the user taps the
            // disabled "+" emoji-picker stub. Static copy, no
            // interpolation (SWIFT6_PATTERNS §1).
            if showPlusHint {
                plusHintRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            Divider().background(scheme.outline.opacity(0.4))

            VStack(spacing: 0) {
                // W141: edit row only when own + text + still within
                // the edit window. Past the cutoff it disappears
                // entirely so the user doesn't try and get a surprise
                // failure from the engine.
                if isOwn && isText && withinEditWindow {
                    actionRow(label: "Modifica",
                              icon: "pencil",
                              danger: false,
                              action: { onEdit(); dismiss() })
                }
                if isText {
                    actionRow(label: "Copia testo",
                              icon: "doc.on.doc",
                              danger: false,
                              action: { onCopy(); dismiss() })
                }
                if isOwn {
                    actionRow(label: "Elimina per tutti",
                              icon: "trash",
                              danger: true,
                              action: { onDeleteForAll(); dismiss() })
                }
                actionRow(label: "Elimina solo per me",
                          icon: "trash",
                          danger: true,
                          action: { onDeleteForMe(); dismiss() })
            }
            .padding(.bottom, 8)
        }
        .background(scheme.surface)
    }

    // MARK: - Reaction row

    private var reactionRow: some View {
        HStack(spacing: 4) {
            ForEach(emojis, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                    dismiss()
                } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(scheme.surfaceVariant.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reagisci con \(emoji)")
            }
            // Disabled "+" stub — lands in a future wave with a full picker.
            // W325: tappable now (purely informational): surfaces a
            // small "Picker emoji in arrivo" hint below the row so the
            // user understands the affordance is intentional, not a
            // bug. The button still does NOT call onReact().
            Button(action: revealPlusHint) {
                ZStack {
                    Circle().fill(scheme.surfaceVariant.opacity(0.45))
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                .frame(width: 40, height: 40)
                .opacity(0.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.plusHintAccessibilityLabel)
            Spacer(minLength: 0)
        }
    }

    // MARK: - W325 helpers

    private static let plusHintText: String = "Picker emoji in arrivo"
    private static let plusHintAccessibilityLabel: String =
        "Altre reazioni: picker emoji in arrivo"
    private static let plusHintAutoDismissSeconds: Double = 2.0

    private var plusHintRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
            Text(Self.plusHintText)
                .qaudionStyle(type.labelMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
    }

    private func revealPlusHint() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showPlusHint = true
        }
        // Auto-dismiss the tooltip after a short window so the action
        // sheet doesn't stay padded forever.
        let delay = Self.plusHintAutoDismissSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showPlusHint = false
            }
        }
    }

    // MARK: - Action row

    private func actionRow(label: String,
                           icon: String,
                           danger: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(danger ? scheme.error : scheme.onSurface)
                    .frame(width: 22)
                Text(label)
                    .qaudionStyle(type.bodyLarge)
                    .foregroundStyle(danger ? scheme.error : scheme.onSurface)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Color.gray.opacity(0.2)
        .sheet(isPresented: .constant(true)) {
            BubbleActionSheet(
                isOwn: true,
                isText: true,
                onReact: { _ in }, onEdit: {}, onCopy: {},
                onDeleteForAll: {}, onDeleteForMe: {}
            )
            .presentationDetents([.medium])
            .qAudionTheme(dark: true)
        }
}
