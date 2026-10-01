import Foundation
#if canImport(WebRTC)
import WebRTC

/// Video frame sealer selector for the codec-layer decorators: SFrame v1 (Q-Audion custom
/// envelope). Kept for potential iOS-only work; NOT selected for 1:1 calls, whose video is
/// encrypted by the native FrameCryptor (the Swift LiveKit-format fallback seal path was deleted:
/// its fixed key index and its own IV generator cannot satisfy the P12 replay rules).
public enum VideoFrameSealer {
    case sframe(SFrameVideoSealer)
}

/// W420 — Decorator for WebRTC encoders and decoders that injects SFrame (RFC 9605)
/// encryption/decryption into the video pipeline.
public final class SFrameVideoEncoderDecorator: NSObject, RTCVideoEncoder {
    private let delegate: RTCVideoEncoder
    private let sealerProvider: () -> VideoFrameSealer?
    private var callback: RTCVideoEncoderCallback?

    public init(
        delegate: RTCVideoEncoder,
        codecInfo: RTCVideoCodecInfo,
        sealerProvider: @escaping () -> VideoFrameSealer?
    ) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
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
                    layer: .low,
                    keyFrame: isKeyFrame,
                    padded: true // Match Android's 64-byte padding policy
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
    private var callback: RTCVideoDecoderCallback?

    public init(
        delegate: RTCVideoDecoder,
        codecInfo: RTCVideoCodecInfo,
        sealerProvider: @escaping () -> VideoFrameSealer?
    ) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
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
        let plaintext: Data
        do {
            switch sealer {
            case .sframe(let s):
                plaintext = try s.open(image.buffer)
            }
        } catch {
            // Log the first few open failures so a misconfigured call
            // (peer using a different format) doesn't silently black-screen
            // forever. Throttled to once per second per decoder.
            SFrameDecodeWarn.shared.warn(
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

/// Throttled warn-log helper for decoder open failures. A peer mismatch (different
/// codec, stale key, wrong format) would otherwise flood the console at 30 fps.
final class SFrameDecodeWarn: @unchecked Sendable {
    static let shared = SFrameDecodeWarn()
    private let lock = NSLock()
    private var lastAt: TimeInterval = 0

    func warn(_ msg: String) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let due = now - lastAt > 1.0
        if due { lastAt = now }
        lock.unlock()
        if due { print("[SFrameVideoDecorator] \(msg) (throttled)") }
    }
}
#endif
