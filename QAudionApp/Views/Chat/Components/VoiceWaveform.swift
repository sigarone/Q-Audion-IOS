import SwiftUI

/// Voice-note waveform renderer. 1:1 port of Android
/// `qaudion-android-new/feature/feature-chat/.../components/VoiceWaveform.kt`.
///
/// Layout: optional 32pt circular play button + 10pt gap + waveform
/// canvas (default 160×32pt) + 10pt gap + duration label. Inside a chat
/// bubble the play button is hidden and only the waveform + label are
/// shown — the bubble itself acts as the tap target.
///
/// Drawing rules (matches Compose `Canvas` + `drawLine`):
///   - bar count = `samples.count`
///   - barWidth = canvasWidth / (n * 1.4)
///   - gap     = barWidth * 0.4
///   - amplitude clamped to [0.15, 1.0] so even silence shows a stub
///   - bars where `i < n * progress` use the `primary` accent;
///     remaining bars use `onSurfaceVariant @ 50%` opacity
///   - centred vertically; no peak hold
struct VoiceWaveform: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let samples: [Float]
    let durationLabel: String
    let isPlaying: Bool
    let progress: Double      // 0.0 ... 1.0
    let showPlayButton: Bool
    let onToggle: () -> Void

    init(samples: [Float],
         durationLabel: String,
         isPlaying: Bool = false,
         progress: Double = 0,
         showPlayButton: Bool = true,
         onToggle: @escaping () -> Void = {}) {
        self.samples = samples
        self.durationLabel = durationLabel
        self.isPlaying = isPlaying
        self.progress = max(0, min(1, progress))
        self.showPlayButton = showPlayButton
        self.onToggle = onToggle
    }

    var body: some View {
        HStack(spacing: 10) {
            if showPlayButton {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .fill(scheme.primary.opacity(0.15))
                            .frame(width: 32, height: 32)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(scheme.primary)
                    }
                }
                .buttonStyle(.plain)
            }

            Canvas { context, size in
                let n = max(1, samples.count)
                let barWidth = size.width / (CGFloat(n) * 1.4)
                let gap = barWidth * 0.4
                let centreY = size.height / 2.0
                let activeBarThreshold = Int((Double(n) * progress).rounded())

                for i in 0..<n {
                    let raw = Double(samples[i])
                    let amplitude = max(0.15, min(1.0, raw))
                    let halfHeight = (size.height / 2.0) * amplitude
                    let x = CGFloat(i) * (barWidth + gap) + barWidth / 2.0

                    let color: Color = i < activeBarThreshold
                        ? scheme.primary
                        : scheme.onSurfaceVariant.opacity(0.5)

                    var path = Path()
                    path.move(to: CGPoint(x: x, y: centreY - halfHeight))
                    path.addLine(to: CGPoint(x: x, y: centreY + halfHeight))
                    context.stroke(path,
                                   with: .color(color),
                                   style: StrokeStyle(lineWidth: barWidth,
                                                      lineCap: .round))
                }
            }
            .frame(width: 160, height: 32)

            Text(durationLabel)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        VoiceWaveform(
            samples: (0..<48).map { _ in Float.random(in: 0.2...1.0) },
            durationLabel: "0:12",
            isPlaying: false,
            progress: 0.0
        )
        VoiceWaveform(
            samples: (0..<48).map { _ in Float.random(in: 0.1...0.9) },
            durationLabel: "0:34",
            isPlaying: true,
            progress: 0.45
        )
        VoiceWaveform(
            samples: (0..<48).map { _ in Float.random(in: 0.2...1.0) },
            durationLabel: "1:08",
            showPlayButton: false  // bubble-embedded variant
        )
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .qAudionTheme(dark: true)
}
