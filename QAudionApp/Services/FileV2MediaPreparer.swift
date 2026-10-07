import Foundation
import UIKit
import ImageIO
import AVFoundation
import QAudionEngine

/// Makes ready what the v2 sender needs to send an image, a voice note or a video: the file to upload (which the sender's own bubble
/// also shows), the display hints (`m`), the tiny preview (`pv`) and the thumbnail (a small JPEG that becomes a v2 file of its own).
/// UIKit, ImageIO and AVFoundation do the decoding and drawing here; the geometry and the limits are the engine's
/// (`FileV2ThumbnailPlan`, `FileV2MediaHints`), and so is the removal of the metadata of a picture (`ImageMetadataStripper`), so they
/// have tests. An image never leaves the device as the user picked or shot it: what is uploaded is a cleaned COPY
/// (`FileV2ImageCleaner`), and so are its thumbnail and its tiny preview.
///
/// Nothing here touches the network, a key or a token, and nothing prints a name or a path.
enum FileV2MediaPreparer {

    /// Everything one send needs besides who it goes to and the choices of the pre-send dialog.
    struct Prepared {
        let kind: FileV2Descriptor.Kind
        /// The file that is uploaded. For an image and a voice note it is the copy in the caches directory that the bubble shows.
        let sourceURL: URL
        /// The name written in the descriptor (`nm`).
        let name: String
        let mimeType: String
        let media: FileV2Descriptor.Media?
        /// The tiny preview (`pv`), at most 2048 bytes.
        let preview: Data?
        /// The thumbnail file (also where the bubble reads it from), or `nil` when there is none.
        let thumbnailURL: URL?
        /// The duration of a voice note or a video, in milliseconds.
        let durationMs: Int64?
    }

    enum PrepareError: Error {
        /// The bytes are not an image this device can decode.
        case undecodable
        /// The image is larger than the cap after it was downscaled.
        case tooLarge
        /// The file could not be read or copied.
        case unreadable
        /// The metadata of the picture (location, device, time) cannot be removed: its format is not understood, or the file is
        /// damaged. Nothing is sent, and the original is never sent instead.
        case notCleanable
    }

    /// The most an image weighs after it was downscaled and re-encoded (the cap the chat always had).
    static let maxImageBytes = 10 * 1024 * 1024
    /// The longest side of an image that is sent, in pixels.
    static let maxImageSide = 2048

    // MARK: An image

    /// A photo of the chat (library, camera, clipboard) as the bytes the picker gave, of any format the device decodes. What is saved
    /// in `Caches/images/<key>.<ext>` and uploaded is a CLEANED COPY (`FileV2ImageCleaner`): without location, device identifiers or
    /// time, the Orientation the only tag left. JPEG, PNG, WEBP and GIF are copied without re-encoding when they are within the
    /// limits of the chat (2048 px on the long side, 10 MB); everything else is re-encoded. The original bytes are never sent.
    static func prepareImage(rawData: Data, key: String) throws -> Prepared {
        let cleaned = try cleanedImage(rawData, policy: .chatPhoto)
        return try storeCleanImage(cleaned, key: key, name: nil)
    }

    /// A picture picked as a FILE (the document picker): the same cleaned copy, kept at its size and named after the picked file (with
    /// the extension of the copy). The picked file is only read: it is never changed, moved or deleted. The caller holds the
    /// security-scoped access to `fileURL` until this returns.
    static func prepareImage(fileURL: URL, key: String, pickedName: String) throws -> Prepared {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw PrepareError.unreadable
        }
        let cleaned = try cleanedImage(data, policy: .pickedFile)
        return try storeCleanImage(cleaned, key: key, name: FileV2ImageCleaner.name(for: pickedName, format: cleaned.format))
    }

    private static func cleanedImage(_ data: Data, policy: FileV2ImageCleaner.Policy) throws -> FileV2CleanImage {
        do {
            return try FileV2ImageCleaner.clean(data, policy: policy)
        } catch FileV2ImageCleaner.CleanError.tooLarge {
            throw PrepareError.tooLarge
        } catch {
            throw PrepareError.notCleanable
        }
    }

    /// Writes the cleaned copy under a name of its own (the key is a random UUID, never the name of the picked file) and describes it.
    private static func storeCleanImage(_ cleaned: FileV2CleanImage, key: String, name: String?) throws -> Prepared {
        let directory = try cachesSubdirectory("images")
        let url = directory.appendingPathComponent("\(key).\(cleaned.fileExtension)")
        do {
            try? FileManager.default.removeItem(at: url)
            try cleaned.data.write(to: url, options: [.atomic])
        } catch {
            throw PrepareError.unreadable
        }
        return try describeImage(fileURL: url, key: key, name: name)
    }

    /// The pieces of an image that is already in its cleaned form on disk (a first send, or the retry of a failed one): the
    /// dimensions, the preview and the thumbnail. The file itself is not touched. ImageIO decodes a small version of the picture, so
    /// a large one is never held in memory at full size for this.
    static func describeImage(fileURL: URL, key: String, name: String? = nil) throws -> Prepared {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let info = FileV2ImageCleaner.readInfo(of: source) else { throw PrepareError.undecodable }
        let format = FileV2ImageCleaner.format(ofCopyAt: fileURL)
        let media = FileV2MediaHints.media(width: info.displayWidth, height: info.displayHeight)
        var thumbnailURL: URL?
        var preview: Data?
        if let small = FileV2ImageCleaner.decodedImage(of: source, maxSide: FileV2ThumbnailPlan.thumbnailMaxSide) {
            let image = UIImage(cgImage: small)
            let thumbnail = jpeg(of: image, maxSide: FileV2ThumbnailPlan.thumbnailMaxSide, quality: 0.7)
            thumbnailURL = thumbnail.flatMap { writeThumbnail($0, key: key) }
            preview = tinyPreview(of: image)
        }
        return Prepared(
            kind: .image, sourceURL: fileURL, name: name ?? imageName(format), mimeType: format.mimeType, media: media,
            preview: preview, thumbnailURL: thumbnailURL, durationMs: nil)
    }

    private static func imageName(_ format: PictureFormat) -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        return "IMG-\(stamp).\(format.fileExtension)"
    }

    // MARK: A voice note

    /// A recorded voice note, copied from the temporary directory to `Caches/voicenotes/<key>.m4a` (the system reclaims the temporary
    /// directory, and the sender replays his own bubble after a restart).
    static func prepareVoice(recording: VoiceNoteRecorder.Recording, key: String) throws -> Prepared {
        let directory = try cachesSubdirectory("voicenotes")
        let url = directory.appendingPathComponent("\(key).m4a")
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: recording.fileURL, to: url)
        } catch {
            throw PrepareError.unreadable
        }
        return describeVoice(fileURL: url, durationMs: Int64(recording.durationMs), mimeType: recording.mimeType)
    }

    /// A voice note that is already in the caches directory (the retry of a failed send): its duration and its waveform (at most 64
    /// peaks in percent, the convention of the three apps).
    static func describeVoice(fileURL: URL, durationMs: Int64, mimeType: String) -> Prepared {
        Prepared(kind: .voice, sourceURL: fileURL, name: "voicenote-\(Int(Date().timeIntervalSince1970)).m4a",
                 mimeType: mimeType.isEmpty ? "audio/mp4" : mimeType,
                 media: FileV2MediaHints.media(durationMs: durationMs, wave: waveform(of: fileURL)),
                 preview: nil, thumbnailURL: nil, durationMs: durationMs)
    }

    /// The peak of each slice of the recording in percent, read by decoding the audio in pieces (the memory does not depend on its
    /// length); `nil` when the file cannot be decoded or is too long to be worth the time (the descriptor then has no waveform,
    /// which is valid).
    static func waveform(of url: URL) -> [Int]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let total = file.length
        guard total > 0, total <= 50_000_000 else { return nil }
        let format = file.processingFormat
        let pieceFrames: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: pieceFrames) else { return nil }
        var peaks = FileV2WavePeaks(totalFrames: total)
        var position: Int64 = 0
        while position < total {
            do {
                try file.read(into: buffer, frameCount: pieceFrames)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            var amplitudes = [Float](repeating: 0, count: frames)
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for index in 0..<frames {
                    let value = abs(samples[index])
                    if value > amplitudes[index] { amplitudes[index] = value }
                }
            }
            peaks.add(amplitudes, startingAtFrame: position)
            position += Int64(frames)
        }
        return peaks.percentages
    }

    // MARK: A video

    /// A video the user picked (a file the picker handed over, or one the app copied): its duration and dimensions, and a frame as
    /// the thumbnail. The file is moved to `Caches/files_v2/<key>/out/` so that it stays until it is sent (and played by the sender).
    static func prepareVideo(sourceURL: URL, key: String) async throws -> Prepared {
        let directory = FileV2LocalFiles.directory(base: FileV2DownloadCenter.cachesBase, rowKey: key)
            .appendingPathComponent("out", isDirectory: true)
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("video." + ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: sourceURL, to: destination)
        } catch {
            throw PrepareError.unreadable
        }
        return try await describeVideo(fileURL: destination, key: key)
    }

    /// The pieces of a video that is already where it stays (a first send after the move, or the retry of a failed one).
    static func describeVideo(fileURL: URL, key: String) async throws -> Prepared {
        let asset = AVURLAsset(url: fileURL)
        var durationMs: Int64?
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 { durationMs = Int64((seconds * 1000).rounded()) }
        }
        var width: Int?
        var height: Int?
        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
           let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            width = Int(abs(rect.width).rounded())
            height = Int(abs(rect.height).rounded())
        }
        var thumbnailURL: URL?
        var preview: Data?
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: FileV2ThumbnailPlan.thumbnailMaxSide, height: FileV2ThumbnailPlan.thumbnailMaxSide)
        if let frame = try? await generator.image(at: .zero).image {
            let image = UIImage(cgImage: frame)
            if width == nil || height == nil {
                width = Int(image.size.width.rounded())
                height = Int(image.size.height.rounded())
            }
            if let data = image.jpegData(compressionQuality: 0.7).flatMap(scrubbed) { thumbnailURL = writeThumbnail(data, key: key) }
            preview = tinyPreview(of: image)
        }
        let mime = FileV2AppServices.mimeType(for: fileURL)
        return Prepared(
            kind: .video, sourceURL: fileURL, name: videoName(fileURL), mimeType: mime == "application/octet-stream" ? "video/quicktime" : mime,
            media: FileV2MediaHints.media(width: width, height: height, durationMs: durationMs), preview: preview,
            thumbnailURL: thumbnailURL, durationMs: durationMs)
    }

    private static func videoName(_ url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        return "VID-\(Int(Date().timeIntervalSince1970)).\(ext)"
    }

    // MARK: Pictures

    /// A JPEG this code made from pixels (a thumbnail, the tiny preview) goes through the stripper too: nothing leaves the device
    /// unchecked. What the stripper cannot read is dropped (these pictures are cosmetic), never sent as it is.
    private static func scrubbed(_ jpeg: Data) -> Data? {
        try? ImageMetadataStripper.strip(jpeg).data
    }

    /// `image` scaled to fit a square of `maxSide` pixels (never enlarged), encoded as JPEG and cleaned.
    private static func jpeg(of image: UIImage, maxSide: Int, quality: CGFloat) -> Data? {
        guard let fit = FileV2ThumbnailPlan.fitted(width: Double(image.size.width), height: Double(image.size.height),
                                                   maxSide: maxSide) else { return nil }
        let target = CGSize(width: fit.width, height: fit.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return drawn.jpegData(compressionQuality: quality).flatMap(scrubbed)
    }

    /// The tiny preview of a descriptor (`pv`): a JPEG of a few hundred bytes, never more than 2048. `nil` if even the smallest
    /// attempt does not fit.
    private static func tinyPreview(of image: UIImage) -> Data? {
        let attempts: [(side: Int, quality: CGFloat)] = [
            (FileV2ThumbnailPlan.previewMaxSide, 0.5), (24, 0.4), (16, 0.3)
        ]
        for attempt in attempts {
            if let data = jpeg(of: image, maxSide: attempt.side, quality: attempt.quality),
               data.count <= FileV2.maxPreviewBytes {
                return data
            }
        }
        return nil
    }

    /// `Caches/files_v2/<key>/thumb/thumb.jpg`: where the bubble of the row looks for its thumbnail, and where the sender uploads it from.
    private static func writeThumbnail(_ data: Data, key: String) -> URL? {
        let url = FileV2LocalFiles.thumbnailURL(base: FileV2DownloadCenter.cachesBase, rowKey: key)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private static func cachesSubdirectory(_ name: String) throws -> URL {
        do {
            let directory = FileV2DownloadCenter.cachesBase.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            throw PrepareError.unreadable
        }
    }
}

extension FileV2MediaPreparer.PrepareError {
    /// How a picture that was refused is told when it was sent as a file (the failure text of `FileV2FailureText`). A photo of the chat
    /// that fails is told by the snackbars of the screens, which count the photos of a batch.
    var failure: FileV2Failure {
        switch self {
        case .undecodable, .notCleanable: return FileV2Failure(.imageNotCleanable)
        case .tooLarge: return FileV2Failure(.fileTooLarge)
        case .unreadable: return FileV2Failure(.unreadable)
        }
    }

    /// Telemetry string: no identifier, no name, no path.
    var code: String {
        switch self {
        case .undecodable: return "undecodable"
        case .tooLarge: return "too_large"
        case .unreadable: return "unreadable"
        case .notCleanable: return "image_not_cleanable"
        }
    }
}
