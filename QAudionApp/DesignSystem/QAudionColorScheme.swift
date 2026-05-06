import SwiftUI

/// 23 Material 3 color roles, port 1:1 of Android `qaudionDarkScheme` /
/// `qaudionLightScheme` from
/// `qaudion-android-new/core/core-ui/.../theme/QAudionColors.kt`.
///
/// SwiftUI has no built-in equivalent of Material's full ColorScheme, so we
/// model it as a plain immutable struct exposed via `@Environment`. Every
/// Q-Audion view that needs a color reads it from
/// `@Environment(\.qaudionScheme)` instead of hard-coding hex literals,
/// so a future theme tweak (rebrand, accessibility contrast bump) is one
/// edit in this file rather than fan-out across views.
public struct QAudionColorScheme: Equatable {
    public let primary: Color
    public let onPrimary: Color
    public let primaryContainer: Color
    public let onPrimaryContainer: Color

    public let secondary: Color
    public let onSecondary: Color
    public let secondaryContainer: Color
    public let onSecondaryContainer: Color

    public let tertiary: Color
    public let onTertiary: Color
    public let tertiaryContainer: Color
    public let onTertiaryContainer: Color

    public let background: Color
    public let onBackground: Color
    public let surface: Color
    public let onSurface: Color
    public let surfaceVariant: Color
    public let onSurfaceVariant: Color

    public let outline: Color

    public let error: Color
    public let onError: Color
    public let errorContainer: Color
    public let onErrorContainer: Color

    /// Dark scheme (default). Hex values lifted byte-for-byte from
    /// `qaudionDarkScheme` in QAudionColors.kt.
    public static let dark = QAudionColorScheme(
        primary:              Color(hex: 0x3E7BFF),
        onPrimary:            Color(hex: 0xFFFFFF),
        primaryContainer:     Color(hex: 0x1B3A7C),
        onPrimaryContainer:   Color(hex: 0xDCE5FF),
        secondary:            Color(hex: 0x6EE7C5),
        onSecondary:          Color(hex: 0x00382A),
        secondaryContainer:   Color(hex: 0x135240),
        onSecondaryContainer: Color(hex: 0xB8F3DF),
        tertiary:             Color(hex: 0xB388FF),
        onTertiary:           Color(hex: 0x2A0C5C),
        tertiaryContainer:    Color(hex: 0x432A7A),
        onTertiaryContainer:  Color(hex: 0xE2D3FF),
        background:           Color(hex: 0x0B0E13),
        onBackground:         Color(hex: 0xE8ECF4),
        surface:              Color(hex: 0x141820),
        onSurface:            Color(hex: 0xE8ECF4),
        surfaceVariant:       Color(hex: 0x1E232D),
        onSurfaceVariant:     Color(hex: 0xB6BDCC),
        outline:              Color(hex: 0x3A4152),
        error:                Color(hex: 0xEB4D5D),
        onError:              Color(hex: 0xFFFFFF),
        errorContainer:       Color(hex: 0x66101A),
        onErrorContainer:     Color(hex: 0xFFDADB)
    )

    /// Light scheme. Hex values lifted byte-for-byte from
    /// `qaudionLightScheme`.
    public static let light = QAudionColorScheme(
        primary:              Color(hex: 0x3E7BFF),
        onPrimary:            Color(hex: 0xFFFFFF),
        primaryContainer:     Color(hex: 0xDCE5FF),
        onPrimaryContainer:   Color(hex: 0x001A4B),
        secondary:            Color(hex: 0x00A381),
        onSecondary:          Color(hex: 0xFFFFFF),
        secondaryContainer:   Color(hex: 0xB8F3DF),
        onSecondaryContainer: Color(hex: 0x00382A),
        tertiary:             Color(hex: 0x6A3DDB),
        onTertiary:           Color(hex: 0xFFFFFF),
        tertiaryContainer:    Color(hex: 0xE2D3FF),
        onTertiaryContainer:  Color(hex: 0x2A0C5C),
        background:           Color(hex: 0xF7F9FC),
        onBackground:         Color(hex: 0x0B0E13),
        surface:              Color(hex: 0xFFFFFF),
        onSurface:            Color(hex: 0x0B0E13),
        surfaceVariant:       Color(hex: 0xE4E7EE),
        onSurfaceVariant:     Color(hex: 0x424958),
        outline:              Color(hex: 0xC4CAD6),
        error:                Color(hex: 0xEB4D5D),
        onError:              Color(hex: 0xFFFFFF),
        errorContainer:       Color(hex: 0xFFDADB),
        onErrorContainer:     Color(hex: 0x66101A)
    )
}

// MARK: - Environment plumbing

private struct QAudionSchemeKey: EnvironmentKey {
    static let defaultValue: QAudionColorScheme = .dark
}

public extension EnvironmentValues {
    /// The active `QAudionColorScheme`. Default is the dark scheme;
    /// `.qAudionTheme(dark: false)` modifier flips to light.
    var qaudionScheme: QAudionColorScheme {
        get { self[QAudionSchemeKey.self] }
        set { self[QAudionSchemeKey.self] = newValue }
    }
}

// MARK: - Color(hex:) helper

public extension Color {
    /// Build a `Color` from a 24-bit RGB integer literal `0xRRGGBB`.
    /// Alpha channel is fixed to 1.0 — every token in QAudionColorScheme
    /// is fully opaque per the Android source.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
