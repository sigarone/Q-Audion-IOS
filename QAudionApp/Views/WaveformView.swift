import SwiftUI

// MARK: - Single Waveform Stream

/// Draws a real-time audio waveform from normalized PCM samples.
/// Used for TX (outgoing), RX (incoming), and cipher (encrypted) streams.
struct WaveformView: View {
    let title: String
    let color: Color
    let samples: [Float] // normalized -1...1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color.opacity(0.8))

            Canvas { context, size in
                let midY = size.height / 2
                let count = max(samples.count - 1, 1)
                let stepX = size.width / CGFloat(count)

                // Waveform path
                var path = Path()
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = midY - CGFloat(sample) * midY * 0.9
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.5)

                // Center reference line
                var centerLine = Path()
                centerLine.move(to: CGPoint(x: 0, y: midY))
                centerLine.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(centerLine, with: .color(color.opacity(0.2)), lineWidth: 0.5)
            }
            .frame(height: 44)
        }
    }
}

// MARK: - Waveform Panel (3-stream stack)

/// Stacked visualization of TX, RX, and cipher waveforms with frame counters.
/// Matches the 3-stream layout from the Android Q-Audion client.
struct WaveformPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            WaveformView(
                title: "TX OUT",
                color: .cyan,
                samples: appState.txWaveform
            )

            WaveformView(
                title: "RX IN",
                color: .green,
                samples: appState.rxWaveform
            )

            WaveformView(
                title: "CIPHER",
                color: .orange,
                samples: appState.cipherWaveform
            )

            // Frame counters
            HStack {
                Label("\(appState.framesTx) TX", systemImage: "arrow.up.circle.fill")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.7))

                Spacer()

                Label("\(appState.framesRx) RX", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green.opacity(0.7))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }
}

// MARK: - Previews

#if DEBUG
struct WaveformView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                WaveformView(
                    title: "TX OUT",
                    color: .cyan,
                    samples: Self.sineWave(count: 128)
                )

                WaveformView(
                    title: "RX IN",
                    color: .green,
                    samples: Self.sineWave(count: 128, phase: 0.5)
                )

                WaveformView(
                    title: "CIPHER",
                    color: .orange,
                    samples: Self.noiseWave(count: 128)
                )
            }
            .padding()
        }
    }

    static func sineWave(count: Int, phase: Float = 0) -> [Float] {
        (0..<count).map { i in
            sin(Float(i) / Float(count) * .pi * 4 + phase * .pi * 2) * 0.7
        }
    }

    static func noiseWave(count: Int) -> [Float] {
        (0..<count).map { _ in Float.random(in: -0.8...0.8) }
    }
}
#endif
