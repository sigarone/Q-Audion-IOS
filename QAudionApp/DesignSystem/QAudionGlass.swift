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

/// Two glass views that take each other's place (send and microphone) share an id in a namespace, so the glass morphs
/// from one to the other instead of cutting. Only used inside a `QAudionGlassGroup`.
struct QAudionGlassMorph {
    let id: String
    let namespace: Namespace.ID
}

private struct QAudionGlassSurface<S: Shape, F: ShapeStyle>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let shape: S
    let tint: Color?
    let interactive: Bool
    let glassAllowed: Bool
    let morph: QAudionGlassMorph?
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
    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        if let morph {
            content.glassEffect(glassValue, in: shape).glassEffectID(morph.id, in: morph.namespace)
        } else {
            content.glassEffect(glassValue, in: shape)
        }
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

    @ViewBuilder
    private func solid(_ content: Content) -> some View {
        let filled = content
            .background(fallback, in: shape)
            .overlay {
                if let stroke = fallbackStroke {
                    shape.stroke(stroke, lineWidth: 1)
                }
            }
        if fallbackShadow {
            filled.shadow(color: Color.black.opacity(0.30), radius: 8, x: 0, y: 4)
        } else {
            filled
        }
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
    /// Do not put this on content, and do not nest glass in glass: a control that sits on a glass surface keeps a solid fill.
    /// `morph` pairs two views that replace each other (inside a `QAudionGlassGroup`).
    func qaudionGlassSurface<S: Shape, F: ShapeStyle>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        glassAllowed: Bool = true,
        morph: QAudionGlassMorph? = nil,
        fallback: F,
        fallbackStroke: Color? = nil,
        fallbackShadow: Bool = false
    ) -> some View {
        modifier(QAudionGlassSurface(
            shape: shape, tint: tint, interactive: interactive, glassAllowed: glassAllowed, morph: morph,
            fallback: fallback, fallbackStroke: fallbackStroke, fallbackShadow: fallbackShadow))
    }
}

/// Groups glass controls that sit next to each other, so they share one sampling region and can morph into each other.
/// Plain pass-through before iOS 26.
struct QAudionGlassGroup<Content: View>: View {
    let spacing: CGFloat
    private let content: () -> Content

    init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    /// The tab bar shrinks while the content scrolls down (iOS 26 and later); unchanged before.
    @ViewBuilder
    func qaudionTabBarMinimizesOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

private struct QAudionBarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let fill: Color
    let hairline: Color
    let hairlineAtTop: Bool

    private var style: QAudionGlassStyle {
        QAudionGlassStyle.resolve(
            osSupportsGlass: QAudionGlassStyle.osSupportsGlass,
            reduceTransparency: reduceTransparency,
            increaseContrast: contrast == .increased)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if style == .glass {
            // No opaque bar: the controls on it are glass and float over the background of the screen itself. The bar
            // keeps its hairline, so the header and the composer stay separated from the list (the list does not scroll
            // under them).
            content
                .overlay(alignment: hairlineAtTop ? .top : .bottom) {
                    Rectangle()
                        .fill(hairline)
                        .frame(height: 0.5)
                }
        } else {
            content
                .background(fill)
                .overlay(alignment: hairlineAtTop ? .top : .bottom) {
                    Rectangle()
                        .fill(hairline)
                        .frame(height: 0.5)
                }
        }
    }
}

private struct QAudionSoftScrollEdges: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if QAudionGlassStyle.resolve(
                osSupportsGlass: true,
                reduceTransparency: reduceTransparency,
                increaseContrast: contrast == .increased) == .glass {
                content.scrollEdgeEffectStyle(.soft, for: .vertical)
            } else {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    /// The bar behind a row of controls (a chat header, a composer). Where the controls are glass the bar draws no fill of
    /// its own, only its hairline; elsewhere it is the opaque `fill` with the hairline, exactly as it was.
    func qaudionBarSurface(fill: Color, hairline: Color, hairlineAtTop: Bool) -> some View {
        modifier(QAudionBarSurface(fill: fill, hairline: hairline, hairlineAtTop: hairlineAtTop))
    }

    /// A control on such a bar: a glass disc where glass is used, nothing added elsewhere.
    func qaudionBarControl() -> some View {
        qaudionGlassSurface(in: Circle(), interactive: true, fallback: Color.clear)
    }

    /// Softens the top and bottom edge of a scroll view where it meets a glass bar (iOS 26 and later, glass only).
    func qaudionSoftScrollEdges() -> some View {
        modifier(QAudionSoftScrollEdges())
    }
}
