import SwiftUI

/// Reusable circular avatar. 1:1 port of Android
/// `qaudion-android-new/core/core-ui/.../components/QAudionAvatar.kt`.
///
/// Three rendering modes (in priority order):
///   1. `imageURL` non-nil + load succeeds → remote image.
///   2. otherwise → solid gradient circle with up-to-2-letter initials.
///   3. group conversation → 3 stacked person silhouettes (system icon).
///
/// Sizes are configurable in the [20, 240] pt range. The upper bound
/// covers call-screen usage (160-200pt hero avatars in
/// `OutgoingCallScreen` / `IncomingCallScreen`); anything bigger should
/// be a proper profile-screen header, not this component.
///
/// Color: deterministic per-name gradient picked from
/// `presenceGradient(for:)` — same string always maps to the same colors,
/// so the same peer keeps a stable visual identity across sessions even
/// if they change display name.
struct QAudionAvatar: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    enum Kind {
        case person
        case group
    }

    let displayName: String
    let imageURL: URL?
    let kind: Kind
    let size: CGFloat
    let presenceDot: PresenceDot?

    init(displayName: String,
         imageURL: URL? = nil,
         kind: Kind = .person,
         size: CGFloat = 44,
         presenceDot: PresenceDot? = nil) {
        self.displayName = displayName
        self.imageURL = imageURL
        self.kind = kind
        self.size = min(240, max(20, size))
        self.presenceDot = presenceDot
    }

    var body: some View {
        ZStack {
            avatarBody
            if let dot = presenceDot {
                dotOverlay(dot)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Body

    @ViewBuilder
    private var avatarBody: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholderCircle
                case .success(let img):
                    img.resizable()
                       .scaledToFill()
                       .frame(width: size, height: size)
                       .clipShape(Circle())
                case .failure:
                    placeholderCircle
                @unknown default:
                    placeholderCircle
                }
            }
        } else {
            placeholderCircle
        }
    }

    @ViewBuilder
    private var placeholderCircle: some View {
        Circle()
            .fill(presenceGradient(for: displayName))
            .frame(width: size, height: size)
            .overlay {
                if kind == .group {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                } else {
                    Text(initials(displayName))
                        .font(.system(size: size * 0.40, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
    }

    // MARK: - Presence dot

    private func dotOverlay(_ dot: PresenceDot) -> some View {
        let dotSize: CGFloat = max(8, size * 0.22)
        return Circle()
            .fill(dotColor(dot))
            .frame(width: dotSize, height: dotSize)
            .overlay(Circle().stroke(scheme.background, lineWidth: 1.5))
            .position(x: size - dotSize / 2 - 1,
                      y: size - dotSize / 2 - 1)
    }

    private func dotColor(_ dot: PresenceDot) -> Color {
        switch dot {
        case .online:  return Color(hex: 0x3DD598)
        case .away:    return Color(hex: 0xF2B73A)
        case .offline: return Color(hex: 0x8892A6)
        }
    }

    // MARK: - Initials

    /// Up to 2 uppercase letters from the first 2 whitespace-separated
    /// words. Falls back to "?" for an empty / whitespace-only name so
    /// the avatar is never blank.
    private func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "?" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    // MARK: - Stable per-name gradient

    /// Deterministic gradient picker: hash the name into 6 brand-friendly
    /// palettes. Same name → same gradient across launches/devices, so a
    /// peer's avatar identity is visually stable.
    private func presenceGradient(for name: String) -> LinearGradient {
        let palettes: [(Color, Color)] = [
            (Color(hex: 0x3E7BFF), Color(hex: 0x6A3DDB)), // brand blue → violet
            (Color(hex: 0x6EE7C5), Color(hex: 0x3DD598)), // jade
            (Color(hex: 0xB388FF), Color(hex: 0xEB4D5D)), // purple → coral
            (Color(hex: 0xF2B73A), Color(hex: 0xEB4D5D)), // amber → coral
            (Color(hex: 0x00DAF3), Color(hex: 0x3E7BFF)), // cyan → blue
            (Color(hex: 0x52E3A5), Color(hex: 0x00A381))  // mint
        ]
        // Use Swift's stable string hash via SDBM-style fold (the
        // built-in `hashValue` is randomized per launch since Swift 5,
        // which would defeat the point of a "stable identity" mapping).
        var h: UInt32 = 5381
        for byte in name.utf8 {
            h = (h &* 33) &+ UInt32(byte)
        }
        let idx = Int(h % UInt32(palettes.count))
        let pair = palettes[idx]
        return LinearGradient(colors: [pair.0, pair.1],
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }
}

// MARK: - PresenceDot

/// Optional online / away / offline dot anchored to the bottom-right of
/// the avatar. Matches Android's `presenceDot` parameter.
enum PresenceDot {
    case online
    case away
    case offline
}

// MARK: - Preview

#Preview {
    HStack(spacing: 16) {
        QAudionAvatar(displayName: "Mario Rossi",
                      presenceDot: .online)
        QAudionAvatar(displayName: "Anna Bianchi",
                      size: 56,
                      presenceDot: .away)
        QAudionAvatar(displayName: "Famiglia",
                      kind: .group,
                      size: 44)
        QAudionAvatar(displayName: "",
                      size: 32,
                      presenceDot: .offline)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .qAudionTheme(dark: true)
}
