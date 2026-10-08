import SwiftUI
import AVKit
import QAudionEngine

/// Bubble content of a file in the file transfer v2 format (WIRE_SPEC section 12): what the chat shows for a message whose body is a
/// file descriptor, in place of the text it is made of (12.7.1: the body is never shown as text). The same view serves a 1:1 chat and
/// a group, a received row and the sender's own.
///
///   - A document: the card with its name and size and, for a received one that is not on this device, the download button; once
///     downloaded, the ordinary file bubble (`FileBubbleContent`) with its save and share buttons.
///   - An image: the image itself once it is on this device (`ImageBubbleContent`: full screen, gallery, save, share); until then a
///     card with the thumbnail (or the tiny preview) and the progress or the download button.
///   - A voice note: the player (`VoiceNoteBubbleContent`) with the duration of the descriptor; a received one is fetched on arrival,
///     so it is the player waiting for the file, and only a failure or a very large one shows the card.
///   - A video: the thumbnail with a play button once the file is on this device, the download button before; a received video is
///     never fetched without a tap.
///
/// The key, the file id and the token stay in the row's body and are never read here: a download starts from the whole row.
struct FileV2BubbleContent: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    /// The key of the row in the download center (the message id, or the id of the group row).
    let rowKey: String
    /// The id the image and voice bubbles use for the row (the gallery, the player).
    let rowId: UUID
    let isOutgoing: Bool
    let info: FileV2ChatFile
    /// The decrypted file on this device as the row records it (a received file after the download, or the sender's own copy).
    let localPath: String?
    let exportBlocked: Bool
    @ObservedObject var downloads: FileV2DownloadCenter
    var saveRequest: Binding<Bool>? = nil
    var shareRequest: Binding<Bool>? = nil
    var galleryItems: [ImageGalleryItem] = []
    /// The user asked for the file (the download button, or "Riprova").
    var onDownload: () -> Void = {}
    /// The bubble appeared and the file is not on this device: a received row asks the center to fetch what is fetched on arrival.
    var onAppearWithoutFile: () -> Void = {}
    /// A voice note or an image was opened: the caller sends the read receipt.
    var onOpened: (() -> Void)? = nil
    /// Non-nil while a call is up: a voice note and a video play through the shared audio session, which belongs to the call. They then
    /// play nothing and call this to tell why.
    var onBlockedByCall: (() -> Void)? = nil

    @State private var thumbnail: UIImage? = nil
    @State private var playing: VideoTarget? = nil
    @State private var sharing: VideoTarget? = nil

    private struct VideoTarget: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Identity of the thumbnail load: it runs again when the thumbnail lands on disk.
    private struct ThumbnailKey: Equatable {
        let ready: Bool
    }

    /// The decrypted file when it is still on disk (the system may reclaim the caches directory).
    private var readablePath: String? {
        FileV2DownloadCenter.fileExists(atPath: localPath) ? localPath : nil
    }

    private var sizeLabel: String? {
        guard info.size > 0 else { return nil }
        return Self.byteFormatter.string(fromByteCount: Int64(clamping: info.size))
    }

    private var isAutomatic: Bool {
        guard let kind = info.descriptorKind else { return false }
        return FileV2AutoDownloadPolicy.isAutomatic(kind: kind, size: info.size)
    }

    private var failedText: String? {
        if case .failed(let text)? = downloads.state(for: rowKey) { return text }
        return nil
    }

    var body: some View {
        content
            .onAppear {
                if readablePath == nil { onAppearWithoutFile() }
            }
            .task(id: ThumbnailKey(ready: downloads.thumbnailReady.contains(rowKey))) {
                await loadThumbnail()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch info.kind {
        case "image": imageContent
        case "voice": voiceContent
        case "video": videoContent
        default: documentContent
        }
    }

    // MARK: A document

    @ViewBuilder
    private var documentContent: some View {
        if !isOutgoing, let path = readablePath {
            FileBubbleContent(messageId: rowId, mediaLocalPath: path, fileSizeBytes: Int64(clamping: info.size),
                              exportBlocked: exportBlocked)
        } else {
            card(systemImage: "doc.fill")
        }
    }

    // MARK: An image

    @ViewBuilder
    private var imageContent: some View {
        if let path = readablePath {
            ImageBubbleContent(messageId: rowId, mediaLocalPath: path, saveRequest: saveRequest, shareRequest: shareRequest,
                               galleryItems: galleryItems, exportBlocked: exportBlocked)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if thumbnail != nil { pictureBox(overlay: false) }
                card(systemImage: "photo")
            }
        }
    }

    // MARK: A voice note

    @ViewBuilder
    private var voiceContent: some View {
        if readablePath != nil || voiceIsComing {
            VoiceNoteBubbleContent(player: VoiceNotePlayer.shared, messageId: rowId, mediaLocalPath: readablePath,
                                   durationMs: info.hints.durationMs ?? 0, shareRequest: shareRequest, onOpened: onOpened,
                                   onBlockedByCall: onBlockedByCall, wave: info.hints.drawableWave)
        } else {
            card(systemImage: "waveform")
        }
    }

    /// A received voice note that is on its way (fetched on arrival) and has not failed: the player shows it is waiting.
    private var voiceIsComing: Bool {
        !isOutgoing && isAutomatic && failedText == nil
    }

    // MARK: A video

    @ViewBuilder
    private var videoContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            pictureBox(overlay: true)
            HStack(spacing: 8) {
                if let durationLabel { Text(durationLabel) }
                if let sizeLabel { Text(sizeLabel) }
                Spacer(minLength: 0)
                if let url = readableURL, !exportBlocked {
                    Button(action: { sharing = VideoTarget(url: url) }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .qaudionStyle(type.labelSmall)
            .foregroundStyle(scheme.onSurfaceVariant)
            if !isOutgoing, readablePath == nil { statusRow }
        }
        .fullScreenCover(item: $playing) { target in
            FileV2VideoPlayerView(url: target.url, onDismiss: { playing = nil })
        }
        .sheet(item: $sharing) { target in
            ActivityShareSheet(activityItems: [target.url])
        }
    }

    private var readableURL: URL? {
        readablePath.map { URL(fileURLWithPath: $0) }
    }

    private var durationLabel: String? {
        guard let ms = info.hints.durationMs, ms > 0 else { return nil }
        let total = Int((Double(ms) / 1000.0).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The thumbnail (or the tiny preview, or a plain box) at the size the descriptor announces, with the play button over it for a
    /// video that is on this device.
    private func pictureBox(overlay: Bool) -> some View {
        let size = Self.boxSize(width: info.hints.width, height: info.hints.height)
        return ZStack {
            Rectangle().fill(scheme.surfaceVariant.opacity(0.65))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            if overlay { playOverlay }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { openVideo() }
    }

    @ViewBuilder
    private var playOverlay: some View {
        if readablePath != nil {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 3)
                .accessibilityLabel(String(localized: "file_v2.video.play", defaultValue: "Riproduci video", comment: "Accessibility label of the play button over a video in a chat."))
        } else if case .downloading(let progress)? = downloads.state(for: rowKey) {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .tint(.white)
        } else {
            Image(systemName: "video.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func openVideo() {
        guard info.kind == "video", let url = readableURL else { return }
        if let blocked = onBlockedByCall {
            blocked()
            return
        }
        playing = VideoTarget(url: url)
        onOpened?()
    }

    // MARK: The card

    private func card(systemImage: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(scheme.surfaceVariant.opacity(0.65))
                    .frame(width: 36, height: 36)
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
            }
            VStack(alignment: .leading, spacing: 4) {
                // Enigma mode (visual effect only): while this row is the one being animated (a file just announced), the name
                // line is the scene; otherwise it is exactly this Text.
                EnigmaAwareBody(rowId: rowKey, fallback: info.displayName, lineLimit: 2) {
                    Text(info.displayName)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                cardStatus
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var cardStatus: some View {
        if isOutgoing {
            if let sizeLabel {
                Text(sizeLabel)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        } else {
            statusRow
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let state = downloads.state(for: rowKey) {
            switch state {
            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 120)
                    Text("\(Int((progress * 100).rounded()))%")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                    actionButton(title: String(localized: "file_v2.cancel", defaultValue: "Annulla", comment: "Button that cancels the download of a received file."),
                                 systemImage: "xmark") { downloads.cancel(rowKey) }
                }
            case .failed(let text):
                VStack(alignment: .leading, spacing: 4) {
                    Text(text)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                    actionButton(title: String(localized: "file_v2.retry", defaultValue: "Riprova", comment: "Button that tries again to download a received file."),
                                 systemImage: "arrow.clockwise", action: onDownload)
                }
            }
        } else {
            HStack(spacing: 8) {
                if let sizeLabel, info.kind != "video" {
                    Text(sizeLabel)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                actionButton(title: String(localized: "file_v2.download", defaultValue: "Scarica", comment: "Button that downloads a received file."),
                             systemImage: "arrow.down.circle", action: onDownload)
            }
        }
    }

    @ViewBuilder
    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .qaudionStyle(type.labelSmall)
            }
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

    // MARK: The thumbnail

    /// The thumbnail file of the row when it is there, else the tiny preview of the descriptor. Decoded off the main actor.
    @MainActor
    private func loadThumbnail() async {
        guard info.kind == "image" || info.kind == "video" else { return }
        if let path = FileV2DownloadCenter.thumbnailPath(forKey: rowKey) {
            let url = URL(fileURLWithPath: path)
            let data: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
                try? Data(contentsOf: url)
            }.value
            if !Task.isCancelled, let data, let image = UIImage(data: data) {
                thumbnail = image
                return
            }
        }
        if thumbnail == nil, let preview = info.preview, let image = UIImage(data: preview) {
            thumbnail = image
        }
    }

    // MARK: Layout

    /// The size of the picture box: the announced aspect ratio fitted into 240 x 320 points, or 200 x 150 when none is announced. The
    /// hints are already limited (`FileV2MediaHints`), so the ratio is always a sane one.
    static func boxSize(width: Int?, height: Int?) -> CGSize {
        guard let width, let height, width > 0, height > 0 else { return CGSize(width: 200, height: 150) }
        let ratio = CGFloat(width) / CGFloat(height)
        var fittedWidth: CGFloat = 240
        var fittedHeight: CGFloat = fittedWidth / ratio
        if fittedHeight > 320 {
            fittedHeight = 320
            fittedWidth = fittedHeight * ratio
        }
        return CGSize(width: max(80, fittedWidth), height: max(60, fittedHeight))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

/// Plays a received (or sent) video that is on this device, full screen.
struct FileV2VideoPlayerView: View {
    let url: URL
    let onDismiss: () -> Void

    @State private var player: AVPlayer? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
        .onAppear {
            let created = AVPlayer(url: url)
            player = created
            created.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
