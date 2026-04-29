import SwiftUI

/// Slow-cycling dual radial-gradient background used by every call screen.
/// 1:1 port of Android `CallMeshBackground` from
/// `qaudion-android-new/feature/feature-call/.../components/CallMeshBackground.kt`.
///
/// Animation: a single phase value cycles 0 → 1 → 0 over 60 s with
/// `easeInOut`. Two soft radial gradients are positioned proportionally
/// to the canvas, with their centres drifting horizontally on opposite
/// sides as `phase` advances — giving the screen a barely-visible
/// "breathing mesh" effect while a call is in progress.
///
/// Colors are intentionally subtle:
///   - blob 1: soft green  (0x22A0FF8A) → transparent
///   - blob 2: soft cyan   (0x1F6ED8FF) → transparent
///
/// Both blobs sit on top of `scheme.background`, so a non-Q-Audion-themed
/// preview still falls back to the system colors.
struct CallMeshBackground: View {
    @Environment(\.qaudionScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            // 60 s period: phase ∈ [0, 1] (triangle), so the centres
            // drift back and forth instead of jumping at the cycle
            // boundary. This matches Compose's
            // `infiniteRepeatable(tween 60_000, RepeatMode.Reverse)`.
            let t = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 60.0) / 60.0
            let triangle = t < 0.5 ? (t * 2) : (2 - t * 2)

            Canvas { ctx, size in
                ctx.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(scheme.background)
                )

                let r1 = max(size.width, size.height) * 0.7
                let c1 = CGPoint(x: size.width * (0.2 + 0.3 * triangle),
                                 y: size.height * 0.3)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c1.x - r1, y: c1.y - r1,
                                           width: r1 * 2, height: r1 * 2)),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 0x22 / 255.0, green: 0xA0 / 255.0,
                                  blue: 0xFF / 255.0, opacity: 0xFF / 255.0)
                                .opacity(0.13),
                            Color.clear
                        ]),
                        center: c1, startRadius: 0, endRadius: r1
                    )
                )

                let r2 = max(size.width, size.height) * 0.65
                let c2 = CGPoint(x: size.width * (0.8 - 0.3 * triangle),
                                 y: size.height * 0.75)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c2.x - r2, y: c2.y - r2,
                                           width: r2 * 2, height: r2 * 2)),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 0x6E / 255.0, green: 0xD8 / 255.0,
                                  blue: 0xFF / 255.0, opacity: 0xFF / 255.0)
                                .opacity(0.12),
                            Color.clear
                        ]),
                        center: c2, startRadius: 0, endRadius: r2
                    )
                )
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    CallMeshBackground()
        .qAudionTheme(dark: true)
}
