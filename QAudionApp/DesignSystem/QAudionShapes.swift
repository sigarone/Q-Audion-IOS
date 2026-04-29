import SwiftUI

/// Material 3 shape token scale, 1:1 port of Android `qaudionShapes`
/// from `QAudionShapes.kt`. 5 corner-radius slots used across the app
/// for buttons (full pill via Capsule), cards, sheets, surfaces.
public enum QAudionShapes {
    public static let extraSmall: CGFloat =  4
    public static let small:      CGFloat =  8
    public static let medium:     CGFloat = 12
    public static let large:      CGFloat = 16
    public static let extraLarge: CGFloat = 24

    /// Convenience: `RoundedRectangle` factories with the standard radii.
    public static var roundedExtraSmall: RoundedRectangle { RoundedRectangle(cornerRadius: extraSmall) }
    public static var roundedSmall:      RoundedRectangle { RoundedRectangle(cornerRadius: small) }
    public static var roundedMedium:     RoundedRectangle { RoundedRectangle(cornerRadius: medium) }
    public static var roundedLarge:      RoundedRectangle { RoundedRectangle(cornerRadius: large) }
    public static var roundedExtraLarge: RoundedRectangle { RoundedRectangle(cornerRadius: extraLarge) }
}
