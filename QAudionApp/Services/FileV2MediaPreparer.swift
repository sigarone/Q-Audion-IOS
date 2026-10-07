import Foundation
import UIKit
import AVFoundation
import QAudionEngine

/// Makes ready what the v2 sender needs to send an image, a voice note or a video: the file to upload (which the sender's own bubble
/// also shows), the display hints (`m`), the tiny preview (`pv`) and the thumbnail (a small JPEG that becomes a v2 file of its own).
/// UIKit and AVFoundation do the decoding and drawing here; the geometry and the limits are the engine's
/// (`FileV2ThumbnailPlan`, `FileV2MediaHints`), so they have tests.
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
    }

    /// The most an image weighs after it was downscaled and re-encoded (the cap the chat always had).
    static let maxImageBytes = 10 * 1024 * 1024
    /// The longest side of an image that is sent, in pixels.
    static let maxImageSide = 2048

    // MARK: An image

    /// An image of any format the device decodes, normalised the way the chat always did (re-encoded as JPEG, which drops the EXIF:
    /// geolocation, device serial, dates; downscaled to 2048 px on the long side) and saved in `Caches/images/<key>.jpg`.
    static func prepareImage(rawData: Data, key: String) throws -> Prepared {
        guard let image = UIImage(data: rawData), let normalised = normalised(image) else { throw PrepareError.undecodable }
        guard normalised.count <= maxImageBytes else { throw PrepareError.tooLarge }
        let directory = try cachesSubdirectory("images")
        let url = directory.appendingPathComponent("\(key).jpg")
        do {
            try? FileManager.default.removeItem(at: url)
            try normalised.write(to: url, options: [.atomic])
        } catch {
            throw PrepareError.unreadable
        }
        return try describeImage(fileURL: url, key: key)
    }

    /// The pieces of an image that is already in its normalised form on disk (a first send, or the retry of a failed one): the
    /// dimensions, the preview and the thumbnail. The file itself is not re-encoded.
    static func describeImage(fileURL: URL, key: String) throws -> Prepared {
        guard let image = UIImage(contentsOfFile: fileURL.path) else { throw PrepareError.undecodable }
        let media = FileV2MediaHints.media(width: Int(image.size.width.rounded()), height: Int(image.size.height.rounded()))
        let thumbnail = jpeg(of: image, maxSide: FileV2ThumbnailPlan.thumbnailMaxSide, quality: 0.7)
        return Prepared(
            kind: .image, sourceURL: fileURL, name: imageName(), mimeType: "image/jpeg", media: media,
            preview: tinyPreview(of: image), thumbnailURL: thumbnail.flatMap { writeThumbnail($0, key: key) }, durationMs: nil)
    }

    private static func normalised(_ image: UIImage) -> Data? {
        let original = image.size
        guard original.width.isFinite, original.height.isFinite, original.width > 0, original.height > 0 else { return nil }
        let longest = max(original.width, original.height)
        let scale: CGFloat = longest > CGFloat(maxImageSide) ? CGFloat(maxImageSide) / longest : 1.0
        let target = CGSize(width: max(1, floor(original.width * scale)), height: max(1, floor(original.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return drawn.jpegData(compressionQuality: 0.85)
    }

    private static func imageName() -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        return "IMG-\(stamp).jpg"
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

    /// A voice note that is already in the caches directory (the retry of a failed send).
    static func describeVoice(fileURL: URL, durationMs: Int64, mimeType: String) -> Prepared {
        Prepared(kind: .voice, sourceURL: fileURL, name: "voicenote-\(Int(Date().timeIntervalSince1970)).m4a",
                 mimeType: mimeType.isEmpty ? "audio/mp4" : mimeType,
                 media: FileV2MediaHints.media(durationMs: durationMs), preview: nil, thumbnailURL: nil, durationMs: durationMs)
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
            if let data = image.jpegData(compressionQuality: 0.7) { thumbnailURL = writeThumbnail(data, key: key) }
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

    /// `image` scaled to fit a square of `maxSide` pixels (never enlarged) and encoded as JPEG.
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
        return drawn.jpegData(compressionQuality: quality)
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
