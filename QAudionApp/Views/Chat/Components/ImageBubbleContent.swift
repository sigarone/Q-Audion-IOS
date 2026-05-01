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
struct ImageBubbleContent: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let messageId: UUID
    let mediaLocalPath: String?

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
                        .contextMenu {
                            // W97: long-press → save to Photos. Use
                            // the system "Salva immagine" idiom so
                            // users find it where they expect.
                            Button {
                                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                                saveAlertVisible = true
                            } label: {
                                Label("Salva in Foto", systemImage: "square.and.arrow.down")
                            }
                            // W100: share sheet — AirDrop / Files /
                            // Messages / Mail. Prefer the on-disk URL
                            // so receivers get the original JPEG with
                            // mime preserved; fall back to UIImage if
                            // path is missing.
                            Button {
                                if let path = mediaLocalPath, !path.isEmpty {
                                    sharingTarget = ImageShareTarget(
                                        activityItems: [URL(fileURLWithPath: path)]
                                    )
                                } else {
                                    sharingTarget = ImageShareTarget(activityItems: [img])
                                }
                            } label: {
                                Label("Condividi", systemImage: "square.and.arrow.up")
                            }
                        }
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
struct ImageFullscreenView: View {
    @Environment(\.qaudionScheme) private var scheme
    let image: UIImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack {
                HStack {
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
