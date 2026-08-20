import SwiftUI
import QAudionEngine

/// Fase 2 — one conversation image reachable from the fullscreen
/// gallery. `ChatDetailScreen`/`GroupChatScreen` build the full,
/// in-display-order list (every image row with a decrypted local
/// cache path, self included) once per render and hand it to every
/// `ImageBubbleContent` row so tapping ANY image opens a gallery that
/// can swipe to every other image in the same conversation — not just
/// the one tapped. Empty (the default) degrades to a single-image
/// gallery, so a call site that hasn't been updated keeps working.
struct ImageGalleryItem: Identifiable, Equatable {
    let id: UUID
    let localPath: String
}

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
    /// Fase 2 — see `ImageGalleryItem` doc comment above.
    var galleryItems: [ImageGalleryItem] = []
    /// Export-permission — mirrors `Message.exportBlocked` /
    /// `GroupMessageStore.Stored.exportBlocked`. `false` (default) =
    /// export allowed, unchanged behaviour. `true` = the sender marked
    /// this attachment export-blocked: `saveRequest`/`shareRequest` are
    /// honored at the BINDING level too (not just hidden upstream in
    /// `BubbleActionSheet`) — defense in depth, per the "disable/hide
    /// with a clear message, never silently degrade" instruction. This
    /// is a client-side/UI-level honor-system gate, same trust model as
    /// view-once — no DRM, no server enforcement.
    var exportBlocked: Bool = false

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
    /// Export-permission gate feedback — shown when a save/share
    /// request lands while `exportBlocked` is true, so the user gets an
    /// explicit explanation instead of a silently-ignored tap.
    @State private var exportBlockedAlertVisible: Bool = false

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
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Immagine allegata")
                        .accessibilityHint("Tocca due volte per visualizzare a schermo intero")
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
            // Fase 2 — `loadedImage` only gates presentation (confirms this
            // bubble's own image decoded); the gallery itself lazily
            // decodes each page independently, so other conversation
            // images swiped into view don't block on this one.
            if loadedImage != nil, let path = mediaLocalPath, !path.isEmpty {
                let items = galleryItems.isEmpty
                    ? [ImageGalleryItem(id: messageId, localPath: path)]
                    : galleryItems
                let startIndex = items.firstIndex(where: { $0.id == messageId }) ?? 0
                ImageFullscreenView(items: items, startIndex: startIndex,
                                    onDismiss: { fullscreen = false })
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
        .alert("Esportazione non consentita", isPresented: $exportBlockedAlertVisible) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Il mittente ha disattivato il salvataggio e la condivisione per questo allegato.")
        }
        // W446: `BubbleActionSheet`'s "Salva in Foto" / "Condividi
        // immagine" rows flip these bindings to trigger the same
        // save/share logic the old inner `.contextMenu` used —
        // unchanged behaviour, just invoked from the shared sheet
        // instead of a competing long-press recognizer.
        // Export-permission gate checked HERE too (not just upstream in
        // BubbleActionSheet, which hides the rows entirely when
        // exportBlocked) — defense in depth so this view never performs
        // the save/share even if some other future call site forgets to
        // gate its own entry point.
        .onChange(of: saveRequest?.wrappedValue ?? false) { requested in
            guard requested else { return }
            guard !exportBlocked else {
                exportBlockedAlertVisible = true
                saveRequest?.wrappedValue = false
                return
            }
            guard let img = loadedImage else { return }
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            saveAlertVisible = true
            saveRequest?.wrappedValue = false
        }
        .onChange(of: shareRequest?.wrappedValue ?? false) { requested in
            guard requested else { return }
            guard !exportBlocked else {
                exportBlockedAlertVisible = true
                shareRequest?.wrappedValue = false
                return
            }
            guard let img = loadedImage else { return }
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Foto non disponibile")
        .accessibilityHint("Tocca due volte per riprovare")
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

/// Fase 2 — fullscreen image gallery. Swipes (native `TabView` paging)
/// across every `ImageGalleryItem` in the conversation, starting on the
/// tapped image. Each page pinch-zooms (`MagnificationGesture`, 1x–4x)
/// with drag-to-pan once zoomed, and double-tap resets to 1x — same
/// gesture set as the Photos app. Replaces the previous single-image,
/// double-tap-only 2x toggle (W135).
/// W125: metadata header overlays the dismiss button — shows W×H plus
/// the rough size in MP for whichever page is currently on screen.
struct ImageFullscreenView: View {
    let items: [ImageGalleryItem]
    let onDismiss: () -> Void

    @State private var selection: Int
    /// Populated lazily as each page decodes its own image, so the
    /// metadata line has something to read for the current page without
    /// the gallery having to decode every image up front.
    @State private var loadedImages: [Int: UIImage] = [:]

    init(items: [ImageGalleryItem], startIndex: Int, onDismiss: @escaping () -> Void) {
        self.items = items
        self.onDismiss = onDismiss
        _selection = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
    }

    private var metadataLine: String {
        guard let img = loadedImages[selection] else { return "" }
        let w = Int(img.size.width)
        let h = Int(img.size.height)
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
            TabView(selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    GalleryPage(localPath: item.localPath,
                                onLoaded: { img in loadedImages[index] = img })
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            VStack {
                HStack {
                    if !metadataLine.isEmpty {
                        Text(metadataLine)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(.black.opacity(0.4))
                            )
                            .padding(.leading)
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding()
                }
                Spacer()
                // Fase 2 — "N / total" page counter, only meaningful once
                // there's more than one image to swipe through.
                if items.count > 1 {
                    Text("\(selection + 1) / \(items.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 24)
                }
            }
        }
    }
}

/// Fase 2 — one page of the fullscreen gallery. Decodes its own image
/// off the local cache path (same `Data(contentsOf:)` + `UIImage(data:)`
/// load `ImageBubbleContent.loadIfNeeded` uses — no second decode path)
/// so opening the gallery never blocks on every image in the
/// conversation at once. Pinch-to-zoom + drag-to-pan once zoomed;
/// double-tap resets to 1x.
private struct GalleryPage: View {
    let localPath: String
    let onLoaded: (UIImage) -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Group {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnifyGesture)
                        .simultaneousGesture(panGesture)
                        .onTapGesture(count: 2) { resetZoom() }
                } else if loadFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("Immagine non disponibile")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil, !loadFailed else { return }
        let path = localPath
        guard !path.isEmpty else { loadFailed = true; return }
        Task { @MainActor in
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                self.image = img
                self.onLoaded(img)
            } else {
                self.loadFailed = true
            }
        }
    }

    private func resetZoom() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1.0), 4.0)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.0 { resetZoom() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                 height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
}
