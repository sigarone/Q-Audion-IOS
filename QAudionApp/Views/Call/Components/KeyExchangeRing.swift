import SwiftUI

/// Ring around the call avatar that fills as the real PQC key exchange for
/// THIS call is confirmed — replaces the static-in-name-but-actually-
/// perpetually-pulsing `AvatarHalo` on the ring screens. See
/// `docs/superpowers/specs/2026-09-03-key-exchange-avatar-animation-design.md`
/// for the full design.
///
/// Always a SINGLE segment — iOS has no local earbud-hardware media path
/// (`earbudHwVerified`/`earbudActive` are hardcoded `false` at their one
/// call site, `LiveInCallScreen.swift:320-321`), so there is nothing real
/// for a second segment to represent. Do not add one.
///
/// Driven by `TimelineView(.animation(paused: phase == .settled))` — when
/// paused, SwiftUI does not invoke the closure at all, which is the direct
/// SwiftUI analogue of Android's bounded `withFrameNanos` loop that exits
/// for good once settled. No custom clock, no calibration/self-tuning: no
/// iOS incident analogous to Android's A36 frame-skip has ever been
/// measured, so there is nothing to calibrate against — see the design
/// doc's "Bounded animation" section for why this is a deliberate scope
/// reduction, not an oversight.
struct KeyExchangeRing: View {
    enum Phase: Equatable {
        case handshaking
        case crystallizing
        case settled
    }

    let phase: Phase
    /// True once a real PQC round-trip is known to be in flight for this
    /// call. On `OutgoingCallScreen` this is true from the moment the ring
    /// screen appears (`.dialing` and `.handshaking` both mean the
    /// handshake is already running — see the design doc). On
    /// `IncomingCallScreen` this is always false, because that screen's
    /// ring is always constructed with `phase: .settled` and no real
    /// handshake data exists while merely ringing.
    let confirmed: Bool
    var ringSize: CGFloat = 220

    @State private var confirmedAt: Date?
    @State private var crystallizeStartedAt: Date?

    private let ringPQCColor = Color(red: 0x4C / 255.0, green: 0x8D / 255.0, blue: 0xFF / 255.0)
    private let ringGuideColor = Color(red: 0x8C / 255.0, green: 0xB4 / 255.0, blue: 0xFF / 255.0)
    private let strokeWidth: CGFloat = 7
    private let fillDurationSeconds: Double = 0.28
    private let crystallizeDurationSeconds: Double = 0.32

    var body: some View {
        TimelineView(.animation(paused: phase == .settled)) { context in
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size, now: context.date)
            }
            .frame(width: ringSize, height: ringSize)
        }
        .onAppear {
            if confirmed && confirmedAt == nil { confirmedAt = Date() }
            if phase == .crystallizing && crystallizeStartedAt == nil { crystallizeStartedAt = Date() }
        }
        .onChange(of: confirmed) { newValue in
            if newValue && confirmedAt == nil { confirmedAt = Date() }
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .crystallizing && crystallizeStartedAt == nil {
                crystallizeStartedAt = Date()
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.455

        // Dim track — always drawn, same shape as the fill arc.
        var track = Path()
        track.addArc(center: center, radius: radius,
                     startAngle: .degrees(-90), endAngle: .degrees(262),
                     clockwise: false)
        ctx.stroke(track, with: .color(ringPQCColor.opacity(0.16)),
                   style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))

        // Fill — animates 0 -> full once `confirmed` flips true.
        if let confirmedAt {
            let progress = min(1.0, now.timeIntervalSince(confirmedAt) / fillDurationSeconds)
            let endAngle = -90.0 + 352.0 * progress
            var fill = Path()
            fill.addArc(center: center, radius: radius,
                        startAngle: .degrees(-90), endAngle: .degrees(endAngle),
                        clockwise: false)
            ctx.stroke(fill, with: .color(ringPQCColor),
                       style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
        }

        // Slowly rotating dashed guide ring — only while actively handshaking.
        if phase == .handshaking {
            let guideRadius = radius + 14
            let rotationDegrees = now.timeIntervalSinceReferenceDate * 12
                .truncatingRemainder(dividingBy: 360)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .degrees(rotationDegrees))
            ctx.translateBy(x: -center.x, y: -center.y)
            var guide = Path()
            guide.addArc(center: center, radius: guideRadius,
                        startAngle: .degrees(0), endAngle: .degrees(360),
                        clockwise: false)
            ctx.stroke(guide, with: .color(ringGuideColor.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 14]))
        }

        // Crystallize pulse — one soft fading white ring, fires once.
        if phase == .crystallizing, let crystallizeStartedAt {
            let progress = min(1.0, now.timeIntervalSince(crystallizeStartedAt) / crystallizeDurationSeconds)
            var pulse = Path()
            pulse.addArc(center: center, radius: radius - strokeWidth,
                        startAngle: .degrees(0), endAngle: .degrees(360),
                        clockwise: false)
            ctx.stroke(pulse, with: .color(.white.opacity((1 - progress) * 0.7)),
                       style: StrokeStyle(lineWidth: 2))
        }
    }
}

/// Pure mapping from `OutgoingCallScreen.State` to the ring's phase —
/// extracted as a free function (not a method on either type) so it is
/// unit-testable with plain XCTest, no SwiftUI/view-hosting needed.
/// Mirrors Android's `KeyExchangeRingModel.kt` split between pure logic
/// and the Compose view.
///
/// `.dialing` and `.handshaking` both map to `.handshaking` — the PQC
/// round-trip is already in flight during `.dialing` too, per the shared
/// cross-platform wire protocol (see the design doc). `.rekeying` is
/// documented dead in production wiring today
/// (`ContentView.swift:424-451`) but is mapped to `.settled` rather than
/// crashing or being left unhandled, in case that ever changes.
func ringPhase(for state: OutgoingCallScreen.State) -> KeyExchangeRing.Phase {
    switch state {
    case .dialing, .handshaking:
        return .handshaking
    case .connected:
        return .crystallizing
    case .rekeying, .ended:
        return .settled
    }
}

#Preview("Handshaking") {
    ZStack {
        Color.black.ignoresSafeArea()
        KeyExchangeRing(phase: .handshaking, confirmed: true)
    }
}

#Preview("Crystallizing") {
    ZStack {
        Color.black.ignoresSafeArea()
        KeyExchangeRing(phase: .crystallizing, confirmed: true)
    }
}

#Preview("Settled, unconfirmed (IncomingCallScreen's case)") {
    ZStack {
        Color.black.ignoresSafeArea()
        KeyExchangeRing(phase: .settled, confirmed: false)
    }
}
