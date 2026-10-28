import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The imported ringtone: choosing the excerpt, what happens when the import fails, and the conversion to the
/// CAF file CallKit can play (at most 30 s, in `Library/Sounds`).
public enum CustomRingtone {

    /// A slice of the source: where it starts and how long it is.
    public struct Excerpt: Equatable, Sendable {
        public let start: Double
        public let duration: Double
    }

    /// The latest start that still leaves a full excerpt (0 when the source is not longer than the limit).
    public static func maxStart(sourceSeconds: Double, limit: Double = CallSoundCatalog.maxRingtoneSeconds) -> Double {
        guard sourceSeconds.isFinite else { return 0 }
        return max(0, sourceSeconds - limit)
    }

    /// The excerpt for a requested start: clamped into the source, never longer than the limit.
    public static func excerpt(sourceSeconds: Double, requestedStart: Double,
                               limit: Double = CallSoundCatalog.maxRingtoneSeconds) -> Excerpt {
        guard sourceSeconds.isFinite, sourceSeconds > 0 else { return Excerpt(start: 0, duration: 0) }
        let requested = requestedStart.isFinite ? requestedStart : 0
        let start = min(max(0, requested), maxStart(sourceSeconds: sourceSeconds, limit: limit))
        return Excerpt(start: start, duration: min(limit, sourceSeconds - start))
    }

    /// Largest source file that is copied and converted.
    public static let maxSourceBytes: Int = 200 * 1024 * 1024

    /// Whether a source of `bytes` may be imported.
    public static func sourceSizeAllowed(_ bytes: Int) -> Bool { bytes > 0 && bytes <= maxSourceBytes }

    public enum ImportError: String, Error, Equatable, Sendable {
        /// Copy-protected audio (for example an Apple Music download): it cannot be decoded.
        case protectedContent
        /// The file holds no audio, or it cannot be opened or decoded.
        case unreadable
        /// The result would be too short to be a ringtone.
        case tooShort
        /// The source is larger than `maxSourceBytes`.
        case tooLarge
        case writeFailed
    }

    /// A note the settings screen shows to explain a fallback.
    public enum Notice: String, Equatable, Sendable {
        case protectedContent
        case conversionFailed
        /// The import failed and the ringtone that worked before is still in use.
        case keptPrevious
        /// The imported file is gone (for example the app data was restored without it).
        case customUnavailable
    }

    public struct ImportedFile: Equatable, Sendable {
        public let displayName: String
        public let startSeconds: Double
        public init(displayName: String, startSeconds: Double) {
            self.displayName = displayName
            self.startSeconds = startSeconds
        }
    }

    /// The ringtone choice after an import or a check, with the note to show, if any.
    public struct Selection: Equatable, Sendable {
        public let ringtoneId: String
        public let settings: CallSoundSettings
        public let notice: Notice?
    }

    /// Applies the outcome of an import: success selects the imported file. A failure keeps the previous imported
    /// ringtone when `previousCustomUsable` (its file is still there): nothing changes but the note. Otherwise it
    /// falls back to the default ringtone, forgets the imported file and carries the note to show.
    public static func applyImport(_ outcome: Result<ImportedFile, ImportError>, settings: CallSoundSettings,
                                   ringtoneId: String, previousCustomUsable: Bool = false) -> Selection {
        var next = settings
        switch outcome {
        case .success(let file):
            next.customFileName = CallSoundCatalog.customFileName
            next.customDisplayName = file.displayName
            next.customStartSeconds = file.startSeconds
            return Selection(ringtoneId: CallSoundCatalog.customId, settings: next, notice: nil)
        case .failure(let error):
            if previousCustomUsable, settings.customFileName != nil {
                return Selection(ringtoneId: ringtoneId, settings: settings, notice: .keptPrevious)
            }
            next.customFileName = nil
            next.customDisplayName = nil
            next.customStartSeconds = 0
            let notice: Notice = error == .protectedContent ? .protectedContent : .conversionFailed
            return Selection(ringtoneId: CallSoundCatalog.defaultRingtoneId, settings: next, notice: notice)
        }
    }

    /// Checks a stored choice against the files on disk: "custom" without its file becomes the default.
    public static func reconcile(ringtoneId: String, settings: CallSoundSettings, customFileExists: Bool) -> Selection {
        guard ringtoneId == CallSoundCatalog.customId, !customFileExists else {
            return Selection(ringtoneId: ringtoneId, settings: settings, notice: nil)
        }
        var next = settings
        next.customFileName = nil
        next.customDisplayName = nil
        next.customStartSeconds = 0
        return Selection(ringtoneId: CallSoundCatalog.defaultRingtoneId, settings: next, notice: .customUnavailable)
    }

    // MARK: - Files

    /// `Library/Sounds` of the app container.
    public static func soundsDirectory() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Sounds", isDirectory: true)
    }

    public static func customFileURL() -> URL? {
        soundsDirectory()?.appendingPathComponent(CallSoundCatalog.customFileName)
    }

    /// True when the imported ringtone exists and is not empty.
    public static func customFileExists() -> Bool {
        guard let url = customFileURL(),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    /// The ringtone in force: the stored choice resolved against the files on disk.
    public static func currentResolution(store: SettingsStore = SettingsStore()) -> CallSoundCatalog.Resolution {
        CallSoundCatalog.resolve(ringtoneId: store.loadNotifications().ringtoneId, customAvailable: customFileExists())
    }
}

#if canImport(AVFoundation)
/// Converts any audio file AVFoundation can decode (mp3, m4a/aac, wav, aiff, caf) into the ringtone file:
/// mono 16-bit linear PCM CAF at 32 kHz, at most 30 s, with a short fade at both ends. Linear PCM is one of the
/// formats CallKit accepts for `ringtoneSound`, and writing it needs no encoder.
public enum CustomRingtoneConverter {

    public static let outputSampleRate: Double = 32_000
    private static let minimumSeconds: Double = 0.5

    /// Duration of the source in seconds. Throws `protectedContent` for copy-protected audio and `unreadable` for
    /// anything that cannot be decoded.
    public static func sourceDuration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        if let protected = try? await asset.load(.hasProtectedContent), protected {
            throw CustomRingtone.ImportError.protectedContent
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            guard rate > 0, file.length > 0 else { throw CustomRingtone.ImportError.unreadable }
            return Double(file.length) / rate
        } catch {
            throw CustomRingtone.ImportError.unreadable
        }
    }

    /// Converts the excerpt starting at `startSeconds` (clamped) of `source` into `destination`. Returns the duration
    /// written. The destination is replaced atomically: a failure leaves the previous file untouched.
    public static func convert(source: URL, startSeconds: Double, destination: URL) async throws -> Double {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try convertSync(source: source, startSeconds: startSeconds, destination: destination))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func convertSync(source: URL, startSeconds: Double, destination: URL) throws -> Double {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw CustomRingtone.ImportError.unreadable }
        let inFormat = input.processingFormat
        guard inFormat.sampleRate > 0, input.length > 0 else { throw CustomRingtone.ImportError.unreadable }
        let sourceSeconds = Double(input.length) / inFormat.sampleRate
        let excerpt = CustomRingtone.excerpt(sourceSeconds: sourceSeconds, requestedStart: startSeconds)
        guard excerpt.duration >= minimumSeconds else { throw CustomRingtone.ImportError.tooShort }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(inFormat.sampleRate / 2)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8_192)
        else { throw CustomRingtone.ImportError.unreadable }

        let fm = FileManager.default
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".converting-\(UUID().uuidString).caf")
        // The system reads this folder when a call rings with the phone locked: readable after the first unlock.
        guard FileProtection.prepareDirectory(destination.deletingLastPathComponent()) else { throw CustomRingtone.ImportError.writeFailed }
        defer { try? fm.removeItem(at: temp) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        var outputFile: AVAudioFile?
        do { outputFile = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw CustomRingtone.ImportError.writeFailed }
        guard outputFile != nil else { throw CustomRingtone.ImportError.writeFailed }

        let startFrame = AVAudioFramePosition(excerpt.start * inFormat.sampleRate)
        let endFrame = min(input.length, startFrame + AVAudioFramePosition(excerpt.duration * inFormat.sampleRate))
        input.framePosition = startFrame

        let totalOut = Int(excerpt.duration * outputSampleRate)
        let fadeIn = Int(0.003 * outputSampleRate)
        let fadeOut = Int(0.05 * outputSampleRate)
        var written = 0
        var readFailed = false

        while written < totalOut {
            outBuffer.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, inStatus in
                let remaining = endFrame - input.framePosition
                guard remaining > 0, !readFailed else {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                let n = AVAudioFrameCount(min(AVAudioFramePosition(inBuffer.frameCapacity), remaining))
                do { try input.read(into: inBuffer, frameCount: n) } catch {
                    readFailed = true
                    inStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                inStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error || readFailed { throw CustomRingtone.ImportError.unreadable }
            var frames = Int(outBuffer.frameLength)
            if frames > 0 {
                frames = min(frames, totalOut - written)
                outBuffer.frameLength = AVAudioFrameCount(frames)
                if let ch = outBuffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        let g = written + i
                        var gain: Float = 1
                        if g < fadeIn { gain = Float(g) / Float(max(1, fadeIn)) }
                        let tail = totalOut - g
                        if tail < fadeOut { gain = min(gain, Float(tail) / Float(max(1, fadeOut))) }
                        ch[i] *= gain
                    }
                }
                do { try outputFile?.write(from: outBuffer) } catch { throw CustomRingtone.ImportError.writeFailed }
                written += frames
            }
            if status == .endOfStream || frames == 0 { break }
        }

        let seconds = Double(written) / outputSampleRate
        guard seconds >= minimumSeconds else { throw CustomRingtone.ImportError.tooShort }
        // The writer is released first: the file is finalized when it goes away.
        outputFile = nil
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch { throw CustomRingtone.ImportError.writeFailed }
        FileProtection.apply(to: destination)
        return seconds
    }
}
#endif
