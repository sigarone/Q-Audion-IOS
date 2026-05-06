import SwiftUI

/// Soft pulsing ring drawn underneath a call-screen avatar. 1:1 port of
/// Android `AvatarHalo` from
/// `qaudion-android-new/feature/feature-call/.../components/AvatarHalo.kt`.
///
/// Animation cycle (1600 ms, `easeInOut`, restart):
///   - scale     : 1.00 → 1.35
///   - opacity   :  0.35 → 0.00
/// At the end of the cycle the ring snaps back to (1.00, 0.35) and the
/// loop continues — gives a heartbeat-like "outward pulse" feel.
///
/// Pass `color` matching the call state (`extras.success` while
/// connected, `extras.pqcAccent` while negotiating, `extras.warning` if
/// degraded). The diameter is the rendered size of the halo at scale
/// 1.0; it expands up to `diameter * 1.35` at peak.
struct AvatarHalo: View {
    let color: Color
    let diameter: CGFloat

    private let period: TimeInterval = 1.6  // 1600 ms

    init(color: Color, diameter: CGFloat = 220) {
        self.color = color
        self.diameter = diameter
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            // easeInOut interpolant
            let eased = easeInOut(t)
            let scale = 1.0 + (1.35 - 1.0) * eased
            let opacity = 0.35 * (1.0 - eased)

            Circle()
                .fill(color.opacity(opacity))
                .frame(width: diameter, height: diameter)
                .scaleEffect(scale)
        }
        .frame(width: diameter * 1.4, height: diameter * 1.4)
        .allowsHitTesting(false)
    }

    /// Cubic Bezier-flavoured easeInOut, matching Compose's
    /// `FastOutSlowInEasing` closely enough for visual parity.
    private func easeInOut(_ t: Double) -> Double {
        // Smoothstep is the standard cheap easeInOut.
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ZStack {
            AvatarHalo(color: .green, diameter: 220)
            AvatarHalo(color: .purple, diameter: 180)
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 160, height: 160)
                .overlay(Text("AB").font(.system(size: 48, weight: .bold)))
        }
    }
}
