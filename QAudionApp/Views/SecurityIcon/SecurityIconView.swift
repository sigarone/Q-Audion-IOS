import SwiftUI
import AVFoundation

// MARK: - Security Icon (iOS draw layer)
//
// SwiftUI counterpart of the Android `SecurityIcon` / `SecurityIconFull`
// Compose renderers. Same contract (`SecurityIconSpec`), same two tiers:
//   • small  (< 96 pt) → abstract glyph — reads in a header / status chip
//   • FULL   (≥ 96 pt) → illustration-grade artwork (the v4/v5 reference)
//
// The picture is fully data-driven: the profile is the Q-Audion earbud when
// one is the active audio route, otherwise the iPhone — so the icon follows
// the detected hardware exactly.

// MARK: Controller — runs detection, republishes on audio-route changes

@MainActor
final class SecurityIconController: ObservableObject {

    /// `nil` ⇒ the icon must be HIDDEN (nothing secure detected, no call).
    @Published private(set) var spec: SecurityIconSpec?

    private let detector = IOSSecurityProbes.makeDetector()
    private var routeObserver: NSObjectProtocol?
    private var currentState: IconState = .connected

    init() {
        // An earbud connecting/disconnecting changes the audio route, which
        // is exactly the signal that must flip earbud ⇄ iPhone.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// Re-run detection. `state` lets the call layer raise the icon to
    /// `.encrypting` / `.rekeying` during an active secure call.
    func refresh(state: IconState? = nil) async {
        if let state { currentState = state }
        let detection = await detector.detect()
        spec = SecurityIconSpecFactory.build(detection: detection, state: currentState)
    }
}

// MARK: - Palette (mirrors Android SecurityIconPalette.kt)

private func roleColor(_ role: ComponentRole) -> Color {
    switch role {
    case .crypto:        return Color(red: 1.00, green: 0.824, blue: 0.290) // gold — CRACEN
    case .compute:       return Color(red: 0.361, green: 0.753, blue: 1.00) // blue — ARM / TEE
    case .memory:        return Color(red: 0.784, green: 0.471, blue: 1.00) // magenta — secure memory
    case .secureElement: return Color(red: 0.227, green: 1.00, blue: 0.706) // green — Secure Enclave
    case .attestation:   return Color(red: 0.541, green: 0.816, blue: 1.00) // pale blue
    case .biometric:     return Color(red: 1.00, green: 0.620, blue: 0.361) // orange — biometric
    }
}

private func stateColor(_ s: IconState) -> Color {
    switch s {
    case .idle:       return Color(red: 0.416, green: 0.463, blue: 0.525)
    case .connected:  return Color(red: 0.165, green: 0.510, blue: 0.839)
    case .encrypting: return Color(red: 0.0,   green: 0.898, blue: 1.0)
    case .rekeying:   return Color(red: 1.0,   green: 0.541, blue: 0.102)
    }
}

/// Global pulse period in seconds; shorter = busier device.
private func pulsePeriod(_ s: IconState) -> Double {
    switch s {
    case .idle:       return 2.6
    case .connected:  return 1.6
    case .encrypting: return 0.65
    case .rekeying:   return 0.35
    }
}

// MARK: - Public view

struct SecurityIconView: View {
    let spec: SecurityIconSpec
    /// Rendered edge length in points. ≥ 96 → FULL illustration tier.
    var size: CGFloat = 200

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, canvasSize in
                let period = pulsePeriod(spec.state)
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: period)) / period
                draw(in: &context, size: canvasSize, phase: phase)
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel(Text("\(spec.profile.displayName) — \(spec.profile.secureBoundaryLabel)"))
    }

    private var isFull: Bool { size >= 96 }

    // MARK: Dispatch

    private func draw(in ctx: inout GraphicsContext, size: CGSize, phase: Double) {
        let accent = stateColor(spec.state)

        // Soft state-coloured backing glow.
        let glowR = min(size.width, size.height) * 0.52
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: size.width / 2 - glowR, y: size.height / 2 - glowR,
                width: glowR * 2, height: glowR * 2
            )),
            with: .color(accent.opacity(0.14))
        )

        switch spec.profile.silhouette {
        case .earbud:      drawEarbud(in: &ctx, size: size, phase: phase, accent: accent)
        case .phoneIsland: drawPhone(in: &ctx, size: size, phase: phase, accent: accent)
        }
    }

    // MARK: Earbud layout

    private func drawEarbud(in ctx: inout GraphicsContext, size: CGSize, phase: Double, accent: Color) {
        let w = size.width, h = size.height
        let body = earbudSilhouette(size)

        ctx.fill(body, with: .color(Color(red: 0.071, green: 0.137, blue: 0.227).opacity(0.94)))
        ctx.stroke(body, with: .color(accent), lineWidth: w * 0.014)

        // Ear tip (silicone dome) on the body crown.
        let tip = CGRect(x: 0.34 * w, y: 0.03 * h, width: 0.32 * w, height: 0.17 * h)
        ctx.fill(Path(ellipseIn: tip), with: .color(Color(white: 0.85).opacity(0.92)))
        // Sound bore.
        ctx.fill(
            Path(ellipseIn: CGRect(x: 0.445 * w, y: 0.085 * h, width: 0.11 * w, height: 0.06 * h)),
            with: .color(Color(red: 0.043, green: 0.043, blue: 0.078))
        )
        // Speaker mesh.
        ctx.fill(
            Path(ellipseIn: CGRect(x: 0.38 * w, y: 0.19 * h, width: 0.24 * w, height: 0.09 * h)),
            with: .color(Color(red: 0.110, green: 0.110, blue: 0.157))
        )

        // Mic grille at the stem tip.
        for i in -1...1 {
            let mx = 0.5 * w + CGFloat(i) * w * 0.035
            ctx.fill(
                Path(ellipseIn: CGRect(x: mx - w * 0.012, y: 0.90 * h - w * 0.012,
                                       width: w * 0.024, height: w * 0.024)),
                with: .color(Color(red: 0.435, green: 0.714, blue: 1.0))
            )
        }

        if isFull {
            let area = CGRect(x: 0.20 * w, y: 0.34 * h, width: 0.60 * w, height: 0.40 * h)
            drawComponentGrid(in: &ctx, area: area, phase: phase, columns: 2)
            drawCenteredText(in: &ctx, spec.profile.secureBoundaryLabel.uppercased(),
                             at: CGPoint(x: 0.5 * w, y: 0.785 * h),
                             fontSize: w * 0.045, color: accent.opacity(0.85))
        } else {
            drawComponentDots(in: &ctx, size: size, phase: phase)
        }
    }

    // MARK: Phone layout

    private func drawPhone(in ctx: inout GraphicsContext, size: CGSize, phase: Double, accent: Color) {
        let w = size.width, h = size.height
        let m = 0.30 * w
        let slab = Path(roundedRect: CGRect(x: m, y: 0.05 * h, width: w - 2 * m, height: 0.90 * h),
                        cornerRadius: 0.055 * w)

        ctx.fill(slab, with: .color(Color(red: 0.071, green: 0.137, blue: 0.227).opacity(0.94)))
        ctx.stroke(slab, with: .color(accent), lineWidth: w * 0.014)

        // Dynamic Island pill.
        ctx.fill(
            Path(roundedRect: CGRect(x: 0.43 * w, y: 0.085 * h, width: 0.14 * w, height: 0.035 * h),
                 cornerRadius: 0.018 * w),
            with: .color(Color(red: 0.043, green: 0.043, blue: 0.078))
        )

        if isFull {
            drawCenteredText(in: &ctx, spec.profile.secureBoundaryLabel.uppercased(),
                             at: CGPoint(x: 0.5 * w, y: 0.165 * h),
                             fontSize: w * 0.044, color: accent.opacity(0.9))
            let area = CGRect(x: 0.36 * w, y: 0.24 * h, width: 0.28 * w, height: 0.60 * h)
            drawComponentGrid(in: &ctx, area: area, phase: phase, columns: 1)
        } else {
            drawComponentDots(in: &ctx, size: size, phase: phase)
        }
    }

    // MARK: Shared — component grid (FULL) and dots (compact)

    private func drawComponentGrid(in ctx: inout GraphicsContext, area: CGRect,
                                   phase: Double, columns: Int) {
        let comps = spec.activeComponents
        guard !comps.isEmpty else { return }
        let cols = max(columns, 1)
        let rows = (comps.count + cols - 1) / cols
        let gapX = area.width * 0.06
        let gapY = area.height * 0.10
        let cellW = (area.width - gapX * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (area.height - gapY * CGFloat(rows - 1)) / CGFloat(rows)

        for (i, c) in comps.enumerated() {
            let col = i % cols, row = i / cols
            let left = area.minX + CGFloat(col) * (cellW + gapX)
            let top = area.minY + CGFloat(row) * (cellH + gapY)
            let accent = roleColor(c.role)

            // Per-chip triangular pulse with a per-index phase offset.
            let chipPhase = (phase + Double(i) / Double(comps.count)).truncatingRemainder(dividingBy: 1.0)
            let pulse = 0.45 + 0.55 * abs(0.5 - chipPhase) * 2.0

            let cell = CGRect(x: left, y: top, width: cellW, height: cellH)
            let chip = Path(roundedRect: cell, cornerRadius: cellH * 0.18)
            ctx.fill(chip, with: .color(accent.opacity(0.16)))
            ctx.stroke(chip, with: .color(accent.opacity(pulse)), lineWidth: cellH * 0.07)

            drawCenteredText(in: &ctx, c.label,
                             at: CGPoint(x: cell.midX, y: cell.midY),
                             fontSize: min(cellH * 0.30, cellW * 0.22),
                             color: accent)
        }
    }

    /// Compact tier: a row of role-coloured dots, no labels (unreadable small).
    private func drawComponentDots(in ctx: inout GraphicsContext, size: CGSize, phase: Double) {
        let comps = spec.activeComponents
        guard !comps.isEmpty else { return }
        let w = size.width, h = size.height
        let r = w * 0.045
        let spacing = r * 2.6
        let total = spacing * CGFloat(comps.count - 1)
        let startX = w / 2 - total / 2
        for (i, c) in comps.enumerated() {
            let chipPhase = (phase + Double(i) / Double(comps.count)).truncatingRemainder(dividingBy: 1.0)
            let pulse = 0.45 + 0.55 * abs(0.5 - chipPhase) * 2.0
            let cx = startX + CGFloat(i) * spacing
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - r, y: h * 0.5 - r, width: r * 2, height: r * 2)),
                with: .color(roleColor(c.role).opacity(pulse))
            )
        }
    }

    private func drawCenteredText(in ctx: inout GraphicsContext, _ text: String,
                                  at point: CGPoint, fontSize: CGFloat, color: Color) {
        guard !text.isEmpty, fontSize > 1 else { return }
        var resolved = ctx.resolve(
            Text(text).font(.system(size: fontSize, weight: .bold, design: .monospaced))
        )
        resolved.shading = .color(color)
        ctx.draw(resolved, at: point, anchor: .center)
    }

    // MARK: Canonical earbud silhouette (ovoid body + short stem)

    private func earbudSilhouette(_ size: CGSize) -> Path {
        var path = Path()
        let w = size.width, h = size.height
        let bcx = 0.50 * w, bcy = 0.42 * h
        let brx = 0.34 * w, bry = 0.40 * h
        let bodyBottom = bcy + bry

        path.addEllipse(in: CGRect(x: bcx - brx, y: bcy - bry, width: brx * 2, height: bry * 2))

        // Stem: straight-sided, rounded bottom, top tucked under the body.
        let sHalf = 0.105 * w
        let sTop = bodyBottom - 0.16 * h
        let sBot = 0.96 * h
        let sR = 0.10 * w
        path.move(to: CGPoint(x: bcx - sHalf, y: sTop))
        path.addLine(to: CGPoint(x: bcx + sHalf, y: sTop))
        path.addLine(to: CGPoint(x: bcx + sHalf, y: sBot - sR))
        path.addQuadCurve(to: CGPoint(x: bcx + sHalf - sR, y: sBot),
                          control: CGPoint(x: bcx + sHalf, y: sBot))
        path.addLine(to: CGPoint(x: bcx - sHalf + sR, y: sBot))
        path.addQuadCurve(to: CGPoint(x: bcx - sHalf, y: sBot - sR),
                          control: CGPoint(x: bcx - sHalf, y: sBot))
        path.closeSubpath()
        return path
    }
}

// MARK: - Header convenience (mirrors Android SecurityIconHeader)

/// Slim live header: the compact glyph + a state line; tap → FULL illustration.
/// Renders nothing when no secure hardware is detected.
struct SecurityIconHeaderView: View {
    @StateObject private var controller = SecurityIconController()
    @State private var showDetail = false

    var body: some View {
        Group {
            if let spec = controller.spec {
                HStack(spacing: 10) {
                    SecurityIconView(spec: spec, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stateLabel(spec))
                            .font(.system(size: 12, weight: .medium))
                        Text("Sicurezza hardware · \(spec.profile.secureBoundaryLabel)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { showDetail = true }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Tocca per mostrare i dettagli hardware")
                .sheet(isPresented: $showDetail) {
                    SecurityIconDetailSheet(spec: spec)
                }
            }
        }
        .task { await controller.refresh() }
    }

    private func stateLabel(_ spec: SecurityIconSpec) -> String {
        switch spec.state {
        case .idle:       return "Inattivo"
        case .connected:  return "Protetto · \(spec.profile.displayName)"
        case .encrypting: return "Cifratura attiva · \(spec.profile.displayName)"
        case .rekeying:   return "Rotazione chiave…"
        }
    }
}

/// FULL-tier detail presented from the header tap.
struct SecurityIconDetailSheet: View {
    let spec: SecurityIconSpec
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text(spec.profile.displayName)
                .font(.title3.bold())
            SecurityIconView(spec: spec, size: 260)
            Text("Sicurezza ancorata all'hardware · \(spec.profile.secureBoundaryLabel)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Chiudi") { dismiss() }
                .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
