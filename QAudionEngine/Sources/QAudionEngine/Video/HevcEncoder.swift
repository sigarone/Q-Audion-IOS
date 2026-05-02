import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware HEVC (H.265) encoder for iOS. Wraps VTCompressionSession.
/// Output NAL units are pushed to a delegate which (in production)
/// forwards them into [VideoFrameFragmenter] for the BcryptoWsRelay
/// path or directly into a [RTCVideoSource] for the WebRTC SRTP path.
///
/// Mirrors Android's `HevcHwVideoEncoder.kt` (MediaCodec path) at the
/// API boundary: caller pushes pixel buffers, callback delivers NALs.
///
/// **Cross-platform contract:**
/// - Same target keyframe interval (KEYFRAME_INTERVAL_SEC = 2 from
///   VideoConstants).
/// - Same default bitrate (DEFAULT_VIDEO_BITRATE_BPS = 800 kbps).
/// - HEVC Annex-B NAL formatting (start-code 0x00000001 prefix) so the
///   peer's decoder can ingest without reformat.
/// - Hardware-accelerated when available (VideoToolbox decides; the
///   constructor passes `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder`).
public final class HevcEncoder: @unchecked Sendable {

    public typealias NalCallback = (Data, Bool) -> Void  // (annexBNalUnit, isKeyFrame)

    public enum EncoderError: Error, Equatable {
        case sessionCreateFailed(OSStatus)
        case sessionPropertyFailed(OSStatus)
        case prepareFailed(OSStatus)
        case encodeFailed(OSStatus)
        case sessionNotInitialised
    }

    public let width: Int
    public let height: Int
    public let bitrateBps: Int
    public let fps: Int
    /// Keyframe interval in seconds.
    public let keyframeIntervalSec: Int

    private var session: VTCompressionSession?
    public var onNal: NalCallback?

    private let lock = NSLock()
    private var frameIndex: Int64 = 0

    public init(
        width: Int = VideoConstants.defaultVideoWidth,
        height: Int = VideoConstants.defaultVideoHeight,
        bitrateBps: Int = VideoConstants.defaultVideoBitrateBps,
        fps: Int = VideoConstants.defaultVideoFps,
        keyframeIntervalSec: Int = VideoConstants.keyframeIntervalSec
    ) {
        self.width = width
        self.height = height
        self.bitrateBps = bitrateBps
        self.fps = fps
        self.keyframeIntervalSec = keyframeIntervalSec
    }

    deinit {
        invalidate()
    }

    // MARK: - Lifecycle

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        if session != nil { return }
        var newSession: VTCompressionSession?
        // W360: kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder
        // is iOS 17.4+ only. Our deployment target is iOS 16 so we
        // build an empty encoder-spec there and let VideoToolbox pick
        // the default encoder (HEVC HW is the default on every supported
        // iPhone running iOS 16+ anyway, so we don't lose the HW path).
        let encoderSpec: CFDictionary
        if #available(iOS 17.4, *) {
            encoderSpec = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ] as CFDictionary
        } else {
            encoderSpec = [String: Any]() as CFDictionary
        }
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: HevcEncoder.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let session = newSession else {
            throw EncoderError.sessionCreateFailed(status)
        }

        try setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue!)
        try setProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        try setProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrateBps))
        try setProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        try setProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                         value: NSNumber(value: keyframeIntervalSec))
        try setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse!)

        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepStatus != noErr {
            throw EncoderError.prepareFailed(prepStatus)
        }
        self.session = session
    }

    public func invalidate() {
        lock.lock()
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        lock.unlock()
    }

    // MARK: - Encode

    /// Encode one frame. The caller supplies a CVPixelBuffer at the
    /// configured `width`x`height`. Output NAL units are delivered
    /// asynchronously via `onNal`.
    public func encode(pixelBuffer: CVPixelBuffer, presentationTimeNs: UInt64? = nil) throws {
        lock.lock()
        guard let session = session else {
            lock.unlock(); throw EncoderError.sessionNotInitialised
        }
        let pts: CMTime
        if let ns = presentationTimeNs {
            pts = CMTime(value: CMTimeValue(ns / 1_000_000), timescale: 1000)
        } else {
            // Default: monotonic frame counter at fps cadence.
            pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        }
        frameIndex += 1
        lock.unlock()

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        if status != noErr {
            throw EncoderError.encodeFailed(status)
        }
    }

    /// Flush any queued frames and emit them through `onNal`.
    public func flush() {
        lock.lock()
        let session = self.session
        lock.unlock()
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
    }

    // MARK: - Property helper

    private func setProperty(_ session: VTCompressionSession, key: CFString, value: AnyObject) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            throw EncoderError.sessionPropertyFailed(status)
        }
    }

    // MARK: - VideoToolbox callback

    private static let outputCallback: VTCompressionOutputCallback = {
        outputCallbackRefCon, _, status, _, sampleBuffer in
        guard status == noErr, let buffer = sampleBuffer, CMSampleBufferDataIsReady(buffer) else {
            return
        }
        guard let refcon = outputCallbackRefCon else { return }
        let me = Unmanaged<HevcEncoder>.fromOpaque(refcon).takeUnretainedValue()
        me.handleOutput(sampleBuffer: buffer)
    }

    private func handleOutput(sampleBuffer: CMSampleBuffer) {
        guard let cb = onNal else { return }

        // Determine if this is a key frame by inspecting the sync attachment.
        let isKeyFrame: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            // NotSync == false means it IS a sync (key) frame.
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKeyFrame = !notSync
        } else {
            isKeyFrame = false
        }

        // For a key frame, prepend the parameter sets (VPS/SPS/PPS) so the
        // peer's decoder can bootstrap. Subsequent frames carry the slice
        // NAL only.
        if isKeyFrame, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            emitParameterSets(formatDesc: formatDesc)
        }

        // Extract slice NAL(s) from the data buffer. iOS emits AVCC-style
        // length-prefixed NAL units; we convert each one to Annex-B by
        // replacing the 4-byte length prefix with the start-code 0x00000001.
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLen, dataPointerOut: &dataPtr)
        guard status == noErr, let ptr = dataPtr else { return }

        var offset = 0
        while offset < totalLen - 4 {
            // Read 4-byte length (BE).
            var nalLen32: UInt32 = 0
            memcpy(&nalLen32, ptr.advanced(by: offset), 4)
            let nalLen = Int(UInt32(bigEndian: nalLen32))
            guard offset + 4 + nalLen <= totalLen else { break }

            var nal = Data(count: 4 + nalLen)
            nal.withUnsafeMutableBytes { dst -> Void in
                guard let dstBase = dst.baseAddress else { return }
                // Annex-B start code.
                dstBase.assumingMemoryBound(to: UInt8.self)[0] = 0x00
                dstBase.assumingMemoryBound(to: UInt8.self)[1] = 0x00
                dstBase.assumingMemoryBound(to: UInt8.self)[2] = 0x00
                dstBase.assumingMemoryBound(to: UInt8.self)[3] = 0x01
                // Copy NAL payload.
                memcpy(dstBase.advanced(by: 4),
                        ptr.advanced(by: offset + 4),
                        nalLen)
            }
            cb(nal, isKeyFrame)
            offset += 4 + nalLen
        }
    }

    private func emitParameterSets(formatDesc: CMFormatDescription) {
        guard let cb = onNal else { return }
        var paramCount: Int = 0
        // First call: just get the count.
        _ = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil)
        for i in 0..<paramCount {
            var setPtr: UnsafePointer<UInt8>?
            var setSize = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &setPtr,
                parameterSetSizeOut: &setSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil)
            guard status == noErr, let setPtr = setPtr, setSize > 0 else { continue }
            var nal = Data(capacity: 4 + setSize)
            nal.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nal.append(setPtr, count: setSize)
            cb(nal, true)
        }
    }
}
