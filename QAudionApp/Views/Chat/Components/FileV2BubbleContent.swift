import SwiftUI
import QAudionEngine

/// Bubble content of a document in the file transfer v2 format (WIRE_SPEC section 12): the card the chat shows for a message whose
/// body is a file descriptor, in place of the text it is made of (12.7.1: the body is never shown as text).
///
///   - A file being sent, or sent: the name and, once the descriptor exists, the size. The upload progress and the delivery state
///     are the bubble's own (`MessageBubble`'s delivery indicator).
///   - A received file that is not on this device yet: the name, the size and a button to download it. The download verifies and
///     decrypts every chunk and shows its progress and, when it fails, why (`FileV2DownloadCenter`).
///   - A received file that is on this device: the ordinary file bubble (`FileBubbleContent`), with its save and share buttons.
///
/// The key, the file id and the token stay in the message body and are never read here: the download starts from the whole message.
struct FileV2BubbleContent: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let message: Message
    let info: FileV2ChatFile
    @ObservedObject var downloads: FileV2DownloadCenter
    let onDownload: () -> Void

    private var isOutgoing: Bool { message.direction == .outgoing }

    /// The decrypted file of a received message, when it is still on disk (the system may reclaim the caches directory).
    private var localPath: String? {
        guard let path = message.mediaLocalPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private var sizeLabel: String? {
        guard info.size > 0 else { return nil }
        return Self.byteFormatter.string(fromByteCount: Int64(clamping: info.size))
    }

    var body: some View {
        if !isOutgoing, let path = localPath {
            FileBubbleContent(messageId: message.id, mediaLocalPath: path, fileSizeBytes: Int64(clamping: info.size),
                              exportBlocked: message.exportBlocked ?? false)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(scheme.surfaceVariant.opacity(0.65))
                    .frame(width: 36, height: 36)
                Image(systemName: "doc.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(scheme.onSurface)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(info.displayName)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusRow
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusRow: some View {
        if isOutgoing {
            if let sizeLabel {
                Text(sizeLabel)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        } else if let state = downloads.state(for: message.id) {
            switch state {
            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 120)
                    Text("\(Int((progress * 100).rounded()))%")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                    actionButton(title: String(localized: "file_v2.cancel", defaultValue: "Annulla", comment: "Button that cancels the download of a received file."),
                                 systemImage: "xmark") { downloads.cancel(message.id) }
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
                if let sizeLabel {
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

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
