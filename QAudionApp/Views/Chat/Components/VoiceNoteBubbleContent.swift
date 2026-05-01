import SwiftUI
import QAudionEngine

/// W81 — bubble content for voice-note messages.
///
/// Three states reflected in the UI:
///   - **Downloading**: `mediaLocalPath` is nil but `mediaDurationMs > 0`
///     (sender embedded duration in the qfile marker). Shows a spinner
///     + "🎤 Nota vocale (4.2s) – download in arrivo".
///   - **Ready**: file is in the cache. Shows the play button + duration.
///   - **Playing**: the global ``VoiceNotePlayer`` is driving this id.
///     Shows the pause button + duration + progress bar.
///
/// Tap toggles between play / pause (resume) for the currently-playing
/// id; tapping any other ready bubble hijacks playback to that one.
struct VoiceNoteBubbleContent: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @ObservedObject var player: VoiceNotePlayer

    let messageId: UUID
    let mediaLocalPath: String?
    let durationMs: Int64

    private var isReady: Bool { mediaLocalPath != nil }
    private var isActive: Bool { player.currentlyPlayingId == messageId }
    private var isPlayingThis: Bool { isActive && !player.isPaused }

    private var durationLabel: String {
        let secs = max(0.0, Double(durationMs) / 1000.0)
        return String(format: "%.1fs", secs)
    }

    private var rateLabel: String {
        switch player.playbackRate {
        case 1.5: return "1.5×"
        case 2.0: return "2×"
        default:  return "1×"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            iconButton
            VStack(alignment: .leading, spacing: 4) {
                Text("Nota vocale")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                if isReady {
                    progressBar
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("download in arrivo")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }
                }
            }
            Spacer(minLength: 4)
            // W95: speed control. Visible only while THIS note is the
            // active one — tapping the chip cycles 1× → 1.5× → 2× → 1×.
            if isActive {
                Button {
                    player.cyclePlaybackRate()
                } label: {
                    Text(rateLabel)
                        .qaudionStyle(type.labelSmall)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(scheme.surfaceVariant.opacity(0.6))
                        )
                        .foregroundStyle(scheme.onSurface)
                }
                .buttonStyle(.plain)
            }
            Text(durationLabel)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
    }

    private var iconSymbol: String {
        if !isReady { return "waveform" }
        return isPlayingThis ? "pause.fill" : "play.fill"
    }

    @ViewBuilder
    private var iconButton: some View {
        Image(systemName: iconSymbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(scheme.onPrimary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(isReady ? scheme.primary : scheme.surfaceVariant.opacity(0.65)))
            .opacity(isReady ? 1.0 : 0.6)
    }

    @ViewBuilder
    private var progressBar: some View {
        // W92: pseudo-waveform — a row of vertical bars whose height
        // varies with a deterministic per-bar pseudo-random offset
        // (so the bubble looks the same on every render for a given
        // messageId, instead of randomly redrawing). Bars left of the
        // playback cursor are highlighted; bars to the right are
        // dimmed. When idle the whole row dims to 60%.
        let p = isActive ? player.progress : 0.0
        let barCount = 28
        WaveformRow(
            barCount: barCount,
            seed: Int(messageId.uuidString.utf8.prefix(8).reduce(0) { ($0 &+ Int($1)) & 0x7FFF_FFFF }),
            progress: p,
            playedColor: scheme.primary,
            unplayedColor: scheme.onSurfaceVariant.opacity(isActive ? 0.45 : 0.30)
        )
        .frame(height: 22)
    }

    /// W92: deterministic-pseudo-random waveform row. The seed is
    /// derived from the messageId so each bubble keeps a stable shape
    /// across re-renders (without persisting the per-bar amplitudes
    /// to disk). Bar amplitudes range 0.25...1.0 of the row height.
    private struct WaveformRow: View {
        let barCount: Int
        let seed: Int
        let progress: Double
        let playedColor: Color
        let unplayedColor: Color

        var body: some View {
            GeometryReader { geo in
                let barWidth = max(1, (geo.size.width - CGFloat(barCount) * 2) / CGFloat(barCount))
                let cursorIdx = Int(Double(barCount) * progress)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let amp = pseudoAmplitude(barIndex: i)
                        let h = max(2, geo.size.height * CGFloat(amp))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < cursorIdx ? playedColor : unplayedColor)
                            .frame(width: barWidth, height: h)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }

        /// Park-Miller-style LCG keyed by (seed, barIndex). Output
        /// in [0.25, 1.0] so even the shortest bar is visible.
        private func pseudoAmplitude(barIndex: Int) -> Double {
            // 32-bit LCG with carefully chosen constants.
            var state = UInt32(truncatingIfNeeded: seed &* 1_103_515_245 &+ barIndex &* 12_345)
            state ^= 0xDEADBEEF
            state = state &* 1_103_515_245 &+ 12_345
            let unitNorm = Double(state) / Double(UInt32.max)
            return 0.25 + 0.75 * unitNorm
        }
    }

    private func handleTap() {
        guard let path = mediaLocalPath, !path.isEmpty else { return }
        if isPlayingThis {
            player.pause()
            return
        }
        if isActive && player.isPaused {
            // Resume — reuses the loaded player for the same id.
            player.play(url: URL(fileURLWithPath: path), messageId: messageId)
            return
        }
        // Fresh play (this bubble might be a different id than the
        // currently-active one; the player will stop the previous and
        // start ours).
        player.play(url: URL(fileURLWithPath: path), messageId: messageId)
    }
}
