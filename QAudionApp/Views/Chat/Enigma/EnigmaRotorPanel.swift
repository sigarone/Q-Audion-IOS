import SwiftUI
import QAudionEngine

/// The three drums of the full level, drawn like a historical Enigma: black knurled drums seen from the front, the A-Z ring
/// engraved in ivory along each drum, one brass-framed window per drum with the big current letter, a dark panel with brass
/// screws and one pilot lamp in the accent colour. GRAPHICS ONLY: the cipher is AES-256-GCM, and the caption under the panel
/// says so.
///
/// Everything is vector (paths, strokes, text symbols): no bitmap, no resource, no image in the package. The position of the
/// drums is `EnigmaRotors.visual(index)`, a pure function of the advance index; `index` comes from the scene's resolved-character
/// count or, for an upload, from the real progress fraction. It never depends on a key, the text or the cipher.
///
/// The panel is `Animatable` on `index`, so a caller that receives the index in steps (an upload reports a part at a time) can
/// let the drums glide with `.animation(_:value:)`.
///
/// The panel stays dark in both light and dark mode (it is an object, not a surface of the app).
struct EnigmaRotorPanel: View, Animatable {
    var index: Double
    let accent: Color

    var animatableData: Double {
        get { index }
        set { index = newValue }
    }

    static let width: CGFloat = 168
    static let height: CGFloat = 60

    var body: some View {
        Canvas { context, size in
            EnigmaRotorArt.draw(&context, size: size, index: index, accent: accent)
        } symbols: {
            ForEach(0..<26, id: \.self) { (i: Int) in
                Text(verbatim: EnigmaRotorArt.letters[i])
                    .font(.system(size: 6.4, weight: .bold))
                    .foregroundColor(EnigmaRotorArt.ivory)
                    .tag(i)
            }
            // The ids of the two groups are DISJOINT (0...25 and 100...125). A Canvas needs every child of `symbols` to have a unique
            // id, and `ForEach(_, id: \.self)` makes the data value the child id: two blocks over `0..<26` both carried the ids
            // 0...25 and SwiftUICore stopped the app with "Canvas.swift: child view IDs must be unique" (iOS 27, build 1.0.1214,
            // as soon as the full level showed the panel). The tag is the id, so the lookup `resolveSymbol(id:)` is unchanged.
            ForEach(EnigmaRotorArt.windowSymbolIds, id: \.self) { (tag: Int) in
                Text(verbatim: EnigmaRotorArt.letters[tag - EnigmaRotorArt.windowSymbolBase])
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundColor(EnigmaRotorArt.windowInk)
                    .tag(tag)
            }
        }
        .frame(width: EnigmaRotorPanel.width, height: EnigmaRotorPanel.height)
        .accessibilityHidden(true)
    }
}

enum EnigmaRotorArt {
    static let letters: [String] = (0..<26).map { (i: Int) -> String in
        String(Character(UnicodeScalar(UInt8(65 + i))))
    }

    /// Canvas symbol ids: the ring letters use `0...25`, the big window letters `windowSymbolBase + 0...25`. They must stay disjoint
    /// (see `EnigmaRotorPanel.body`): the panel and `drawWindow` both derive the window id from `windowSymbolBase`.
    static let windowSymbolBase: Int = 100
    static let windowSymbolIds: [Int] = (0..<26).map { (i: Int) -> Int in EnigmaRotorArt.windowSymbolBase + i }

    // Palette: black #0B0D0C, brass #B08D3C / #D4B060, ivory #E8E1CF, wood, knurl.
    static let black = Color(hex: 0x0B0D0C)
    static let wood = Color(hex: 0x2B1B10)
    static let body = Color(hex: 0x181B19)
    static let rim = Color(hex: 0x1F2321)
    static let brass = Color(hex: 0xB08D3C)
    static let brassLight = Color(hex: 0xD4B060)
    static let brassDark = Color(hex: 0x6F5420)
    static let ivory = Color(hex: 0xE8E1CF)
    static let windowInk = Color(hex: 0x0E100F)
    static let knurlLight = Color(hex: 0x4A4E4B)
    static let knurlDark = Color(hex: 0x020303)

    private static let twoPi: Double = 6.283185307179586
    private static let lettersPerTurn: Double = 26
    private static let teethPerLetter: Double = 2
    private static let ringLettersEachSide: Int = 6
    private static let rimTeethEachSide: Int = 11

    /// Static geometry for one panel size (points).
    private struct Geometry {
        let w: CGFloat
        let h: CGFloat
        let border: CGFloat
        let padX: CGFloat
        let padY: CGFloat
        let gap: CGFloat
        let rimW: CGFloat
        let winW: CGFloat
        let winH: CGFloat
        let frame: CGFloat
        let drumW: CGFloat
        let drumH: CGFloat
        let radius: CGFloat
        let cy: CGFloat
        let winTop: CGFloat

        init(w: CGFloat, h: CGFloat) {
            let padXValue: CGFloat = 11
            let padYValue: CGFloat = 6
            let gapValue: CGFloat = 5
            let winHValue: CGFloat = 19
            let drumHeight: CGFloat = h - 2 * padYValue
            let centerY: CGFloat = padYValue + drumHeight / 2
            self.w = w
            self.h = h
            self.border = 2.5
            self.padX = padXValue
            self.padY = padYValue
            self.gap = gapValue
            self.rimW = 8
            self.winW = 25
            self.winH = winHValue
            self.frame = 1.8
            self.drumW = (w - 2 * padXValue - 2 * gapValue) / 3
            self.drumH = drumHeight
            self.radius = drumHeight / 2
            self.cy = centerY
            self.winTop = centerY - winHValue / 2
        }
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, index: Double, accent: Color) {
        let geo = Geometry(w: size.width, h: size.height)
        let pos = EnigmaRotors.visual(index)
        drawPanel(&ctx, geo: geo, accent: accent)
        for i in 0..<3 {
            let v: Double = (i == 0) ? pos.left : ((i == 1) ? pos.middle : pos.right)
            let x0: CGFloat = geo.padX + CGFloat(i) * (geo.drumW + geo.gap)
            drawDrum(&ctx, geo: geo, x0: x0, v: v)
        }
    }

    private static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }

    private static func drawPanel(_ ctx: inout GraphicsContext, geo: Geometry, accent: Color) {
        let outer = CGRect(x: 0, y: 0, width: geo.w, height: geo.h)
        ctx.fill(Path(roundedRect: outer, cornerRadius: 5), with: .color(wood))
        let inner: CGRect = outer.insetBy(dx: geo.border, dy: geo.border)
        let innerPath = Path(roundedRect: inner, cornerRadius: 3.5)
        ctx.fill(innerPath, with: .color(black))
        let glowColors: [Color] = [brass.opacity(0.20), Color.clear]
        let glow = GraphicsContext.Shading.radialGradient(
            Gradient(colors: glowColors),
            center: CGPoint(x: geo.w / 2, y: 0),
            startRadius: 0,
            endRadius: geo.w * 0.62
        )
        ctx.fill(innerPath, with: glow)
        ctx.stroke(innerPath, with: .color(brass.opacity(0.45)), lineWidth: 0.7)

        // the one touch of the accent colour of the progress bar: a small pilot lamp on the top edge
        let lampY: CGFloat = geo.border + 0.6
        ctx.fill(circle(geo.w / 2, lampY, 2.4), with: .color(accent.opacity(0.22)))
        ctx.fill(circle(geo.w / 2, lampY, 1.0), with: .color(accent.opacity(0.9)))

        // four brass screws, each slot turned differently, as screws are
        let sx: CGFloat = 5.6
        let sy: CGFloat = 5.6
        let r: CGFloat = 2.1
        for c in 0..<4 {
            let x: CGFloat = (c % 2 == 0) ? sx : geo.w - sx
            let y: CGFloat = (c < 2) ? sy : geo.h - sy
            ctx.fill(circle(x, y, r + 0.5), with: .color(brassDark))
            ctx.fill(circle(x, y, r), with: .color(brass))
            ctx.fill(circle(x - 0.5, y - 0.5, r * 0.42), with: .color(brassLight.opacity(0.85)))
            let dx: CGFloat = r * ((c % 2 == 0) ? 0.85 : 0.45)
            let dy: CGFloat = r * ((c < 2) ? 0.45 : 0.85)
            var slot = Path()
            slot.move(to: CGPoint(x: x - dx, y: y - dy))
            slot.addLine(to: CGPoint(x: x + dx, y: y + dy))
            ctx.stroke(slot, with: .color(knurlDark), lineWidth: 0.7)
        }
    }

    private static func drawDrum(_ ctx: inout GraphicsContext, geo: Geometry, x0: CGFloat, v: Double) {
        let cx: CGFloat = x0 + geo.drumW / 2
        let drumRect = CGRect(x: x0, y: geo.padY, width: geo.drumW, height: geo.drumH)

        // body, then the strips of the two knurled rims
        ctx.fill(Path(roundedRect: drumRect, cornerRadius: 3), with: .color(body))
        ctx.fill(Path(CGRect(x: x0, y: geo.padY, width: geo.rimW, height: geo.drumH)), with: .color(rim))
        ctx.fill(Path(CGRect(x: x0 + geo.drumW - geo.rimW, y: geo.padY, width: geo.rimW, height: geo.drumH)), with: .color(rim))

        drawKnurling(&ctx, geo: geo, x0: x0, v: v)
        drawRing(&ctx, geo: geo, x0: x0, cx: cx, v: v)

        // curvature of the cylinder
        let shadeStops: [Gradient.Stop] = [
            Gradient.Stop(color: Color.black.opacity(0.82), location: 0),
            Gradient.Stop(color: Color.black.opacity(0.08), location: 0.30),
            Gradient.Stop(color: Color.clear, location: 0.50),
            Gradient.Stop(color: Color.black.opacity(0.08), location: 0.70),
            Gradient.Stop(color: Color.black.opacity(0.82), location: 1),
        ]
        let shade = GraphicsContext.Shading.linearGradient(
            Gradient(stops: shadeStops),
            startPoint: CGPoint(x: 0, y: geo.padY),
            endPoint: CGPoint(x: 0, y: geo.padY + geo.drumH)
        )
        ctx.fill(Path(roundedRect: drumRect, cornerRadius: 3), with: shade)

        drawWindow(&ctx, geo: geo, cx: cx, v: v)
    }

    /// Sawtooth ridges that roll with the drum, two teeth per letter.
    private static func drawKnurling(_ ctx: inout GraphicsContext, geo: Geometry, x0: CGFloat, v: Double) {
        let teethStep: Double = twoPi / (lettersPerTurn * teethPerLetter)
        let tBase: Int = Int((v * teethPerLetter).rounded(.down))
        var light = Path()
        var dark = Path()
        for side in 0..<2 {
            let xa: CGFloat = (side == 0) ? x0 + 0.8 : x0 + geo.drumW - geo.rimW + 0.8
            let xb: CGFloat = xa + geo.rimW - 1.6
            for j in -rimTeethEachSide...(rimTeethEachSide - 1) {
                let th: Double = (Double(tBase + j) - v * teethPerLetter) * teethStep
                let c: Double = cos(th)
                if c <= 0.12 { continue }
                let y: CGFloat = geo.cy + geo.radius * CGFloat(sin(th))
                let cc: CGFloat = CGFloat(c)
                let yLight: CGFloat = y - 0.35 * cc
                let yDark: CGFloat = y + 0.5 * cc
                light.move(to: CGPoint(x: xa, y: yLight))
                light.addLine(to: CGPoint(x: xb, y: yLight))
                dark.move(to: CGPoint(x: xa, y: yDark))
                dark.addLine(to: CGPoint(x: xb, y: yDark))
            }
        }
        ctx.stroke(dark, with: .color(knurlDark), lineWidth: 1.1)
        ctx.stroke(light, with: .color(knurlLight), lineWidth: 0.9)
    }

    /// The engraved A-Z ring between the rims; the letters shrink and fade toward the edges of the drum.
    private static func drawRing(_ ctx: inout GraphicsContext, geo: Geometry, x0: CGFloat, cx: CGFloat, v: Double) {
        let ringStep: Double = twoPi / lettersPerTurn
        let base: Int = Int(v.rounded(.down))
        let ringLeft: CGFloat = x0 + geo.rimW
        let ringRight: CGFloat = x0 + geo.drumW - geo.rimW
        for j in -ringLettersEachSide...ringLettersEachSide {
            let idx: Int = base + j
            let th: Double = (Double(idx) - v) * ringStep
            let c: Double = cos(th)
            if c <= 0.2 { continue }
            let y: CGFloat = geo.cy + geo.radius * CGFloat(sin(th))
            if abs(y - geo.cy) < geo.winH / 2 { continue } // hidden behind the window anyway
            let tag: Int = ((idx % 26) + 26) % 26
            guard let symbol = ctx.resolveSymbol(id: tag) else { continue }
            var letter = ctx
            letter.opacity = c * c
            letter.translateBy(x: cx, y: y)
            letter.scaleBy(x: 1, y: CGFloat(c))
            letter.draw(symbol, at: .zero, anchor: .center)
        }
        var edges = Path()
        edges.move(to: CGPoint(x: ringLeft, y: geo.padY))
        edges.addLine(to: CGPoint(x: ringLeft, y: geo.padY + geo.drumH))
        edges.move(to: CGPoint(x: ringRight, y: geo.padY))
        edges.addLine(to: CGPoint(x: ringRight, y: geo.padY + geo.drumH))
        ctx.stroke(edges, with: .color(knurlDark), lineWidth: 0.8)
    }

    /// Brass window with the big letter of the current position, rolling up as the drum turns.
    private static func drawWindow(_ ctx: inout GraphicsContext, geo: Geometry, cx: CGFloat, v: Double) {
        let wl: CGFloat = cx - geo.winW / 2
        let winRect = CGRect(x: wl, y: geo.winTop, width: geo.winW, height: geo.winH)
        ctx.fill(Path(winRect), with: .color(ivory))

        let base: Int = Int(v.rounded(.down))
        let pitch: CGFloat = geo.winH * 0.96
        var inside = ctx
        inside.clip(to: Path(winRect))
        for idx in (base - 1)...(base + 2) {
            let offset: CGFloat = CGFloat(Double(idx) - v)
            let y: CGFloat = geo.cy + offset * pitch
            if y < geo.winTop - pitch * 0.5 { continue }
            if y > geo.winTop + geo.winH + pitch * 0.5 { continue }
            let tag: Int = ((idx % 26) + 26) % 26
            guard let symbol = ctx.resolveSymbol(id: windowSymbolBase + tag) else { continue }
            inside.draw(symbol, at: CGPoint(x: cx, y: y + 1), anchor: .center)
        }

        let winShadeStops: [Gradient.Stop] = [
            Gradient.Stop(color: Color.black.opacity(0.34), location: 0),
            Gradient.Stop(color: Color.clear, location: 0.22),
            Gradient.Stop(color: Color.clear, location: 0.78),
            Gradient.Stop(color: Color.black.opacity(0.34), location: 1),
        ]
        let winShade = GraphicsContext.Shading.linearGradient(
            Gradient(stops: winShadeStops),
            startPoint: CGPoint(x: 0, y: geo.winTop),
            endPoint: CGPoint(x: 0, y: geo.winTop + geo.winH)
        )
        ctx.fill(Path(winRect), with: winShade)

        let brassStops: [Gradient.Stop] = [
            Gradient.Stop(color: brassLight, location: 0),
            Gradient.Stop(color: brass, location: 0.5),
            Gradient.Stop(color: brassDark, location: 1),
        ]
        let brassBrush = GraphicsContext.Shading.linearGradient(
            Gradient(stops: brassStops),
            startPoint: CGPoint(x: 0, y: geo.winTop - geo.frame),
            endPoint: CGPoint(x: 0, y: geo.winTop + geo.winH + geo.frame)
        )
        let frameRect: CGRect = winRect.insetBy(dx: -geo.frame / 2, dy: -geo.frame / 2)
        ctx.stroke(Path(roundedRect: frameRect, cornerRadius: 1.6), with: brassBrush, lineWidth: geo.frame)
        ctx.stroke(Path(winRect), with: .color(knurlDark.opacity(0.7)), lineWidth: 0.6)
    }
}
