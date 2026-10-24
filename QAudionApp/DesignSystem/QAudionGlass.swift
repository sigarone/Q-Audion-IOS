import SwiftUI

/// How a floating control is drawn: as Liquid Glass (iOS 26 and later), or with the solid fill it had before.
///
/// Glass is for the controls that float above the content (call buttons, the call dock, the composer's send and
/// microphone buttons, the floating action button, the live location strip), never for the content itself (rows,
/// bubbles, cards). Bars the system draws (tab bar, navigation bar, toolbars) get glass from the system and are not
/// touched here. The solid style is used on older systems and whenever the user asked for more contrast or less
/// transparency, so a control never depends on what is behind it to be legible.
/// https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views
/// https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
enum QAudionGlassStyle: Equatable {
    case glass
    case solid

    /// The choice as a pure function of what the system and the user say.
    static func resolve(osSupportsGlass: Bool, reduceTransparency: Bool, increaseContrast: Bool) -> QAudionGlassStyle {
        if osSupportsGlass && !reduceTransparency && !increaseContrast {
            return .glass
        }
        return .solid
    }

    /// Whether this system has Liquid Glass at all.
    static var osSupportsGlass: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }
}

private struct QAudionGlassSurface<S: Shape, F: ShapeStyle>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S
    let tint: Color?
    let interactive: Bool
    let glassAllowed: Bool
    let fallback: F
    let fallbackStroke: Color?
    let fallbackShadow: Bool

    private var style: QAudionGlassStyle {
        guard glassAllowed else { return .solid }
        return QAudionGlassStyle.resolve(
            osSupportsGlass: QAudionGlassStyle.osSupportsGlass,
            reduceTransparency: reduceTransparency,
            increaseContrast: contrast == .increased)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if style == .glass {
                glass(content)
            } else {
                solid(content)
            }
        } else {
            solid(content)
        }
    }

    @available(iOS 26.0, *)
    private func glass(_ content: Content) -> some View {
        content.glassEffect(glassValue, in: shape)
    }

    @available(iOS 26.0, *)
    private var glassValue: Glass {
        var value = Glass.regular
        if let tint {
            value = value.tint(tint)
        }
        if interactive {
            value = value.interactive()
        }
        return value
    }

    private func solid(_ content: Content) -> some View {
        content
            .background(fallback, in: shape)
            .overlay {
                if let stroke = fallbackStroke {
                    shape.stroke(stroke, lineWidth: 1)
                }
            }
            .shadow(color: Color.black.opacity(fallbackShadow ? 0.30 : 0),
                    radius: fallbackShadow ? 8 : 0, x: 0, y: fallbackShadow ? 4 : 0)
    }
}

extension View {
    /// Draws this view's background as Liquid Glass in `shape` when the system has it and the user's accessibility
    /// settings allow it; otherwise as `fallback` (exactly what the view had before glass), with the optional
    /// `fallbackStroke` and `fallbackShadow` of that look.
    ///
    /// - `tint`: a brand colour to tint the glass with (a primary action). Leave nil for plain glass.
    /// - `interactive`: the glass reacts to touch; for buttons only.
    /// - `glassAllowed`: false keeps the solid look for a state that needs it (a microphone that is recording).
    ///
    /// Do not put this on content, and do not nest it: a glass view inside a glass view is drawn by the outer one.
    func qaudionGlassSurface<S: Shape, F: ShapeStyle>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        glassAllowed: Bool = true,
        fallback: F,
        fallbackStroke: Color? = nil,
        fallbackShadow: Bool = false
    ) -> some View {
        modifier(QAudionGlassSurface(
            shape: shape, tint: tint, interactive: interactive, glassAllowed: glassAllowed,
            fallback: fallback, fallbackStroke: fallbackStroke, fallbackShadow: fallbackShadow))
    }
}
