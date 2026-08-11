import SwiftUI

/// Chat message bubble. 1:1 port of Android
/// `qaudion-android-new/feature/feature-chat/.../components/MessageBubble.kt`.
///
/// Three variants share the same shell (rounded rect + asymmetric tail
/// corner) but differ in colors, alignment and footer:
///
///   • `.sent`     — outgoing, right-aligned. Background
///                   `scheme.primary @ 0.28α` + 1pt border `primary @ 0.55α`.
///                   Tail (bottom-right) corner = 4pt; the other 3 corners
///                   = 14pt. Footer shows time + delivery state icon
///                   (sent / delivered / read), color-coded.
///   • `.received` — incoming, left-aligned. Background
///                   `scheme.surfaceVariant @ 0.65α`, no border.
///                   Tail (bottom-left) corner = 4pt; other 3 = 14pt.
///                   Footer shows only the time.
///   • `.admin`    — system/system-of-record message, centred. Capsule-ish
///                   pill (full radius), `scheme.surface @ 0.55α` bg,
///                   `onSurfaceVariant` text. No tail. No reactions.
///
/// Optional slots (mirrored 1:1 from Android):
///   - `replyQuote`: 2pt vertical accent bar + quoted-author + snippet,
///     drawn at the top of the bubble, separated by an 8pt gap.
///   - `body`:       primary text or rich content (e.g. voice waveform).
///                   Required (the bubble has no purpose without it).
///   - `reactions`:  horizontal chip strip rendered just BELOW the bubble
///                   (NOT inside it — matches Compose `Row` after the
///                   `Surface`). Each chip = small capsule with emoji +
///                   count.
///
/// Max content width = 280pt to mirror Android's
/// `Modifier.widthIn(max = 280.dp)`. Beyond that the body wraps.

// MARK: - Public model types (non-generic; reusable from any callsite)

enum MessageBubbleVariant {
    case sent
    case received
    case admin
}

// Fase 2 — Equatable so `GroupMessageRowUi` (Equatable) can carry an
// optional `MessageDelivery` for the group-chat delivery/read ticks
// without hand-rolling `==`. Auto-synthesizable: every case's associated
// value (`Double` on `.uploading`) is already Equatable.
// `public` because `GroupMessageRowUi.delivery` (in GroupModels.swift) is a
// `public` stored property — Swift requires the property's type to be at
// least as accessible as the property itself, even within a single app
// target (the compiler enforces this declaratively, not by whether another
// module actually consumes it today).
public enum MessageDelivery: Equatable {
    case sending     // single grey clock
    /// W446 — local-only intermediate state while an attachment upload is
    /// in flight (TUS chunked path). `progress` is `0.0...1.0`. Never
    /// persisted (not part of `Message.Status`/wire schema) — purely
    /// derived UI state computed from the in-flight upload's onProgress
    /// callback and discarded once the send reaches a terminal state.
    case uploading(progress: Double)
    case sent        // single check, onSurfaceVariant
    case delivered   // double check, onSurfaceVariant
    case read        // double check, primary
    case failed      // exclamation, error
}

struct MessageReplyQuote {
    let author: String
    let snippet: String
}

struct MessageReaction: Identifiable {
    let id: String        // emoji unicode (stable across re-renders)
    let emoji: String
    let count: Int
    let highlighted: Bool // true if the local user reacted
}

// MARK: - Bubble view

struct MessageBubble<Body: View>: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let variant: MessageBubbleVariant
    let timeLabel: String?
    let delivery: MessageDelivery?
    let replyQuote: MessageReplyQuote?
    let reactions: [MessageReaction]
    /// Tap handler for a reaction chip — re-toggles that emoji (second
    /// tap of an emoji the local user already reacted with removes it;
    /// symmetric with `BubbleActionSheet`'s emoji row, which calls the
    /// same underlying `ChatContainer.toggleReaction`). `nil` renders
    /// the chips non-interactive (e.g. previews) without changing their
    /// appearance.
    let onReact: ((String) -> Void)?
    /// True when this message was delivered over the offline BLE-mesh
    /// fallback transport (branch `claude/ble-mesh-cleanroom-spike`)
    /// instead of the normal WebSocket path — mirrors `Message.viaMesh`.
    /// Renders a small antenna glyph in the footer next to the timestamp.
    let viaMesh: Bool
    /// Stored as `content` (NOT `body`) to avoid colliding with the
    /// `View` protocol's required `var body: some View`. Both members
    /// would otherwise share the same name in the same type, which the
    /// compiler rejects. Trailing-closure callsites are unchanged.
    let content: () -> Body

    init(variant: MessageBubbleVariant,
         timeLabel: String? = nil,
         delivery: MessageDelivery? = nil,
         replyQuote: MessageReplyQuote? = nil,
         reactions: [MessageReaction] = [],
         onReact: ((String) -> Void)? = nil,
         viaMesh: Bool = false,
         @ViewBuilder content: @escaping () -> Body) {
        self.variant = variant
        self.timeLabel = timeLabel
        self.delivery = delivery
        self.replyQuote = replyQuote
        self.reactions = reactions
        self.onReact = onReact
        self.viaMesh = viaMesh
        self.content = content
    }

    var body: some View {
        switch variant {
        case .sent, .received:
            chatBubble
        case .admin:
            adminPill
        }
    }

    // MARK: - Chat bubble (sent / received)

    @ViewBuilder
    private var chatBubble: some View {
        let alignment: HorizontalAlignment = (variant == .sent) ? .trailing : .leading
        let frameAlignment: Alignment = (variant == .sent) ? .trailing : .leading

        VStack(alignment: alignment, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                if let quote = replyQuote {
                    replyQuoteView(quote)
                }
                content()
                if let timeLabel {
                    footer(timeLabel: timeLabel)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 280, alignment: .leading)
            .background(BubbleShape(variant: variant).fill(bubbleFill))
            .overlay(bubbleBorder)
            .clipShape(BubbleShape(variant: variant))

            if !reactions.isEmpty {
                reactionsStrip
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var bubbleFill: Color {
        switch variant {
        case .sent:     return scheme.primary.opacity(0.28)
        case .received: return scheme.surfaceVariant.opacity(0.65)
        case .admin:    return .clear
        }
    }

    @ViewBuilder
    private var bubbleBorder: some View {
        if variant == .sent {
            BubbleShape(variant: .sent)
                .stroke(scheme.primary.opacity(0.55), lineWidth: 1)
        }
    }

    // MARK: - Reply quote

    private func replyQuoteView(_ quote: MessageReplyQuote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(variant == .sent ? scheme.primary : scheme.secondary)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.author)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Text(quote.snippet)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurface.opacity(0.85))
                    .lineLimit(2)
            }
        }
        // Make the quote stretch the full bubble width without forcing
        // the bubble's frame: Android uses `fillMaxWidth()` inside the
        // Column.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer (time + delivery)

    private func footer(timeLabel: String) -> some View {
        HStack(spacing: 4) {
            if variant == .sent {
                Spacer(minLength: 0)
            }
            if viaMesh {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .accessibilityLabel("Inviato via mesh Bluetooth")
            }
            Text(timeLabel)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            if variant == .sent, let delivery {
                deliveryIcon(delivery)
            }
        }
        .frame(maxWidth: .infinity, alignment: variant == .sent ? .trailing : .leading)
    }

    @ViewBuilder
    private func deliveryIcon(_ delivery: MessageDelivery) -> some View {
        switch delivery {
        case .sending:
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
        case .uploading(let progress):
            // Thin determinate bar, same visual weight as the check-mark
            // icons around it (11pt-tall footer row). Clamp defensively —
            // callers pass raw bytesUploaded/totalBytes ratios that could
            // transiently exceed 1.0 on the final chunk's rounding.
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(scheme.onSurfaceVariant)
                .frame(width: 28)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.onSurfaceVariant)
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.primary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme.error)
        }
    }

    // MARK: - Reactions strip

    private var reactionsStrip: some View {
        // Reactions render OUTSIDE the bubble (Android's Column places
        // the Row right under the Surface). Horizontal scroll is omitted
        // — a chat row rarely accrues > 4 distinct emojis, and an HStack
        // wraps cleanly inside the 280pt ceiling.
        HStack(spacing: 6) {
            ForEach(reactions) { r in
                reactionChip(r)
            }
        }
    }

    @ViewBuilder
    private func reactionChip(_ r: MessageReaction) -> some View {
        let label = HStack(spacing: 3) {
            Text(r.emoji).font(.system(size: 12))
            Text("\(r.count)")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(
            Capsule().fill(
                r.highlighted
                    ? scheme.primary.opacity(0.22)
                    : scheme.surface.opacity(0.65)
            )
        )
        .overlay(
            Capsule().stroke(
                r.highlighted ? scheme.primary.opacity(0.55) : Color.clear,
                lineWidth: 1
            )
        )

        // Tapping a chip re-toggles that emoji via the same
        // toggleReaction path BubbleActionSheet's emoji row uses — no
        // reaction-sending logic is duplicated here. Chips render
        // non-interactive when no handler is supplied (e.g. previews).
        if let onReact {
            Button {
                onReact(r.emoji)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reazione \(r.emoji), \(r.count)")
            .accessibilityHint(r.highlighted ? "Tocca per rimuovere la tua reazione" : "Tocca per aggiungere questa reazione")
        } else {
            label
        }
    }

    // MARK: - Admin pill

    @ViewBuilder
    private var adminPill: some View {
        // Admin / system messages: centred capsule. We ignore replyQuote,
        // delivery and reactions — the Android variant doesn't render
        // them either.
        HStack {
            content()
                .font(type.labelSmall.font)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(scheme.surface.opacity(0.55)))
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - BubbleShape (asymmetric corner tail)

/// Rounded rectangle with one "tail" corner sharpened to 4pt; the other
/// three corners are 14pt. Mirrors Compose's
/// `RoundedCornerShape(topStart=14, topEnd=14, bottomEnd=tail, bottomStart=14)`
/// (and the mirror for received).
private struct BubbleShape: Shape {
    let variant: MessageBubbleVariant

    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 4
        let main: CGFloat = 14

        // Apply per-corner radii. iOS Path has no native per-corner API,
        // so we build it manually with arcs.
        let (tl, tr, br, bl): (CGFloat, CGFloat, CGFloat, CGFloat) = {
            switch variant {
            case .sent:     return (main, main, tail, main) // bottom-right tail
            case .received: return (main, main, main, tail) // bottom-left tail
            case .admin:    return (main, main, main, main) // unused for admin
            }
        }()

        return Self.roundedPath(in: rect, tl: tl, tr: tr, br: br, bl: bl)
    }

    static func roundedPath(in r: CGRect, tl: CGFloat, tr: CGFloat,
                            br: CGFloat, bl: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr),
                 radius: tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br),
                 radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl),
                 radius: bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl),
                 radius: tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 8) {
            MessageBubble(
                variant: .received,
                timeLabel: "10:42"
            ) {
                Text("Ciao! Tutto a posto?")
                    .foregroundStyle(.white)
            }

            MessageBubble(
                variant: .sent,
                timeLabel: "10:43",
                delivery: .read
            ) {
                Text("Sì grazie. Stasera ci sentiamo su voce, ho la chiave nuova.")
                    .foregroundStyle(.white)
            }

            MessageBubble(
                variant: .sent,
                timeLabel: "10:44",
                delivery: .delivered,
                replyQuote: .init(author: "Mario",
                                  snippet: "ho la chiave nuova"),
                reactions: [
                    .init(id: "👍", emoji: "👍", count: 2, highlighted: true),
                    .init(id: "🔒", emoji: "🔒", count: 1, highlighted: false)
                ]
            ) {
                Text("Perfetto, ti chiamo alle 21.")
                    .foregroundStyle(.white)
            }

            MessageBubble<Text>(
                variant: .admin,
                timeLabel: nil
            ) {
                Text("Chiave riconfermata via Voice-as-Key")
            }
        }
        .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .qAudionTheme(dark: true)
}
