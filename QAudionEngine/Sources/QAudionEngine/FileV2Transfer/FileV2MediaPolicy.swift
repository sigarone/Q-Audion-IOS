import Foundation

// The pure decisions of the media side of file transfer v2 (images, voice notes, videos, avatars): what is fetched on arrival,
// what a descriptor's display hints are worth, and how a thumbnail is sized. No I/O and no UIKit here, so each rule has a test;
// the app does the decoding and drawing.

/// What is downloaded without a tap (the owner's rule, WIRE_SPEC 12.9 leaves it to the client): avatars, thumbnails, voice notes
/// and images up to 25 MiB. A video, a document and anything above 25 MiB show a card with the name, the size and a download
/// action: the user decides, and the cellular data is not spent for a file nobody asked for.
public enum FileV2AutoDownloadPolicy {

    /// 25 MiB of plaintext (`sz` of the descriptor).
    public static let maxAutomaticBytes: UInt64 = 25 * 1024 * 1024

    /// An avatar is a picture of at most 512 x 512 pixels (a few hundred kilobytes): one that is DECLARED larger than 8 MiB is not an
    /// avatar and is discarded without being fetched (the convention shared by the three apps).
    public static let maxAvatarBytes: UInt64 = 8 * 1024 * 1024

    /// Whether a file of `kind` and `size` bytes is fetched on arrival.
    public static func isAutomatic(kind: FileV2Descriptor.Kind, size: UInt64) -> Bool {
        switch kind {
        case .avatar:
            return size <= maxAvatarBytes
        case .thumb, .voice, .image:
            return size <= maxAutomaticBytes
        case .file, .video:
            return false
        }
    }

    /// The thumbnail of an image or a video is always fetched on arrival: it is the preview of a card that is waiting for a tap (a
    /// video, a large image) or of an image that is still coming. A document shows no picture, so the thumbnail some sender may
    /// attach to one is not fetched. `kind` is the kind of the FILE the thumbnail belongs to.
    public static func fetchesThumbnail(of kind: FileV2Descriptor.Kind) -> Bool {
        switch kind {
        case .image, .video: return true
        case .file, .voice, .avatar, .thumb: return false
        }
    }
}

/// The display hints of a descriptor (`m`), as the user interface may use them. The format does not check their ranges (a
/// width may be negative or larger than 32 bits, a waveform may have a million samples): whatever the interface draws or
/// allocates from them goes through here first.
public struct FileV2MediaHints: Equatable, Sendable {
    /// Largest side an image or video may claim, in pixels.
    public static let maxDimension: Int64 = 16_384
    /// Longest duration shown, in milliseconds (24 hours).
    public static let maxDurationMs: Int64 = 24 * 60 * 60 * 1000
    /// Most waveform samples kept: the convention shared by the three apps is at most 64 integers.
    public static let maxWaveSamples = 64
    /// Largest value of a waveform sample: the peak amplitude of its slice, in percent of the full scale (0...100).
    public static let maxWaveValue = 100

    /// Both sides in pixels, or `nil` when either is missing or outside `1...maxDimension`.
    public let width: Int?
    public let height: Int?
    /// `0...maxDurationMs`; a negative duration is `nil`, a longer one is cut to `maxDurationMs`.
    public let durationMs: Int64?
    /// At most `maxWaveSamples` values, each `0...maxWaveValue`; empty when the descriptor had none.
    public let wave: [Int]

    /// The waveform as a drawing needs it: each sample as a fraction of the LOUDEST one (so a quiet note is drawn as tall as a loud
    /// one), `0...1`. Empty when there is no waveform or it is all zero (nothing to draw: the player draws its own bars).
    public var drawableWave: [Double] {
        guard let peak = wave.max(), peak > 0 else { return [] }
        return wave.map { Double($0) / Double(peak) }
    }

    public init(width: Int? = nil, height: Int? = nil, durationMs: Int64? = nil, wave: [Int] = []) {
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.wave = wave
    }

    /// The hints of a received descriptor's `m` (`nil` when it has none).
    public init(media: FileV2Descriptor.Media?) {
        guard let media else {
            self.init()
            return
        }
        var width: Int?
        var height: Int?
        if let w = media.w, let h = media.h, w >= 1, w <= Self.maxDimension, h >= 1, h <= Self.maxDimension {
            width = Int(w)
            height = Int(h)
        }
        var duration: Int64?
        if let dur = media.dur, dur >= 0 { duration = min(dur, Self.maxDurationMs) }
        let wave = (media.wave ?? []).prefix(Self.maxWaveSamples).map { Int(min(max($0, 0), Int64(Self.maxWaveValue))) }
        self.init(width: width, height: height, durationMs: duration, wave: Array(wave))
    }

    /// The `m` a sender writes. Nothing out of range is written: a side that is not positive is left out (both are), a negative
    /// duration is left out, a waveform is brought to at most `waveSamples` values of `0...maxWaveValue`. `nil` when nothing is
    /// left to say.
    public static func media(width: Int? = nil, height: Int? = nil, durationMs: Int64? = nil, wave: [Int]? = nil,
                             waveSamples: Int = FileV2MediaHints.maxWaveSamples) -> FileV2Descriptor.Media? {
        var media = FileV2Descriptor.Media()
        if let width, let height, width >= 1, height >= 1, Int64(width) <= maxDimension, Int64(height) <= maxDimension {
            media.w = Int64(width)
            media.h = Int64(height)
        }
        if let durationMs, durationMs >= 0 { media.dur = min(durationMs, maxDurationMs) }
        if let wave, !wave.isEmpty {
            media.wave = downsample(wave, to: min(max(1, waveSamples), maxWaveSamples)).map {
                Int64(min(max($0, 0), maxWaveValue))
            }
        }
        if media.w == nil && media.h == nil && media.dur == nil && media.wave == nil { return nil }
        return media
    }

    /// `values` brought to at most `count` samples: when there are more, each output sample is the largest value of its
    /// slice (the peak is what a waveform shows); when there are fewer or as many, they are returned as they are.
    public static func downsample(_ values: [Int], to count: Int) -> [Int] {
        guard count >= 1, values.count > count else { return values }
        var out: [Int] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let start = index * values.count / count
            let end = max(start + 1, (index + 1) * values.count / count)
            out.append(values[start..<min(end, values.count)].max() ?? 0)
        }
        return out
    }
}

/// The waveform of a voice note, as the peak of each slice of the recording in percent of the full scale: the app decodes the audio
/// and feeds the amplitude of every frame in order, and this keeps the largest one of each of `buckets` equal slices. The slices are
/// computed from the total number of frames, so a recording of any length gives the same number of samples.
public struct FileV2WavePeaks: Sendable {
    public let buckets: Int
    public let totalFrames: Int64
    private var peaks: [Float]

    /// `buckets` is limited to `1...FileV2MediaHints.maxWaveSamples`.
    public init(totalFrames: Int64, buckets: Int = FileV2MediaHints.maxWaveSamples) {
        self.totalFrames = max(0, totalFrames)
        self.buckets = min(max(1, buckets), FileV2MediaHints.maxWaveSamples)
        self.peaks = [Float](repeating: 0, count: self.buckets)
    }

    /// Adds the amplitudes (absolute values, `0...1`) of consecutive frames, the first one being frame number `startingAtFrame`. A
    /// frame past the end of the recording, a negative one, or an amplitude that is not a number is ignored.
    public mutating func add(_ amplitudes: [Float], startingAtFrame start: Int64) {
        guard totalFrames > 0 else { return }
        for (offset, amplitude) in amplitudes.enumerated() {
            let frame = start + Int64(offset)
            guard frame >= 0, frame < totalFrames, amplitude.isFinite else { continue }
            let bucket = min(buckets - 1, Int(frame * Int64(buckets) / totalFrames))
            let magnitude = min(1, abs(amplitude))
            if magnitude > peaks[bucket] { peaks[bucket] = magnitude }
        }
    }

    /// The peak of each slice in percent, `0...100`.
    public var percentages: [Int] {
        peaks.map { Int(($0 * 100).rounded()) }
    }
}

/// How a thumbnail and a tiny preview are sized. The thumbnail is a separate v2 file (`kind: thumb`, its own key) shown on the
/// card of an image or a video while the real file is not there; the preview (`pv`, at most 2048 decoded bytes) is inside the
/// descriptor and is what the card shows at once. The app draws and encodes; the geometry is here.
public enum FileV2ThumbnailPlan {
    /// Longest side of the thumbnail, in pixels.
    public static let thumbnailMaxSide = 320
    /// Longest side of the tiny preview, in pixels.
    public static let previewMaxSide = 32

    /// The size of an image of `width` x `height` points when it is fitted into a square of `maxSide`: the aspect ratio is kept,
    /// the image is never enlarged and each side is at least 1. `nil` when the source size is not a usable one (not finite, zero
    /// or negative) or `maxSide` is below 1.
    public static func fitted(width: Double, height: Double, maxSide: Int) -> (width: Int, height: Int)? {
        guard maxSide >= 1, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let longest = max(width, height)
        let scale = longest > Double(maxSide) ? Double(maxSide) / longest : 1.0
        let fittedWidth = max(1, Int((width * scale).rounded()))
        let fittedHeight = max(1, Int((height * scale).rounded()))
        return (min(fittedWidth, maxSide), min(fittedHeight, maxSide))
    }
}
