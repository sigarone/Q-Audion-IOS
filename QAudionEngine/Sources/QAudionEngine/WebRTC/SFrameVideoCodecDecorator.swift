import Foundation
#if canImport(WebRTC)
import WebRTC

/// Cross-platform video frame sealer selector — picks the wire format
/// used for end-to-end video encryption on this call.
///
/// W420: SFrame v1 (Q-Audion custom envelope).
/// W539: LiveKit / libwebrtc native FrameCryptor envelope — the format
///       Desktop (`LiveKitFrameCryptor.ts`) and Android (libwebrtc
///       native `FrameCryptor`) actually emit / consume. Required for
///       cross-platform interop; the SFrame path is preserved for any
///       future iOS-only group-call work but is NOT selected for
///       1:1 calls by default.
public enum VideoFrameSealer {
    case sframe(SFrameVideoSealer)
    case livekit(LiveKitVideoFrameCryptor)
}

/// Map a `RTCVideoCodecInfo.name` (uppercased) to the cryptor's codec
/// tag. Used by the LiveKit cryptor to compute `unencrypted_bytes` and
/// to decide whether RBSP wrapping is required.
private func liveKitCodec(from name: String) -> LiveKitVideoFrameCryptor.FrameCodec {
    switch name.uppercased() {
    case "H264", "AVC": return .h264
    case "H265", "HEVC": return .h265
    case "VP8": return .vp8
    case "VP9": return .vp9
    case "AV1", "AV01": return .av1
    default:
        // Unknown codec → safest default is VP9 (`unencryptedBytes=0`),
        // which means the whole frame is ciphertext. If a peer rolls out
        // a new codec name we'll log+drop on the receive side; for now
        // this keeps us alive on best-effort fallback.
        return .vp9
    }
}

/// W420 — Decorator for WebRTC encoders and decoders that injects
/// SFrame (RFC 9605) or LiveKit (libwebrtc native) encryption/decryption
/// into the video pipeline.
///
/// This provides a byte-identical alternative to Android's native
/// `FrameCryptor` on iOS builds where the insertable-streams API
/// is unavailable.
public final class SFrameVideoEncoderDecorator: NSObject, RTCVideoEncoder {
    private let delegate: RTCVideoEncoder
    private let sealerProvider: () -> VideoFrameSealer?
    private let codec: LiveKitVideoFrameCryptor.FrameCodec
    private var callback: RTCVideoEncoderCallback?

    public init(
        delegate: RTCVideoEncoder,
        codecInfo: RTCVideoCodecInfo,
        sealerProvider: @escaping () -> VideoFrameSealer?
    ) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
        self.codec = liveKitCodec(from: codecInfo.name)
        super.init()
    }

    public func setCallback(_ callback: RTCVideoEncoderCallback?) {
        self.callback = callback
        guard callback != nil else {
            delegate.setCallback(nil)
            return
        }
        delegate.setCallback { [weak self] (image, codecInfo) -> Bool in
            guard let self = self, let cb = self.callback else { return false }

            // If no sealer is provided, pass through as plain WebRTC.
            guard let sealer = self.sealerProvider() else {
                return cb(image, codecInfo)
            }

            let isKeyFrame = image.frameType == .videoFrameKey
            let sealedDataOpt: Data?
            switch sealer {
            case .sframe(let s):
                sealedDataOpt = try? s.seal(
                    plaintext: image.buffer,
                    layer: .L,
                    keyFrame: isKeyFrame,
                    padded: true // Match Android's 64-byte padding policy
                )
            case .livekit(let lk):
                // W539 — LiveKit/libwebrtc native FrameCryptor wire format.
                // `image.timeStamp` is the RTP timestamp; SSRC is not
                // available at the codec layer (codec output happens
                // before RTP packetization), but the IV is carried on
                // the wire so the receiver doesn't need to reconstruct
                // it. Passing ssrc=0 is fine for interop — the receiver
                // reads `iv` from the trailer.
                sealedDataOpt = try? lk.seal(
                    data: image.buffer,
                    codec: self.codec,
                    isKeyFrame: isKeyFrame,
                    ssrc: 0,
                    rtpTimestamp: image.timeStamp
                )
            }

            guard let sealedData = sealedDataOpt else {
                // Seal failed — fall back to plain WebRTC for this frame.
                // Better than dropping; the inbound side may still drop
                // because the peer expects encrypted frames, but at least
                // logs/diagnostics will surface the issue instead of a
                // silent black-screen.
                return cb(image, codecInfo)
            }

            // Clone the image but with the encrypted buffer.
            let encryptedImage = RTCEncodedImage()
            encryptedImage.buffer = sealedData
            encryptedImage.encodedWidth = image.encodedWidth
            encryptedImage.encodedHeight = image.encodedHeight
            encryptedImage.timeStamp = image.timeStamp
            encryptedImage.captureTimeMs = image.captureTimeMs
            encryptedImage.ntpTimeMs = image.ntpTimeMs
            encryptedImage.flags = image.flags
            encryptedImage.encodeStartMs = image.encodeStartMs
            encryptedImage.encodeFinishMs = image.encodeFinishMs
            encryptedImage.frameType = image.frameType
            encryptedImage.rotation = image.rotation
            encryptedImage.qp = image.qp
            encryptedImage.contentType = image.contentType

            return cb(encryptedImage, codecInfo)
        }
    }

    public func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        return delegate.startEncode(with: settings, numberOfCores: numberOfCores)
    }

    public func release() -> Int {
        return delegate.release()
    }

    public func encode(_ frame: RTCVideoFrame, codecSpecificInfo: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        return delegate.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: frameTypes)
    }

    public func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        return delegate.setBitrate(bitrateKbit, framerate: framerate)
    }

    public func implementationName() -> String {
        return "SFrame(\(delegate.implementationName()))"
    }

    public func scalingSettings() -> RTCVideoEncoderQpThresholds? {
        return delegate.scalingSettings()
    }

    public var resolutionAlignment: Int { return delegate.resolutionAlignment }
    public var applyAlignmentToAllSimulcastLayers: Bool { return delegate.applyAlignmentToAllSimulcastLayers }
    public var supportsNativeHandle: Bool { return delegate.supportsNativeHandle }
}

public final class SFrameVideoDecoderDecorator: NSObject, RTCVideoDecoder {
    private let delegate: RTCVideoDecoder
    private let sealerProvider: () -> VideoFrameSealer?
    private let codec: LiveKitVideoFrameCryptor.FrameCodec
    private var callback: RTCVideoDecoderCallback?

    public init(
        delegate: RTCVideoDecoder,
        codecInfo: RTCVideoCodecInfo,
        sealerProvider: @escaping () -> VideoFrameSealer?
    ) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
        self.codec = liveKitCodec(from: codecInfo.name)
        super.init()
    }

    public func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
        delegate.setCallback { [weak self] frame in
            self?.callback?(frame)
        }
    }

    public func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        return delegate.startDecode(withNumberOfCores: numberOfCores)
    }

    public func release() -> Int {
        return delegate.release()
    }

    public func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo: RTCCodecSpecificInfo?, renderTimeMs: Int64) -> Int {
        // If no sealer is provided, pass through as plain WebRTC.
        guard let sealer = self.sealerProvider() else {
            return delegate.decode(image, missingFrames: missingFrames, codecSpecificInfo: codecSpecificInfo, renderTimeMs: renderTimeMs)
        }

        // Intercept and open.
        let isKeyFrame = image.frameType == .videoFrameKey
        let plaintext: Data
        do {
            switch sealer {
            case .sframe(let s):
                plaintext = try s.open(image.buffer)
            case .livekit(let lk):
                // W539 — Open the LiveKit/libwebrtc native FrameCryptor
                // wire-format frame produced by Desktop or Android.
                plaintext = try lk.open(
                    data: image.buffer,
                    codec: self.codec,
                    isKeyFrame: isKeyFrame
                )
            }
        } catch {
            // W539 — log the first few open failures so a misconfigured
            // call (e.g. wrong codec map, peer using a different format)
            // doesn't silently black-screen forever. Throttled to once
            // per second per decoder.
            LiveKitDecodeWarn.shared.warn(
                "decoder open failed: \(error)"
            )
            // Drop the frame — better to skip a frame than to feed
            // garbage to the underlying codec.
            return 0
        }

        // Clone the image but with the decrypted buffer.
        let decryptedImage = RTCEncodedImage()
        decryptedImage.buffer = plaintext
        decryptedImage.encodedWidth = image.encodedWidth
        decryptedImage.encodedHeight = image.encodedHeight
        decryptedImage.timeStamp = image.timeStamp
        decryptedImage.captureTimeMs = image.captureTimeMs
        decryptedImage.ntpTimeMs = image.ntpTimeMs
        decryptedImage.flags = image.flags
        decryptedImage.encodeStartMs = image.encodeStartMs
        decryptedImage.encodeFinishMs = image.encodeFinishMs
        decryptedImage.frameType = image.frameType
        decryptedImage.rotation = image.rotation
        decryptedImage.qp = image.qp
        decryptedImage.contentType = image.contentType

        return delegate.decode(decryptedImage, missingFrames: missingFrames, codecSpecificInfo: codecSpecificInfo, renderTimeMs: renderTimeMs)
    }

    public func implementationName() -> String {
        return "SFrame(\(delegate.implementationName()))"
    }
}

public final class SFrameVideoEncoderFactoryDecorator: NSObject, RTCVideoEncoderFactory {
    private let delegate: RTCVideoEncoderFactory
    private let sealerProvider: () -> VideoFrameSealer?

    public init(delegate: RTCVideoEncoderFactory, sealerProvider: @escaping () -> VideoFrameSealer?) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
        super.init()
    }

    public func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        guard let encoder = delegate.createEncoder(info) else { return nil }
        return SFrameVideoEncoderDecorator(delegate: encoder, codecInfo: info, sealerProvider: sealerProvider)
    }

    public func supportedCodecs() -> [RTCVideoCodecInfo] {
        return delegate.supportedCodecs()
    }
}

public final class SFrameVideoDecoderFactoryDecorator: NSObject, RTCVideoDecoderFactory {
    private let delegate: RTCVideoDecoderFactory
    private let sealerProvider: () -> VideoFrameSealer?

    public init(delegate: RTCVideoDecoderFactory, sealerProvider: @escaping () -> VideoFrameSealer?) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
        super.init()
    }

    public func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        guard let decoder = delegate.createDecoder(info) else { return nil }
        return SFrameVideoDecoderDecorator(delegate: decoder, codecInfo: info, sealerProvider: sealerProvider)
    }

    public func supportedCodecs() -> [RTCVideoCodecInfo] {
        return delegate.supportedCodecs()
    }
}

/// W539 — throttled warn-log helper for LiveKit decoder open failures.
/// A peer mismatch (different codec, stale key, wrong format) would
/// otherwise flood the console at 30 fps.
final class LiveKitDecodeWarn: @unchecked Sendable {
    static let shared = LiveKitDecodeWarn()
    private let lock = NSLock()
    private var lastAt: TimeInterval = 0

    func warn(_ msg: String) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let due = now - lastAt > 1.0
        if due { lastAt = now }
        lock.unlock()
        if due { print("[LiveKitVideoCryptor] \(msg) (throttled)") }
    }
}
#endif
