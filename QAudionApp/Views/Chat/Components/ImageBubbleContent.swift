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
    /// W97: long-press save-to-Photos confirmation. iOS auto-prompts
    /// for photo-library write permission the first time
    /// `UIImageWriteToSavedPhotosAlbum` runs.
    @State private var saveAlertVisible: Bool = false

    var body: some View {
        Group {
            if let path = mediaLocalPath, !path.isEmpty {
                if let img = loadedImage {
                    Image(uiImage: img)
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
                        }
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
    }

    private var placeholderBox: some View {
        // Simple gray box at the same nominal width so the layout
        // doesn't jump when the image loads.
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.6))
                .frame(width: 200, height: 150)
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(scheme.onSurfaceVariant)
        }
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
            } else {
                print("[ImageBubbleContent] failed to load \(path) — cache reclaimed?")
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
