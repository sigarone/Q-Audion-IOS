import SwiftUI

/// Q-Audion "Aegis Cipher" design system color palette.
public enum QColors {
    // Backgrounds
    public static let deepSpace = Color(red: 0x0E/255, green: 0x0E/255, blue: 0x0E/255)
    public static let darkNavy = Color(red: 0x13/255, green: 0x13/255, blue: 0x13/255)
    public static let cardSurface = Color(red: 0x1F/255, green: 0x1F/255, blue: 0x1F/255)
    public static let cardSurfaceElevated = Color(red: 0x2A/255, green: 0x2A/255, blue: 0x2A/255)

    // Primary (cyan)
    public static let qGreen = Color(red: 0x00/255, green: 0xDA/255, blue: 0xF3/255)
    public static let qGreenDark = Color(red: 0x00/255, green: 0xB8/255, blue: 0xD4/255)
    public static let qGreenSubtle = qGreen.opacity(0.12)

    // Secondary
    public static let qBlue = Color(red: 0x57/255, green: 0xA6/255, blue: 0xD0/255)
    public static let qBlueDark = Color(red: 0x3A/255, green: 0x7F/255, blue: 0xA8/255)
    public static let qBlueSubtle = qBlue.opacity(0.12)

    // Accent
    public static let qGold = Color(red: 0xFF/255, green: 0xD6/255, blue: 0x0A/255)
    public static let qGoldDark = Color(red: 0xFF/255, green: 0xAB/255, blue: 0x00/255)
    public static let qGoldSubtle = qGold.opacity(0.12)

    // Status
    public static let error = Color(red: 0xFF/255, green: 0xB4/255, blue: 0xAB/255)
    public static let warning = Color(red: 0xFF/255, green: 0xD6/255, blue: 0x0A/255)

    // Trust shield
    public static let trustUntrusted = Color(red: 0x83/255, green: 0x94/255, blue: 0x93/255)
    public static let trustKeyExchanged = Color(red: 0x57/255, green: 0xA6/255, blue: 0xD0/255)
    public static let trustSasVerified = Color(red: 0x00/255, green: 0xDA/255, blue: 0xF3/255)
    public static let trustNfcVerified = Color(red: 0x00/255, green: 0xDA/255, blue: 0xF3/255)
    public static let trustFullyVerified = Color(red: 0xFF/255, green: 0xD6/255, blue: 0x0A/255)

    // Text
    public static let textPrimary = Color(red: 0xE2/255, green: 0xE2/255, blue: 0xE2/255)
    public static let textSecondary = Color(red: 0xB9/255, green: 0xCA/255, blue: 0xC9/255)
    public static let textTertiary = Color(red: 0x83/255, green: 0x94/255, blue: 0x93/255)
    public static let textOnPrimary = deepSpace

    // Borders
    public static let border = Color(red: 0x3A/255, green: 0x4A/255, blue: 0x49/255)
    public static let outlineVariant = Color(red: 0x3A/255, green: 0x4A/255, blue: 0x49/255)

    // Misc
    public static let divider = cardSurfaceElevated
    public static let overlay = Color.black.opacity(0.6)
}

/// View modifier applying Q-Audion dark theme.
public struct QAudionThemeModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .preferredColorScheme(.dark)
            .tint(QColors.qGreen)
    }
}

public extension View {
    func qAudionTheme() -> some View {
        modifier(QAudionThemeModifier())
    }
}
