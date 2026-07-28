import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// W391 — hardware HEVC (H.265) decoder for iOS. Wraps
/// VTDecompressionSession. Caller pushes Annex-B NAL units (the same
/// shape `HevcEncoder` emits) and receives decoded `CVPixelBuffer`
/// frames via callback.
///
/// **Cross-platform contract:**
/// - Accepts the same Annex-B start-code-prefixed NAL units the
///   Android sender produces (and our own HevcEncoder emits) — VPS,
///   SPS, PPS as parameter-set NALs (NUT 32/33/34) plus IDR slices.
/// - On the first key frame, parameter sets are stripped and folded
///   into a `CMVideoFormatDescription`; the decoder is then created
///   lazily with that format. Subsequent frames carry slice NAL only
///   (matching the encoder's contract).
///
/// **Thread safety:** the public API uses an internal lock so a
/// single-producer single-consumer setup (capture-thread feeds, UI
/// thread reads decoded buffers) is safe. The output callback fires
/// on the VideoToolbox decoder thread; the caller's `onPixelBuffer`
/// closure must be reentrant.
public final class HevcDecoder: @unchecked Sendable {

    public typealias PixelBufferCallback = (CVPixelBuffer, CMTime) -> Void

    public enum DecoderError: Error, Equatable {
        case sessionCreateFailed(OSStatus)
        case sessionPropertyFailed(OSStatus)
        case formatDescriptionFailed(OSStatus)
        case decodeFailed(OSStatus)
        case malformedNalUnit
        case awaitingParameterSets
    }

    public var onPixelBuffer: PixelBufferCallback?

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?

    /// Cached parameter sets (VPS, SPS, PPS) extracted from the most
    /// recent key frame. The first call to `decode(_:)` after these are
    /// populated builds the format description and creates the session.
    private var pendingVps: Data?
    private var pendingSps: Data?
    private var pendingPps: Data?

    public init() {}

    deinit {
        invalidate()
    }

    public func invalidate() {
        lock.lock()
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDesc = nil
        pendingVps = nil
        pendingSps = nil
        pendingPps = nil
        lock.unlock()
    }

    // MARK: - Decode

    /// Decode an Annex-B NAL unit. Parameter-set NALs (VPS/SPS/PPS)
    /// are cached and folded into a CMVideoFormatDescription on first
    /// IDR slice. Slice NALs are submitted to VTDecompressionSession.
    /// Returns synchronously; decoded frames are delivered async via
    /// `onPixelBuffer`.
    public func decode(_ nalUnit: Data, presentationTime: CMTime = .zero) throws {
        // Strip start code (Annex-B 0x00000001 prefix).
        guard let stripped = Self.stripStartCode(nalUnit) else {
            throw DecoderError.malformedNalUnit
        }
        guard !stripped.isEmpty else { return }

        // HEVC NAL unit type is bits 1-6 of the first byte.
        let nalType = (stripped[stripped.startIndex] >> 1) & 0x3F
        switch nalType {
        case 32:
            lock.lock(); pendingVps = stripped; lock.unlock()
            return
        case 33:
            lock.lock(); pendingSps = stripped; lock.unlock()
            return
        case 34:
            lock.lock(); pendingPps = stripped; lock.unlock()
            return
        default:
            break
        }

        // Slice NAL — make sure session is ready.
        try ensureSessionReady()
        try submitSliceNal(stripped, presentationTime: presentationTime)
    }

    // MARK: - Session management

    private func ensureSessionReady() throws {
        lock.lock()
        if session != nil { lock.unlock(); return }
        guard let vps = pendingVps, let sps = pendingSps, let pps = pendingPps else {
            lock.unlock()
            throw DecoderError.awaitingParameterSets
        }
        lock.unlock()

        let fmt = try Self.makeFormatDesc(vps: vps, sps: sps, pps: pps)
        let newSession = try Self.makeSession(format: fmt) { [weak self] pb, pts in
            self?.onPixelBuffer?(pb, pts)
        }
        lock.lock()
        self.formatDesc = fmt
        self.session = newSession
        lock.unlock()
    }

    private func submitSliceNal(_ nalPayload: Data, presentationTime: CMTime) throws {
        lock.lock()
        guard let session = session, let fmt = formatDesc else {
            lock.unlock()
            throw DecoderError.awaitingParameterSets
        }
        lock.unlock()

        // Build AVCC-style length-prefixed sample for VideoToolbox.
        var avcc = Data(capacity: 4 + nalPayload.count)
        let len = UInt32(nalPayload.count).bigEndian
        withUnsafeBytes(of: len) { avcc.append(contentsOf: $0) }
        avcc.append(nalPayload)

        var blockBuffer: CMBlockBuffer?
        let blockStatus = avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddr = raw.baseAddress else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ).onSuccess {
                // force-unwrap safe: onSuccess only runs this closure when
                // the preceding CMBlockBufferCreateWithMemoryBlock returned
                // noErr, which per Apple's contract guarantees blockBufferOut
                // (blockBuffer) was populated.
                CMBlockBufferReplaceDataBytes(
                    // swiftlint:disable:next force_unwrapping
                    with: baseAddr, blockBuffer: blockBuffer!,
                    offsetIntoDestination: 0, dataLength: avcc.count)
            }
        }
        if blockStatus != noErr {
            throw DecoderError.decodeFailed(blockStatus)
        }
        guard let bb = blockBuffer else {
            throw DecoderError.decodeFailed(-1)
        }

        var sampleBuffer: CMSampleBuffer?
        var sizes: [Int] = [avcc.count]
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sampleBuffer
        )
        if sampleStatus != noErr {
            throw DecoderError.decodeFailed(sampleStatus)
        }
        guard let sb = sampleBuffer else { throw DecoderError.decodeFailed(-1) }

        var infoFlags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil, infoFlagsOut: &infoFlags)
        if decodeStatus != noErr {
            throw DecoderError.decodeFailed(decodeStatus)
        }
    }

    // MARK: - Helpers

    private static func stripStartCode(_ nal: Data) -> Data? {
        guard nal.count >= 4 else { return nil }
        let s = nal.startIndex
        // 0x00000001 (4-byte) or 0x000001 (3-byte) start code.
        if nal[s] == 0x00, nal[s+1] == 0x00, nal[s+2] == 0x00, nal[s+3] == 0x01 {
            return nal.subdata(in: (s+4)..<nal.endIndex)
        }
        if nal[s] == 0x00, nal[s+1] == 0x00, nal[s+2] == 0x01 {
            return nal.subdata(in: (s+3)..<nal.endIndex)
        }
        return nil
    }

    private static func makeFormatDesc(vps: Data, sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        let parameterSets: [Data] = [vps, sps, pps]
        // Build pointer + size arrays.
        var formatDescOut: CMVideoFormatDescription?
        let result: OSStatus = parameterSets.withUnsafeBufferPointers { bufs, sizes in
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: bufs,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &formatDescOut)
        }
        if result != noErr {
            throw DecoderError.formatDescriptionFailed(result)
        }
        guard let fmt = formatDescOut else {
            throw DecoderError.formatDescriptionFailed(-1)
        }
        return fmt
    }

    private static func makeSession(
        format: CMVideoFormatDescription,
        callback: @escaping PixelBufferCallback
    ) throws -> VTDecompressionSession {
        // Output pixel format: 32BGRA for direct CGImage / Metal compat.
        let outputAttrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]

        // Output callback marshalling — VideoToolbox calls a C function;
        // we route via an Unmanaged pointer to a closure-holder.
        final class CallbackHolder {
            let cb: PixelBufferCallback
            init(_ cb: @escaping PixelBufferCallback) { self.cb = cb }
        }
        let holder = CallbackHolder(callback)
        let cocb: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, pts, _ in
            guard status == noErr, let buffer = imageBuffer, let refcon = refcon else { return }
            let h = Unmanaged<CallbackHolder>.fromOpaque(refcon).takeUnretainedValue()
            h.cb(buffer, pts)
        }
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: cocb,
            decompressionOutputRefCon: Unmanaged.passRetained(holder).toOpaque())

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: outputAttrs as CFDictionary,
            outputCallback: &record,
            decompressionSessionOut: &newSession)
        if status != noErr {
            throw DecoderError.sessionCreateFailed(status)
        }
        guard let session = newSession else {
            throw DecoderError.sessionCreateFailed(-1)
        }
        // Real-time playback hint for streaming.
        _ = VTSessionSetProperty(
            session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return session
    }
}

// MARK: - Helpers

private extension OSStatus {
    /// Run `body` only if status is success; return the original status.
    /// Lets us thread error handling through CMBlockBufferCreate +
    /// CMBlockBufferReplaceDataBytes without a nested do/catch.
    func onSuccess(_ body: () -> Void) -> OSStatus {
        if self == noErr { body() }
        return self
    }
}

private extension Array where Element == Data {
    /// Run `body` with parallel arrays of (UnsafePointer<UInt8>, Int)
    /// for each Data. The pointers are valid only inside `body`.
    func withUnsafeBufferPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        // Pin every Data's bytes by recursively entering withUnsafeBytes
        // on each. We use a CPS-style helper.
        func loop(_ idx: Int,
                  _ ptrs: inout [UnsafePointer<UInt8>],
                  _ sizes: inout [Int],
                  _ done: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
            if idx == self.count {
                return done(ptrs, sizes)
            }
            return self[idx].withUnsafeBytes { raw -> R in
                guard let base = raw.baseAddress else { return done(ptrs, sizes) }
                ptrs.append(base.assumingMemoryBound(to: UInt8.self))
                sizes.append(raw.count)
                let r = loop(idx + 1, &ptrs, &sizes, done)
                ptrs.removeLast()
                sizes.removeLast()
                return r
            }
        }
        var ptrs: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        return loop(0, &ptrs, &sizes, body)
    }
}
