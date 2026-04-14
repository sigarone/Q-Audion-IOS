import SwiftUI

/// Q-Audion color palette matching Android QColors exactly.
public enum QColors {
    // Backgrounds
    public static let deepSpace = Color(red: 0x0D/255, green: 0x0D/255, blue: 0x1A/255)
    public static let darkNavy = Color(red: 0x1A/255, green: 0x1A/255, blue: 0x2E/255)
    public static let cardSurface = Color(red: 0x23/255, green: 0x23/255, blue: 0x42/255)
    public static let cardSurfaceElevated = Color(red: 0x2A/255, green: 0x2A/255, blue: 0x4A/255)

    // Primary
    public static let qGreen = Color(red: 0x00/255, green: 0xE6/255, blue: 0x76/255)
    public static let qGreenDark = Color(red: 0x00/255, green: 0xC8/255, blue: 0x53/255)
    public static let qGreenSubtle = qGreen.opacity(0.12)

    // Secondary
    public static let qBlue = Color(red: 0x00/255, green: 0xB0/255, blue: 0xFF/255)
    public static let qBlueDark = Color(red: 0x00/255, green: 0x91/255, blue: 0xEA/255)
    public static let qBlueSubtle = qBlue.opacity(0.12)

    // Accent
    public static let qGold = Color(red: 0xFF/255, green: 0xD7/255, blue: 0x40/255)
    public static let qGoldDark = Color(red: 0xFF/255, green: 0xAB/255, blue: 0x00/255)
    public static let qGoldSubtle = qGold.opacity(0.12)

    // Status
    public static let error = Color(red: 0xFF/255, green: 0x52/255, blue: 0x52/255)
    public static let warning = Color(red: 0xFF/255, green: 0xA7/255, blue: 0x26/255)

    // Trust shield
    public static let trustUntrusted = Color(red: 0x75/255, green: 0x75/255, blue: 0x75/255)
    public static let trustKeyExchanged = qBlue
    public static let trustSasVerified = qGreen
    public static let trustNfcVerified = Color(red: 0x00/255, green: 0xBF/255, blue: 0xA5/255)
    public static let trustFullyVerified = qGold

    // Text
    public static let textPrimary = Color(red: 0xE0/255, green: 0xE0/255, blue: 0xE0/255)
    public static let textSecondary = Color(red: 0xB0/255, green: 0xB0/255, blue: 0xB0/255)
    public static let textTertiary = Color(red: 0x75/255, green: 0x75/255, blue: 0x75/255)
    public static let textOnPrimary = deepSpace

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
