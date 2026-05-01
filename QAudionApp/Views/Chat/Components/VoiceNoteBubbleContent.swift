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
            Text(durationLabel)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
    }

    @ViewBuilder
    private var iconButton: some View {
        let symbol: String
        if !isReady {
            symbol = "waveform"
        } else if isPlayingThis {
            symbol = "pause.fill"
        } else {
            symbol = "play.fill"
        }
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(scheme.onPrimary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(isReady ? scheme.primary : scheme.surfaceVariant.opacity(0.65)))
            .opacity(isReady ? 1.0 : 0.6)
    }

    @ViewBuilder
    private var progressBar: some View {
        let p = isActive ? player.progress : 0.0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(scheme.onSurfaceVariant.opacity(0.30))
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 1)
                    .fill(scheme.primary)
                    .frame(width: geo.size.width * CGFloat(p), height: 3)
            }
        }
        .frame(height: 3)
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
