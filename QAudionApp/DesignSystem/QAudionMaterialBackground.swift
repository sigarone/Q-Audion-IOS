import SwiftUI

/// What is drawn behind a floating surface (a badge, a panel, a progress
/// card): the translucent system material, or, when the user turned on
/// "Reduce Transparency" in Accessibility settings, an opaque surface color.
/// Kept apart from the views so the choice is a plain function.
enum QAudionBackdrop: Equatable {
    case material
    case opaque

    static func resolve(reduceTransparency: Bool) -> QAudionBackdrop {
        reduceTransparency ? .opaque : .material
    }
}

private struct QAudionMaterialBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.qaudionScheme) private var scheme

    let material: Material

    func body(content: Content) -> some View {
        switch QAudionBackdrop.resolve(reduceTransparency: reduceTransparency) {
        case .material:
            content.background(material)
        case .opaque:
            content.background(scheme.surfaceVariant)
        }
    }
}

private struct QAudionMaterialBackgroundInShape<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.qaudionScheme) private var scheme

    let material: Material
    let shape: S

    func body(content: Content) -> some View {
        switch QAudionBackdrop.resolve(reduceTransparency: reduceTransparency) {
        case .material:
            content.background(material, in: shape)
        case .opaque:
            content.background(scheme.surfaceVariant, in: shape)
        }
    }
}

public extension View {
    /// Background that is a translucent material, except when "Reduce
    /// Transparency" is on: then it is the opaque `surfaceVariant` color of
    /// the design system (dark or light as the theme is). With the option off
    /// it is exactly `.background(material)`.
    func qaudionMaterialBackground(_ material: Material = .ultraThinMaterial) -> some View {
        modifier(QAudionMaterialBackground(material: material))
    }

    /// Same, clipped to `shape` (exactly `.background(material, in: shape)`
    /// with the option off).
    func qaudionMaterialBackground<S: Shape>(_ material: Material = .ultraThinMaterial,
                                             in shape: S) -> some View {
        modifier(QAudionMaterialBackgroundInShape(material: material, shape: shape))
    }
}
