import Foundation
import ImageIO
import UniformTypeIdentifiers
import QAudionEngine

/// A picture that is ready to be sealed and uploaded: a COPY of what the user picked or shot, with no location, no device
/// identifier and no time in it. The original is never what leaves the device.
struct FileV2CleanImage {
    let data: Data
    let format: PictureFormat

    var mimeType: String { format.mimeType }
    var fileExtension: String { format.fileExtension }
}

extension PictureFormat {
    var mimeType: String {
        switch self {
        case .jpeg: return "image/jpeg"
        case .png: return "image/png"
        case .webp: return "image/webp"
        case .gif: return "image/gif"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .webp: return "webp"
        case .gif: return "gif"
        }
    }
}

/// Makes the cleaned copy of a picture (the owner's rule, the same on Android, iOS and Desktop): EXIF, XMP, IPTC and GPS data never
/// leave the device, and the only thing kept is the orientation, so the picture still shows upright. If cleaning fails, or the format
/// is not understood, the picture is NOT sent in its original form: `CleanError.notCleanable`.
///
/// 1. JPEG, PNG, WEBP and GIF are copied by the engine's `ImageMetadataStripper` WITHOUT decoding the pixels (no loss, same colours,
///    an animated GIF stays animated); the Orientation is the only tag that stays. This is used as long as the result is within the
///    limits of the `Policy`.
/// 2. Everything else (HEIC, AVIF, TIFF, RAW...), a picture of those four formats that is damaged or above the limits, is decoded and
///    encoded again through ImageIO: the Orientation is applied to the pixels, and the new file has no metadata because nothing but
///    the pixels (and their colour space) is handed to the encoder. JPEG, or PNG when the picture has transparency.
/// 3. If that is not possible either (SVG, a file that is not a picture), `CleanError.notCleanable`.
///
/// Pure functions of the bytes they are given: nothing here reads a file, prints a name or a path, or touches the network.
enum FileV2ImageCleaner {

    /// What a picture must satisfy to be sent as it is (after its metadata was removed), else it is re-encoded.
    enum Policy {
        /// A photo of the chat (library, camera, clipboard): the limits the chat has always had, 2048 px on the long side and 10 MB.
        case chatPhoto
        /// A picture picked as a file: kept at its size.
        case pickedFile

        var maxSide: Int? {
            switch self {
            case .chatPhoto: return FileV2MediaPreparer.maxImageSide
            case .pickedFile: return nil
            }
        }

        var maxBytes: Int? {
            switch self {
            case .chatPhoto: return FileV2MediaPreparer.maxImageBytes
            case .pickedFile: return nil
            }
        }

        /// The longest side of a re-encoded picture: a picture above it is scaled down (a decode is never above 16 MP for a file).
        var reencodeMaxSide: Int {
            switch self {
            case .chatPhoto: return FileV2MediaPreparer.maxImageSide
            case .pickedFile: return 4096
            }
        }

        var jpegQuality: Double {
            switch self {
            case .chatPhoto: return 0.85
            case .pickedFile: return 0.92
            }
        }
    }

    enum CleanError: Error {
        /// The metadata cannot be removed (format not understood, file damaged, not a picture): nothing is sent.
        case notCleanable
        /// Even re-encoded, the picture is above the cap of the policy.
        case tooLarge
    }

    /// The most a picture may weigh to be cleaned by copying it in memory (the input, the output and a copy of it are alive together);
    /// above it the picture is re-encoded, which streams.
    static let maxStrippedInputBytes = 64 * 1024 * 1024

    /// The cleaned copy of `input`.
    static func clean(_ input: Data, policy: Policy) throws -> FileV2CleanImage {
        guard !input.isEmpty else { throw CleanError.notCleanable }
        if input.count <= maxStrippedInputBytes, let stripped = try? ImageMetadataStripper.strip(input),
           isWithinLimits(stripped.data, policy: policy) {
            return FileV2CleanImage(data: stripped.data, format: stripped.format)
        }
        return try reencode(input, policy: policy)
    }

    // MARK: What ImageIO says about a picture

    struct Info {
        let width: Int
        let height: Int
        /// The EXIF orientation, 1...8 (1 when the picture says nothing).
        let orientation: Int
        let hasAlpha: Bool

        /// The size as it is shown: turned by a quarter when the orientation says so.
        var displayWidth: Int { (5...8).contains(orientation) ? height : width }
        var displayHeight: Int { (5...8).contains(orientation) ? width : height }
    }

    /// The size, the orientation and the transparency of the first picture of `source`, read from its header (the pixels are not
    /// decoded); `nil` when ImageIO cannot read it.
    static func readInfo(of source: CGImageSource) -> Info? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        return Info(width: width, height: height, orientation: (1...8).contains(orientation) ? orientation : 1, hasAlpha: hasAlpha)
    }

    /// The first picture of `source` with its orientation applied, scaled down to `maxSide` on the long side when it is larger (a
    /// subsampled decode: a large picture is never held in memory at full size just to make a small one). A picture that is not larger
    /// is never enlarged.
    static func decodedImage(of source: CGImageSource, maxSide: Int) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let info = readInfo(of: source), max(info.width, info.height) > maxSide {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxSide
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func isWithinLimits(_ data: Data, policy: Policy) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let info = readInfo(of: source) else { return false }
        if let maxBytes = policy.maxBytes, data.count > maxBytes { return false }
        if let maxSide = policy.maxSide, max(info.width, info.height) > maxSide { return false }
        return true
    }

    // MARK: Re-encoding

    private static func reencode(_ input: Data, policy: Policy) throws -> FileV2CleanImage {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil), let info = readInfo(of: source) else {
            throw CleanError.notCleanable
        }
        guard let image = decodedImage(of: source, maxSide: policy.reencodeMaxSide) else { throw CleanError.notCleanable }
        let type: UTType = info.hasAlpha ? .png : .jpeg
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw CleanError.notCleanable
        }
        // Nothing but the pixels goes to the encoder: no properties of the source, no metadata dictionaries.
        var options: [CFString: Any] = [:]
        if !info.hasAlpha { options[kCGImageDestinationLossyCompressionQuality] = policy.jpegQuality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CleanError.notCleanable }
        let bytes = encoded as Data
        // The encoder's file goes through the stripper too: whatever small blocks it writes of its own are gone as well.
        let result: FileV2CleanImage
        if let stripped = try? ImageMetadataStripper.strip(bytes) {
            result = FileV2CleanImage(data: stripped.data, format: stripped.format)
        } else {
            result = FileV2CleanImage(data: bytes, format: info.hasAlpha ? .png : .jpeg)
        }
        guard !result.data.isEmpty else { throw CleanError.notCleanable }
        if let maxBytes = policy.maxBytes, result.data.count > maxBytes { throw CleanError.tooLarge }
        return result
    }

    // MARK: Pictures picked as files

    /// Whether the file at `url` is a picture: its name says so (any type that conforms to `public.image`), or its first bytes do (a
    /// file without an extension, or with a wrong one). The caller holds the security-scoped access to `url`.
    static func isPicture(at url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        return ImageMetadataStripper.looksLikePicture(head)
    }

    /// The name a cleaned copy of the picture called `picked` is sent under: the picked name, with the extension of the format of
    /// the copy (a HEIC that became a JPEG is "name.jpg").
    static func name(for picked: String, format: PictureFormat) -> String {
        let stem = (picked as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "IMG" : stem) + "." + format.fileExtension
    }

    /// The format of a cleaned copy this app wrote (its extension is the one `PictureFormat.fileExtension` gives).
    static func format(ofCopyAt url: URL) -> PictureFormat {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "webp": return .webp
        case "gif": return .gif
        default: return .jpeg
        }
    }
}
