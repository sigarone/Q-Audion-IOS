import SwiftUI
import QAudionEngine

/// W82 — bubble content for image attachments.
///
/// Three states reflected in the UI:
///   - **Downloading**: `mediaLocalPath` is nil (the receive Task is
///     still fetching ciphertext). Shows a placeholder rectangle with
///     a spinner.
///   - **Ready (cached)**: `mediaLocalPath` points to a JPEG. Renders
///     the image at max width 240pt, aspect-fit. Tap → fullscreen
///     viewer (uses iOS' built-in QuickLook via SwiftUI sheet).
///   - **Decode failed**: `mediaLocalPath` is set but the file is
///     missing or unreadable (cache reclaimed). Shows a broken-link
///     icon + "Foto non disponibile" — user can long-press the bubble
///     to delete the row in a future patch.
///
/// W446: "Salva in Foto" / "Condividi" used to live in an inner
/// `.contextMenu` on the `Image` below. That competed with
/// `ChatDetailScreen`'s outer `.onLongPressGesture` (which opens
/// `BubbleActionSheet`) for the same long-press touch — a
/// `.contextMenu` registers a `UIContextMenuInteraction` directly on
/// its view and wins over an ancestor's plain SwiftUI
/// `.onLongPressGesture`, so long-pressing an image opened this menu
/// instead of the shared action sheet every other bubble type uses.
/// The actions now live in `BubbleActionSheet` (gated on
/// `mediaKind == .image`); this view exposes `saveRequest` /
/// `shareRequest` bindings so `ChatDetailScreen` can trigger them
/// from there.
struct ImageBubbleContent: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let messageId: UUID
    let mediaLocalPath: String?
    /// W446: bound by `ChatDetailScreen` so `BubbleActionSheet`'s
    /// "Salva in Foto" row can trigger `UIImageWriteToSavedPhotosAlbum`
    /// on the currently-loaded `UIImage` without duplicating the image
    /// decode/cache logic at the call site.
    var saveRequest: Binding<Bool>? = nil
    /// W446: bound by `ChatDetailScreen` so `BubbleActionSheet`'s
    /// "Condividi immagine" row can trigger the share sheet here,
    /// where the loaded `UIImage`/on-disk path already live.
    var shareRequest: Binding<Bool>? = nil

    @State private var fullscreen: Bool = false
    @State private var loadedImage: UIImage? = nil
    /// W123: tracks whether the load failed so we can show a retry
    /// button instead of an indefinite shimmer.
    @State private var loadFailed: Bool = false
    /// W97: long-press save-to-Photos confirmation. iOS auto-prompts
    /// for photo-library write permission the first time
    /// `UIImageWriteToSavedPhotosAlbum` runs.
    @State private var saveAlertVisible: Bool = false
    /// W100: share sheet target wrapper for `.sheet(item:)`. The
    /// activity items list contains either the on-disk URL (when the
    /// JPEG cache hit) or the in-memory UIImage (fallback).
    @State private var sharingTarget: ImageShareTarget? = nil

    private struct ImageShareTarget: Identifiable {
        let id = UUID()
        let activityItems: [Any]
    }

    var body: some View {
        Group {
            if let path = mediaLocalPath, !path.isEmpty {
                if let img = loadedImage {
                    Image(uiImage: img)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { fullscreen = true }
                } else if loadFailed {
                    failedBox(path: path)
                } else {
                    placeholderBox
                        .onAppear { loadIfNeeded(path: path) }
                }
            } else {
                downloadingBox
            }
        }
        .sheet(isPresented: $fullscreen) {
            if let img = loadedImage {
                ImageFullscreenView(image: img, onDismiss: { fullscreen = false })
            }
        }
        .alert("Salvata in Foto", isPresented: $saveAlertVisible) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("L'immagine è ora nella libreria Foto.")
        }
        .sheet(item: $sharingTarget) { target in
            ActivityShareSheet(activityItems: target.activityItems)
        }
        // W446: `BubbleActionSheet`'s "Salva in Foto" / "Condividi
        // immagine" rows flip these bindings to trigger the same
        // save/share logic the old inner `.contextMenu` used —
        // unchanged behaviour, just invoked from the shared sheet
        // instead of a competing long-press recognizer.
        .onChange(of: saveRequest?.wrappedValue ?? false) { requested in
            guard requested, let img = loadedImage else { return }
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            saveAlertVisible = true
            saveRequest?.wrappedValue = false
        }
        .onChange(of: shareRequest?.wrappedValue ?? false) { requested in
            guard requested, let img = loadedImage else { return }
            if let path = mediaLocalPath, !path.isEmpty {
                sharingTarget = ImageShareTarget(activityItems: [URL(fileURLWithPath: path)])
            } else {
                sharingTarget = ImageShareTarget(activityItems: [img])
            }
            shareRequest?.wrappedValue = false
        }
    }

    private var placeholderBox: some View {
        // W111: shimmering skeleton instead of static gray placeholder.
        // Animated linear gradient sweep gives a "loading" affordance
        // matching iOS system patterns. Fixed dimensions match the
        // post-load max so the layout doesn't jump when the image
        // appears.
        ShimmeringRectangle()
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var downloadingBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.6))
                .frame(width: 200, height: 150)
            VStack(spacing: 8) {
                ProgressView().scaleEffect(0.9)
                Text("Download in arrivo")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
    }

    private func loadIfNeeded(path: String) {
        // Off-main load to avoid jank when the row scrolls into view.
        Task { @MainActor in
            let url = URL(fileURLWithPath: path)
            // Read the bytes (small enough at 2048px max + JPEG q=0.85)
            // synchronously — the image cap is 10 MB.
            if let data = try? Data(contentsOf: url),
               let img = UIImage(data: data) {
                self.loadedImage = img
                self.loadFailed = false
            } else {
                print("[ImageBubbleContent] failed to load \(path) — cache reclaimed?")
                self.loadFailed = true
            }
        }
    }

    /// W123: error-state view shown when the cache file is missing or
    /// unreadable. Tap retries the load — useful when the user
    /// scrolled past + back, in case the cache repopulated.
    @ViewBuilder
    private func failedBox(path: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.6))
                .frame(width: 200, height: 150)
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundStyle(scheme.onSurfaceVariant)
                Text("Foto non disponibile")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Text("Tocca per riprovare")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.primary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            loadFailed = false
            loadIfNeeded(path: path)
        }
    }
}

/// W111: shimmering skeleton placeholder. Linear gradient sweep
/// animated 1.5s → seemless looped. iOS system pattern for image
/// loading states.
private struct ShimmeringRectangle: View {
    @State private var phase: CGFloat = -1.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Rectangle().fill(Color.gray.opacity(0.20))
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.45),
                        Color.white.opacity(0)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: w * 0.6)
                .offset(x: phase * w)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
        }
    }
}

/// Minimal fullscreen image viewer — pinch-to-zoom is iOS' native
/// behaviour on `Image` inside a `ScrollView` on iOS 17+. For iOS 16
/// the user just sees a big aspect-fit image with a Done button.
/// W125: metadata header overlays the dismiss button — shows W×H plus
/// the rough size in MP if reachable.
struct ImageFullscreenView: View {
    @Environment(\.qaudionScheme) private var scheme
    let image: UIImage
    let onDismiss: () -> Void

    /// W135: double-tap toggle 1x ↔ 2x. iOS Photos pattern. 0.25s
    /// spring animates the scaleEffect.
    @State private var zoomed: Bool = false

    private var metadataLine: String {
        let w = Int(image.size.width)
        let h = Int(image.size.height)
        let mp = Double(w * h) / 1_000_000.0
        if mp >= 0.05 {
            return String(format: "%d × %d  ·  %.1f MP", w, h, mp)
        } else {
            return "\(w) × \(h)"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(zoomed ? 2.0 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.85),
                               value: zoomed)
                    .onTapGesture(count: 2) {
                        zoomed.toggle()
                    }
            }
            VStack {
                HStack {
                    Text(metadataLine)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(.black.opacity(0.4))
                        )
                        .padding(.leading)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}
