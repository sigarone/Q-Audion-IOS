import SwiftUI
import UIKit
import QAudionEngine

/// W99: minimal UIActivityViewController wrapper. Used by chat
/// attachment bubbles for the system share sheet (AirDrop / Files /
/// Mail / Messages). Mirrors VCardShareSheet without the temp-file
/// dance — caller already has the URL on disk.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}

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
///
/// W446: "Condividi audio" used to live in an inner `.contextMenu` on
/// `bubbleRow` (i.e. the entire body of this view). That competed
/// with `ChatDetailScreen`'s outer `.onLongPressGesture` (which opens
/// `BubbleActionSheet`) for the same long-press touch — a
/// `.contextMenu` registers a `UIContextMenuInteraction` directly on
/// its view and wins over an ancestor's plain SwiftUI
/// `.onLongPressGesture`, so long-pressing a voice note opened this
/// menu instead of the shared action sheet every other bubble type
/// uses. The action now lives in `BubbleActionSheet` (gated on
/// `mediaKind == .voiceNote`); this view exposes `shareRequest` so
/// `ChatDetailScreen` can trigger it from there.
struct VoiceNoteBubbleContent: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @ObservedObject var player: VoiceNotePlayer

    let messageId: UUID
    let mediaLocalPath: String?
    let durationMs: Int64
    /// W446: bound by `ChatDetailScreen` so `BubbleActionSheet`'s
    /// "Condividi audio" row can trigger the share sheet here, where
    /// the cached file path already lives.
    var shareRequest: Binding<Bool>? = nil

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

    /// Identifiable URL wrapper so SwiftUI's `.sheet(item:)` accepts it.
    private struct ShareTarget: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var sharingURL: ShareTarget? = nil

    var body: some View {
        bubbleRow
            .sheet(item: $sharingURL) { target in
                ActivityShareSheet(activityItems: [target.url])
            }
            // W446: "Condividi audio" moved to `BubbleActionSheet` (see
            // the struct doc comment above) — `shareRequest` is flipped
            // by that sheet's row and drives the same share-sheet
            // presentation the old inner `.contextMenu` used. Disabled
            // while the file is still downloading, same as before.
            .onChange(of: shareRequest?.wrappedValue ?? false) { requested in
                guard requested, let path = mediaLocalPath, !path.isEmpty else {
                    shareRequest?.wrappedValue = false
                    return
                }
                sharingURL = ShareTarget(url: URL(fileURLWithPath: path))
                shareRequest?.wrappedValue = false
            }
    }

    private var bubbleRow: some View {
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
            // W95+W105: speed control + ±15s skip. Only visible while
            // THIS note is the active one. Skip-back/forward use the
            // VoiceNotePlayer.skip API; chip cycles speed.
            if isActive {
                Button {
                    player.skip(seconds: -15.0, messageId: messageId)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(scheme.onSurface)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Indietro 15 secondi")

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

                Button {
                    player.skip(seconds: 15.0, messageId: messageId)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(scheme.onSurface)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Avanti 15 secondi")
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
            // W126: subtle scale pulse on the icon when this bubble is
            // the actively-playing note. Cue the user that this is the
            // bubble making sound (when multiple voice notes are
            // visible, distinguishing 'which one is talking right now'
            // can be harder than it sounds).
            .scaleEffect(isPlayingThis ? 1.06 : 1.0)
            .animation(
                isPlayingThis
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: isPlayingThis
            )
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
            unplayedColor: scheme.onSurfaceVariant.opacity(isActive ? 0.45 : 0.30),
            // W98: drag-to-scrub only enabled while this bubble is the
            // active player. Otherwise the gesture is nil and the row
            // is just a passive visualization.
            onScrub: isActive ? { pos in
                player.seek(to: pos, messageId: messageId)
            } : nil
        )
        .frame(height: 22)
    }

    /// W92: deterministic-pseudo-random waveform row. The seed is
    /// derived from the messageId so each bubble keeps a stable shape
    /// across re-renders (without persisting the per-bar amplitudes
    /// to disk). Bar amplitudes range 0.25...1.0 of the row height.
    /// W98: drag-to-scrub gesture on the row when this bubble is the
    /// active note — calls onScrub with normalized position 0...1.
    private struct WaveformRow: View {
        let barCount: Int
        let seed: Int
        let progress: Double
        let playedColor: Color
        let unplayedColor: Color
        let onScrub: ((Double) -> Void)?

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
                .contentShape(Rectangle())
                .gesture(
                    onScrub.map { handler in
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let pos = max(0.0, min(1.0, Double(value.location.x / geo.size.width)))
                                handler(pos)
                            }
                    }
                )
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

    /// W124: file existence check for the cached path. Used by the
    /// bubble to display 'file mancante' instead of an inert play
    /// icon when the cache was reclaimed.
    private var fileExists: Bool {
        guard let path = mediaLocalPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func handleTap() {
        guard let path = mediaLocalPath, !path.isEmpty else { return }
        // W124: missing cache → no-op rather than crash the player.
        guard FileManager.default.fileExists(atPath: path) else {
            print("[VoiceNoteBubbleContent] file missing at \(path)")
            return
        }
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
