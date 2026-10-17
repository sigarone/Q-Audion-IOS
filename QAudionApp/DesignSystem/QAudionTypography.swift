import SwiftUI
import UIKit

/// 15-style typography scale (display, headline, title, body and label roles,
/// each in large, medium and small).
///
/// Conversion notes:
///   - sizes are points, the same numeric value as the design tokens.
///   - lineHeight: SwiftUI doesn't expose lineHeight on `Font`;
///     callers that need exact line height pin it via `.lineSpacing(_:)`
///     where `lineSpacing = lineHeight - fontSize`. We expose both
///     metrics in `Style` so the Text helper can apply them together.
///   - letterSpacing → `.tracking(_:)` modifier.
///   - weight 400 → `.regular`, 500 → `.medium`, 700 → `.bold`.
///   - The brand font is a future TODO; we use the iOS system font
///     until the brand TTF lands.
///
/// Text size chosen by the user (Dynamic Type): the sizes below are the ones
/// shown at the default text size ("Large"). The theme modifier
/// (`QAudionThemeModifier`) reads the user's size and publishes
/// `standard.scaled(for:)` as the `qaudionType` environment value, so every
/// view that reads `type.bodyMedium` and so on gets the size for the current
/// setting, and is redrawn when the setting changes. `Text.qaudionStyle` keeps
/// returning `Text`, so modifiers chained after it behave as before.
public struct QAudionTypography: Equatable {

    /// The group of system text styles a role grows with when the user picks a
    /// larger or smaller text size (the `relativeTo` of the role).
    public enum Family: CaseIterable, Equatable {
        case display
        case headline
        case title
        case body
        case label

        /// The system text style whose size curve the role follows.
        public var textStyle: UIFont.TextStyle {
            switch self {
            case .display:  return .largeTitle
            case .headline: return .title1
            case .title:    return .headline
            case .body:     return .body
            case .label:    return .caption1
            }
        }
    }

    /// Largest text size the design system follows. Above it text stops
    /// growing: the fixed parts of the layouts (cells, bars, badges) do not
    /// fit larger text. This is the only place where the cap is declared.
    public static let maxDynamicTypeSize: DynamicTypeSize = .accessibility3

    /// One typography role (e.g. `headlineLarge`). Stores the
    /// raw metrics so callers can build either a `Font` or a fully-pinned
    /// `Text` with line height + tracking applied.
    public struct Style: Equatable {
        public let size: CGFloat        // pt, at the default text size
        public let weight: Font.Weight
        public let lineHeight: CGFloat  // pt — for `.lineSpacing(lineHeight - size)`
        public let tracking: CGFloat    // pt — for `.tracking(...)`
        public let family: Family       // which system text style it scales like

        public var font: Font {
            .system(size: size, weight: weight, design: .default)
        }

        /// Computed lineSpacing to feed `.lineSpacing(_:)` so the rendered
        /// line height matches the `lineHeight` token.
        public var lineSpacing: CGFloat {
            max(0, lineHeight - size)
        }

        /// This role at the given text size: size, line height and tracking
        /// grow by the same factor, so the proportions of the role stay as
        /// designed. At the default size ("Large") the result is `self`.
        public func scaled(for dynamicTypeSize: DynamicTypeSize) -> Style {
            scaled(by: QAudionTypography.scaleFactor(for: family, at: dynamicTypeSize))
        }

        func scaled(by factor: CGFloat) -> Style {
            guard factor != 1 else { return self }
            return Style(size: size * factor,
                         weight: weight,
                         lineHeight: lineHeight * factor,
                         tracking: tracking * factor,
                         family: family)
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

    /// Default Q-Audion typography, at the default text size (size / weight /
    /// lineHeight / letterSpacing of each role, plus the text style family it
    /// grows with).
    public static let standard = QAudionTypography(
        displayLarge:   Style(size: 57, weight: .regular, lineHeight: 64, tracking: -0.25, family: .display),
        displayMedium:  Style(size: 45, weight: .regular, lineHeight: 52, tracking:  0.0,  family: .display),
        displaySmall:   Style(size: 36, weight: .regular, lineHeight: 44, tracking:  0.0,  family: .display),
        headlineLarge:  Style(size: 32, weight: .bold,    lineHeight: 40, tracking:  0.0,  family: .headline),
        headlineMedium: Style(size: 28, weight: .bold,    lineHeight: 36, tracking:  0.0,  family: .headline),
        headlineSmall:  Style(size: 24, weight: .medium,  lineHeight: 32, tracking:  0.0,  family: .headline),
        titleLarge:     Style(size: 22, weight: .medium,  lineHeight: 28, tracking:  0.0,  family: .title),
        titleMedium:    Style(size: 16, weight: .medium,  lineHeight: 24, tracking:  0.15, family: .title),
        titleSmall:     Style(size: 14, weight: .medium,  lineHeight: 20, tracking:  0.10, family: .title),
        bodyLarge:      Style(size: 16, weight: .regular, lineHeight: 24, tracking:  0.50, family: .body),
        bodyMedium:     Style(size: 14, weight: .regular, lineHeight: 20, tracking:  0.25, family: .body),
        bodySmall:      Style(size: 12, weight: .regular, lineHeight: 16, tracking:  0.40, family: .body),
        labelLarge:     Style(size: 14, weight: .medium,  lineHeight: 20, tracking:  0.10, family: .label),
        labelMedium:    Style(size: 12, weight: .medium,  lineHeight: 16, tracking:  0.50, family: .label),
        labelSmall:     Style(size: 11, weight: .medium,  lineHeight: 16, tracking:  0.50, family: .label)
    )

    /// All 15 roles by name, in declaration order.
    public var roles: [(name: String, style: Style)] {
        [
            ("displayLarge", displayLarge), ("displayMedium", displayMedium), ("displaySmall", displaySmall),
            ("headlineLarge", headlineLarge), ("headlineMedium", headlineMedium), ("headlineSmall", headlineSmall),
            ("titleLarge", titleLarge), ("titleMedium", titleMedium), ("titleSmall", titleSmall),
            ("bodyLarge", bodyLarge), ("bodyMedium", bodyMedium), ("bodySmall", bodySmall),
            ("labelLarge", labelLarge), ("labelMedium", labelMedium), ("labelSmall", labelSmall)
        ]
    }

    // MARK: - Dynamic Type

    /// By how much a size in `family` grows (or shrinks) at `dynamicTypeSize`
    /// compared with the default size ("Large"), where it is exactly 1. The
    /// curve is the system one for the family's text style, and sizes above
    /// `maxDynamicTypeSize` count as `maxDynamicTypeSize`.
    public static func scaleFactor(for family: Family, at dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let effective = min(dynamicTypeSize, maxDynamicTypeSize)
        if effective == .large { return 1 }
        // Scale a round reference value, not the font size: the result is the
        // ratio between the style's size at `effective` and at "Large".
        let reference: CGFloat = 100
        let traits = UITraitCollection(preferredContentSizeCategory: effective.uiContentSizeCategory)
        let scaled = UIFontMetrics(forTextStyle: family.textStyle)
            .scaledValue(for: reference, compatibleWith: traits)
        return scaled / reference
    }

    /// A fixed point size (an icon next to text, a cell of digits) at
    /// `dynamicTypeSize`, with the same curve and cap as the roles.
    public static func scaledSize(_ size: CGFloat, family: Family, at dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        size * scaleFactor(for: family, at: dynamicTypeSize)
    }

    /// All 15 roles at the given text size.
    public func scaled(for dynamicTypeSize: DynamicTypeSize) -> QAudionTypography {
        QAudionTypography(
            displayLarge:   displayLarge.scaled(for: dynamicTypeSize),
            displayMedium:  displayMedium.scaled(for: dynamicTypeSize),
            displaySmall:   displaySmall.scaled(for: dynamicTypeSize),
            headlineLarge:  headlineLarge.scaled(for: dynamicTypeSize),
            headlineMedium: headlineMedium.scaled(for: dynamicTypeSize),
            headlineSmall:  headlineSmall.scaled(for: dynamicTypeSize),
            titleLarge:     titleLarge.scaled(for: dynamicTypeSize),
            titleMedium:    titleMedium.scaled(for: dynamicTypeSize),
            titleSmall:     titleSmall.scaled(for: dynamicTypeSize),
            bodyLarge:      bodyLarge.scaled(for: dynamicTypeSize),
            bodyMedium:     bodyMedium.scaled(for: dynamicTypeSize),
            bodySmall:      bodySmall.scaled(for: dynamicTypeSize),
            labelLarge:     labelLarge.scaled(for: dynamicTypeSize),
            labelMedium:    labelMedium.scaled(for: dynamicTypeSize),
            labelSmall:     labelSmall.scaled(for: dynamicTypeSize)
        )
    }
}

private extension DynamicTypeSize {
    /// The UIKit content size category with the same name in the user's
    /// settings.
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall:          return .extraSmall
        case .small:           return .small
        case .medium:          return .medium
        case .large:           return .large
        case .xLarge:          return .extraLarge
        case .xxLarge:         return .extraExtraLarge
        case .xxxLarge:        return .extraExtraExtraLarge
        case .accessibility1:  return .accessibilityMedium
        case .accessibility2:  return .accessibilityLarge
        case .accessibility3:  return .accessibilityExtraLarge
        case .accessibility4:  return .accessibilityExtraExtraLarge
        case .accessibility5:  return .accessibilityExtraExtraExtraLarge
        @unknown default:      return .large
        }
    }
}

// MARK: - Environment plumbing

private struct QAudionTypographyKey: EnvironmentKey {
    static let defaultValue: QAudionTypography = .standard
}

public extension EnvironmentValues {
    /// Active Q-Audion typography scale, already adjusted to the text size
    /// the user picked (see `QAudionThemeModifier`). Read in views via
    /// `@Environment(\.qaudionType)`.
    var qaudionType: QAudionTypography {
        get { self[QAudionTypographyKey.self] }
        set { self[QAudionTypographyKey.self] = newValue }
    }
}

// MARK: - Text style helper

public extension Text {
    /// Apply a typography role (font + tracking) to this Text.
    /// Returns Text so further Text-only modifiers (like .italic(),
    /// .strikethrough()) can be chained. Caller must additionally use
    /// `.lineSpacing(style.lineSpacing)` on the parent if multi-line
    /// layout requires the exact line-height.
    func qaudionStyle(_ style: QAudionTypography.Style) -> Text {
        self.font(style.font).tracking(style.tracking)
    }
}

// MARK: - View style helper (catches non-Text containers)

public extension View {
    /// Apply a typography role (font + tracking) to ANY view.
    /// Used when chaining qaudionStyle on a `TextField`, `Button`, or
    /// any other container whose return type from earlier modifiers is
    /// `some View` rather than `Text`. The Text-only overload above is
    /// preferred (it preserves Text return type) and Swift's overload
    /// resolution picks it automatically when the receiver is Text.
    func qaudionStyle(_ style: QAudionTypography.Style) -> some View {
        self.font(style.font).tracking(style.tracking)
    }
}

// MARK: - Fixed point sizes that follow the text size

private struct QAudionScaledSystemFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let family: QAudionTypography.Family

    func body(content: Content) -> some View {
        let scaled = QAudionTypography.scaledSize(size, family: family, at: dynamicTypeSize)
        return content.font(.system(size: scaled, weight: weight, design: design))
    }
}

public extension View {
    /// System font of `size` points at the default text size that follows the
    /// text size chosen by the user, with the same curve and cap as the
    /// typography roles. For the parts of a component that are not a role
    /// (the glyph of an icon next to a label, a cell of digits): pick the
    /// `family` of the text the part sits next to.
    func qaudionScaledFont(size: CGFloat,
                           weight: Font.Weight = .regular,
                           design: Font.Design = .default,
                           family: QAudionTypography.Family = .body) -> some View {
        modifier(QAudionScaledSystemFont(size: size, weight: weight, design: design, family: family))
    }
}
