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

    // W524: these are no longer `let` so the ABR controller can adjust
    // bitrate / fps mid-stream and resolution stepping can recreate
    // the VTCompressionSession at a new size. All four still default
    // to VideoConstants.* in the initialiser.
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var bitrateBps: Int
    public private(set) var fps: Int
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
    /// Request the next encoded frame to be a forced IDR keyframe.
    /// The VTCompressionSession will include VPS/SPS/PPS in the output
    /// callback so the remote decoder can start immediately.
    /// Thread-safe (protected by `lock`).
    public func requestForcedKeyFrame() {
        lock.lock(); pendingForceKeyFrame = true; lock.unlock()
    }
    private var pendingForceKeyFrame = false
    private var forcedKeyFrameAtIndex: Int64 = -1

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
        // W567-fix v2: record frameIndex before encode if a forced keyframe
        // is requested, so handleOutput can check if this frame matches.
        let doForce = pendingForceKeyFrame
        if doForce {
            pendingForceKeyFrame = false
            forcedKeyFrameAtIndex = frameIndex
        }
        frameIndex += 1
        lock.unlock()

        var frameProps: CFDictionary? = nil
        if doForce {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        if status != noErr {
            throw EncoderError.encodeFailed(status)
        }
    }

    /// W398 — adjust bitrate mid-stream. VTCompressionSession allows
    /// AverageBitRate to be re-set on a live session; the encoder
    /// adjusts its rate-control on the next frames. No restart needed.
    /// Bounded to [VideoConstants.minVideoBitrateBps,
    /// maxVideoBitrateBps] so a wild ABR controller can't push the
    /// encoder into degenerate states.
    public func setBitrate(_ newBps: Int) {
        let clamped = max(VideoConstants.minVideoBitrateBps,
                          min(VideoConstants.maxVideoBitrateBps, newBps))
        lock.lock()
        guard let session = session else { lock.unlock(); return }
        bitrateBps = clamped
        lock.unlock()
        let status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: clamped))
        if status != noErr {
            print("[HevcEncoder] setBitrate(\(clamped)) failed status=\(status)")
        }
    }

    /// W524 — adjust expected frame rate mid-stream. Bounded to a sane
    /// VoIP range so the ABR controller cannot push the encoder into
    /// degenerate states. Note: the AVCaptureSession upstream still
    /// delivers frames at its own native cadence — this hint only
    /// affects rate-control (the encoder spends fewer bits on motion
    /// estimation when the expected rate is lower, which preserves
    /// per-frame quality at the bitrate budget the ABR set).
    public func setFps(_ newFps: Int) {
        let clamped = max(5, min(60, newFps))
        lock.lock()
        guard let session = session else { lock.unlock(); return }
        fps = clamped
        lock.unlock()
        let status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: clamped))
        if status != noErr {
            print("[HevcEncoder] setFps(\(clamped)) failed status=\(status)")
        }
    }

    /// W524 — recreate the VTCompressionSession at a new resolution.
    /// VideoToolbox does not allow width/height to change on a live
    /// session, so this tears down the current session and rebuilds
    /// it at the new dimensions. Caller MUST also update the upstream
    /// AVCaptureSession preset so the pixel buffers match. The new
    /// session inherits the current bitrate / fps / keyframe interval.
    public func setResolution(width newW: Int, height newH: Int) throws {
        guard newW > 0, newH > 0 else { return }
        // Save / restore bitrate + fps across the session recreation so
        // the ABR controller's last decision isn't reverted by the
        // tear-down. keyframeIntervalSec is `let` so it carries over
        // implicitly without an explicit save/restore.
        let oldFps = self.fps
        let oldBps = self.bitrateBps
        invalidate()
        self.width = newW
        self.height = newH
        self.bitrateBps = oldBps
        self.fps = oldFps
        try start()
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
        // Apple docs: "If kCMSampleAttachmentKey_NotSync is present and kCFBooleanTrue,
        // the sample is not a sync sample. If this key is absent, the sample is assumed
        // to be a sync sample." — so the correct default is isKeyFrame = true.
        // W567 v3: previous code defaulted to `false` in the else branch, which meant
        // that VideoToolbox keyframes with an absent or empty attachment array were
        // incorrectly marked as P-frames — the fragmenter never emitted VPS/SPS/PPS,
        // the remote decoder never bootstrapped, and video appeared frozen/choppy.
        var isKeyFrame: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            // notSync == false (or absent) → IS a sync (key) frame.
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKeyFrame = !notSync
        } else {
            // No attachments array, or array is empty — per Apple docs this means
            // the frame IS a sync frame (keyframe). Previously this branch returned
            // false, suppressing parameter-set emission and breaking the decoder.
            isKeyFrame = true
        }

        // W567-fix v2: if a forced keyframe was requested, the CMSampleBuffer
        // attachment might not be set correctly by VideoToolbox. Force isKeyFrame=true
        // for the first NAL of the frame with matching pts.
        lock.lock()
        let forcedFrame = forcedKeyFrameAtIndex
        lock.unlock()

        if forcedFrame >= 0, CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer) == CMTime(value: forcedFrame, timescale: CMTimeScale(fps)) {
            isKeyFrame = true
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
