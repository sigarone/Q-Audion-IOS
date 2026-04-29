import SwiftUI

/// 15-style Material 3 typography scale, 1:1 port of Android
/// `qaudionTypography` from QAudionTypography.kt.
///
/// Conversion notes (Android → SwiftUI):
///   - sp → pt 1:1 (SwiftUI's `Font` works in points; Material's `sp` is
///     the same numeric value before display-density scaling).
///   - lineHeight (sp) → SwiftUI doesn't expose lineHeight on `Font`;
///     callers that need exact line height pin it via `.lineSpacing(_:)`
///     where `lineSpacing = lineHeight - fontSize`. We expose both
///     metrics in `Style` so the Text helper can apply them together.
///   - letterSpacing (sp) → `.tracking(_:)` modifier.
///   - weight 400 → `.regular`, 500 → `.medium`, 700 → `.bold`.
///   - Brand font (Inter / Geist) is a future TODO matching Android's
///     "FontFamily.SansSerif placeholder" comment; we use the iOS
///     system font until the brand TTF lands.
public struct QAudionTypography: Equatable {

    /// One Material typography role (e.g. `headlineLarge`). Stores the
    /// raw metrics so callers can build either a `Font` or a fully-pinned
    /// `Text` with line height + tracking applied.
    public struct Style: Equatable {
        public let size: CGFloat        // pt
        public let weight: Font.Weight
        public let lineHeight: CGFloat  // pt — for `.lineSpacing(lineHeight - size)`
        public let tracking: CGFloat    // pt — for `.tracking(...)`

        public var font: Font {
            .system(size: size, weight: weight, design: .default)
        }

        /// Computed lineSpacing to feed `.lineSpacing(_:)` so the rendered
        /// line height matches Material's `lineHeight` token.
        public var lineSpacing: CGFloat {
            max(0, lineHeight - size)
        }
    }

    // Display
    public let displayLarge:   Style
    public let displayMedium:  Style
    public let displaySmall:   Style

    // Headline
    public let headlineLarge:  Style
    public let headlineMedium: Style
    public let headlineSmall:  Style

    // Title
    public let titleLarge:     Style
    public let titleMedium:    Style
    public let titleSmall:     Style

    // Body
    public let bodyLarge:      Style
    public let bodyMedium:     Style
    public let bodySmall:      Style

    // Label
    public let labelLarge:     Style
    public let labelMedium:    Style
    public let labelSmall:     Style

    /// Default Q-Audion typography. Values byte-for-byte match the
    /// Android `qaudionTypography` table (size / weight / lineHeight /
    /// letterSpacing).
    public static let standard = QAudionTypography(
        displayLarge:   Style(size: 57, weight: .regular, lineHeight: 64, tracking: -0.25),
        displayMedium:  Style(size: 45, weight: .regular, lineHeight: 52, tracking:  0.0),
        displaySmall:   Style(size: 36, weight: .regular, lineHeight: 44, tracking:  0.0),
        headlineLarge:  Style(size: 32, weight: .bold,    lineHeight: 40, tracking:  0.0),
        headlineMedium: Style(size: 28, weight: .bold,    lineHeight: 36, tracking:  0.0),
        headlineSmall:  Style(size: 24, weight: .medium,  lineHeight: 32, tracking:  0.0),
        titleLarge:     Style(size: 22, weight: .medium,  lineHeight: 28, tracking:  0.0),
        titleMedium:    Style(size: 16, weight: .medium,  lineHeight: 24, tracking:  0.15),
        titleSmall:     Style(size: 14, weight: .medium,  lineHeight: 20, tracking:  0.10),
        bodyLarge:      Style(size: 16, weight: .regular, lineHeight: 24, tracking:  0.50),
        bodyMedium:     Style(size: 14, weight: .regular, lineHeight: 20, tracking:  0.25),
        bodySmall:      Style(size: 12, weight: .regular, lineHeight: 16, tracking:  0.40),
        labelLarge:     Style(size: 14, weight: .medium,  lineHeight: 20, tracking:  0.10),
        labelMedium:    Style(size: 12, weight: .medium,  lineHeight: 16, tracking:  0.50),
        labelSmall:     Style(size: 11, weight: .medium,  lineHeight: 16, tracking:  0.50)
    )
}

// MARK: - Environment plumbing

private struct QAudionTypographyKey: EnvironmentKey {
    static let defaultValue: QAudionTypography = .standard
}

public extension EnvironmentValues {
    /// Active Q-Audion typography scale. Read in views via
    /// `@Environment(\.qaudionType)`.
    var qaudionType: QAudionTypography {
        get { self[QAudionTypographyKey.self] }
        set { self[QAudionTypographyKey.self] = newValue }
    }
}

// MARK: - Text style helper

public extension Text {
    /// Apply a Material typography role (font + tracking) to this Text.
    /// Caller must additionally use `.lineSpacing(style.lineSpacing)` on
    /// the parent if multi-line layout requires the exact Material
    /// line-height.
    func qaudionStyle(_ style: QAudionTypography.Style) -> Text {
        self.font(style.font).tracking(style.tracking)
    }
}
