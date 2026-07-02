import SwiftUI
import UIKit
import QAudionEngine

/// W446 — bubble content for generic (non-image, non-audio) file
/// attachments: PDFs, documents, archives, anything that isn't already
/// routed to ``ImageBubbleContent`` or ``VoiceNoteBubbleContent``.
///
/// Architecturally this is closer to ``VoiceNoteBubbleContent`` than to
/// ``ImageBubbleContent``: the payload is opaque bytes + a filename, not
/// something that can be previewed inline. It reuses the exact same
/// decrypt/cache plumbing — by the time this view renders, the qfile /
/// attach_announce receive pipeline (``ChatVoiceNoteReceiver``, wired
/// from `AppState.handleIncomingMessage`) has already downloaded +
/// decrypted the attachment to a local cache file and stamped
/// `Message.mediaLocalPath` via `ConversationStore.setMediaInfo`. This
/// view never touches ciphertext or the vault — it only reads the
/// already-decrypted bytes off disk, same as the other two bubbles.
///
/// Two states reflected in the UI:
///   - **Downloading**: `mediaLocalPath` is nil (the receive Task is
///     still fetching/decrypting). Shows a spinner + "Download in arrivo".
///   - **Ready**: `mediaLocalPath` points at the decrypted cache file.
///     Shows a document icon, a best-effort filename (derived from the
///     cache path — the wire protocol does not currently carry the
///     original filename, see `FileTransfer.FileMarker.QFile.name` /
///     `AttachAnnounceMeta`, neither of which round-trips to `Message`),
///     and two actions:
///       - **Salva**: opens the system share sheet
///         (`UIActivityViewController`, same `ActivityShareSheet` wrapper
///         `VoiceNoteBubbleContent` already uses for its "Condividi audio"
///         action) — iOS surfaces "Salva in File" as a built-in activity,
///         which is the same document-save path `UIDocumentPickerViewController`
///         would offer, without introducing a second file-writing
///         mechanism.
///       - **Condividi**: same `ActivityShareSheet`, so AirDrop / Mail /
///         Messages / third-party apps all work identically to how they
///         already do for voice notes and images.
struct FileBubbleContent: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let messageId: UUID
    let mediaLocalPath: String?
    /// Byte size of the decrypted file, when known. `nil` hides the
    /// size line rather than showing a misleading "0 KB".
    let fileSizeBytes: Int64?

    init(messageId: UUID, mediaLocalPath: String?, fileSizeBytes: Int64? = nil) {
        self.messageId = messageId
        self.mediaLocalPath = mediaLocalPath
        self.fileSizeBytes = fileSizeBytes
    }

    private var isReady: Bool {
        guard let path = mediaLocalPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Best-effort display name. The wire protocol (qfile marker /
    /// attach_announce) doesn't currently preserve the sender's
    /// original filename through to `Message` (see `AppState.swift`
    /// receive path — `ConversationStore.setMediaInfo` only stamps
    /// path/duration/mime), so we fall back to the cache file's own
    /// name, same as the information already available (implicitly) to
    /// `ImageBubbleContent`.
    private var displayName: String {
        guard let path = mediaLocalPath, !path.isEmpty else {
            return "Allegato"
        }
        return (path as NSString).lastPathComponent
    }

    private var fileExtension: String {
        (displayName as NSString).pathExtension.uppercased()
    }

    private var sizeLabel: String? {
        guard let bytes = fileSizeBytes, bytes > 0 else { return nil }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    /// Identifiable URL wrapper so SwiftUI's `.sheet(item:)` accepts it.
    /// Mirrors `VoiceNoteBubbleContent.ShareTarget` exactly.
    private struct ShareTarget: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var sharingURL: ShareTarget? = nil
    /// Distinguishes "Salva" from "Condividi" only for the confirmation
    /// copy shown after the share sheet completes — both drive the same
    /// `ActivityShareSheet`.
    @State private var saveConfirmVisible: Bool = false

    var body: some View {
        bubbleRow
            .sheet(item: $sharingURL) { target in
                ActivityShareSheet(activityItems: [target.url])
            }
            .alert("File pronto per il salvataggio", isPresented: $saveConfirmVisible) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Scegli \"Salva in File\" nella schermata di condivisione per salvare il documento sul dispositivo.")
            }
    }

    private var bubbleRow: some View {
        HStack(spacing: 10) {
            iconBadge
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isReady {
                    HStack(spacing: 6) {
                        if let sizeLabel {
                            Text(sizeLabel)
                                .qaudionStyle(type.labelSmall)
                                .foregroundStyle(scheme.onSurfaceVariant)
                        }
                        actionButton(title: "Salva", systemImage: "square.and.arrow.down") {
                            guard let path = mediaLocalPath, !path.isEmpty else { return }
                            sharingURL = ShareTarget(url: URL(fileURLWithPath: path))
                            saveConfirmVisible = true
                        }
                        actionButton(title: "Condividi", systemImage: "square.and.arrow.up") {
                            guard let path = mediaLocalPath, !path.isEmpty else { return }
                            sharingURL = ShareTarget(url: URL(fileURLWithPath: path))
                        }
                    }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // W446: no inner .contextMenu here — the always-visible inline
        // Salva/Condividi buttons above already give a tap-accessible
        // path to both actions, and a .contextMenu on this row would
        // reintroduce the exact long-press-hijack bug BubbleActionSheet's
        // consolidation just fixed for image/voice-note bubbles (a
        // .contextMenu installs its own UIContextMenuInteraction, which
        // wins the long-press touch over ChatDetailScreen's outer
        // .onLongPressGesture — see BubbleActionSheet's doc comment).
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

    /// No mime-specific icon set exists anywhere in the codebase (the
    /// composer's paperclip button is generic too), so this stays a
    /// single generic document glyph — matches the "no icon mapping
    /// exists, don't invent one" guidance. The file extension badge
    /// (e.g. "PDF") next to it gives the type cue instead.
    @ViewBuilder
    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(isReady ? scheme.primary : scheme.surfaceVariant.opacity(0.65))
                .frame(width: 36, height: 36)
            Image(systemName: "doc.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(scheme.onPrimary)
                .opacity(isReady ? 1.0 : 0.6)
        }
        .overlay(alignment: .bottom) {
            if isReady, !fileExtension.isEmpty {
                Text(fileExtension)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(scheme.onPrimary)
                    .padding(.horizontal, 3)
                    .background(
                        Capsule().fill(scheme.secondary)
                    )
                    .offset(y: 6)
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
