import SwiftUI

/// Slim 30pt status strip rendered above the chat thread. 1:1 port of
/// Android `qaudion-android-new/feature/feature-chat/.../components/SessionStatusStrip.kt`.
///
/// Layout (left → right):
///   [confidence dot] [presence label] [C=0.NN] [mini spark] [RE-KEY in MM:SS]
///
/// Color coding (matches Android `confidenceTone(...)`):
///   - confidence ≥ 0.80 → success     (riskLow / green)
///   - confidence ≥ 0.50 → warning     (riskMedium / amber)
///   - confidence  < 0.50 → riskHigh   (red)
///
/// Background = vertical gradient surface→surfaceVariant @ 0.7 — keeps the
/// strip visually distinct from both the topbar and the chat list without
/// being noisy.
struct SessionStatusStrip: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    /// Live VoiceID confidence [0.0, 1.0].
    let confidence: Double
    /// Short presence label, e.g. "Connesso", "Voce in corso", "Inattivo".
    let presence: String
    /// Last N (≤ 16) confidence samples for the mini-spark, oldest first.
    /// Pass an empty array to hide the spark.
    let recentSamples: [Float]
    /// Seconds remaining before automatic re-key. nil hides the countdown.
    let rekeyInSeconds: Int?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(toneColor)
                .frame(width: 8, height: 8)

            Text(presence)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurface)

            Text(String(format: "C=%.2f", min(1.0, max(0.0, confidence))))
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(toneColor)

            if !recentSamples.isEmpty {
                MiniSpark(samples: recentSamples, color: toneColor)
                    .frame(width: 36, height: 14)
            }

            Spacer(minLength: 6)

            if let rekeyInSeconds {
                Image(systemName: "key.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                Text("RE-KEY \(formatMmSs(rekeyInSeconds))")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.0)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    scheme.surface.opacity(0.95),
                    scheme.surfaceVariant.opacity(0.70)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            // 1pt hairline separator from chat list below.
            Rectangle()
                .fill(scheme.outline.opacity(0.35))
                .frame(height: 0.5)
        }
    }

    // MARK: - Helpers

    private var toneColor: Color {
        if confidence >= 0.80 { return extras.success }
        if confidence >= 0.50 { return extras.warning }
        return extras.riskHigh
    }

    private func formatMmSs(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - MiniSpark

/// Tiny inline spark line. Plots up to ~16 recent samples as a polyline.
/// Linear segments, no smoothing — matches the Compose `Canvas` impl.
private struct MiniSpark: View {
    let samples: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2 else { return }
            // Clamp samples into [0, 1] before drawing so a transient
            // out-of-range value doesn't blow the spark off the canvas.
            let normalized: [Double] = samples.map { Double(max(0, min(1, $0))) }
            let stepX = size.width / CGFloat(normalized.count - 1)
            var path = Path()
            for (i, v) in normalized.enumerated() {
                // Y is inverted: 1.0 → top of the canvas.
                let x = CGFloat(i) * stepX
                let y = size.height * (1.0 - CGFloat(v))
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path,
                           with: .color(color),
                           style: StrokeStyle(lineWidth: 1.2,
                                              lineCap: .round,
                                              lineJoin: .round))
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        SessionStatusStrip(
            confidence: 0.92,
            presence: "Connesso · voce in corso",
            recentSamples: [0.81, 0.85, 0.88, 0.90, 0.93, 0.92, 0.94, 0.92],
            rekeyInSeconds: 187
        )
        SessionStatusStrip(
            confidence: 0.62,
            presence: "Connesso",
            recentSamples: [0.55, 0.62, 0.58, 0.65, 0.62, 0.61, 0.64, 0.62],
            rekeyInSeconds: 42
        )
        SessionStatusStrip(
            confidence: 0.35,
            presence: "Verifica vocale debole",
            recentSamples: [0.4, 0.38, 0.36, 0.34, 0.35, 0.33, 0.36, 0.35],
            rekeyInSeconds: nil
        )
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .qAudionTheme(dark: true)
}
