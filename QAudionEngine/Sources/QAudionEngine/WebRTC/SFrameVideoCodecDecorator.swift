import Foundation
#if canImport(WebRTC)
import WebRTC

/// W420 — Decorator for WebRTC encoders and decoders that injects
/// SFrame (RFC 9605) encryption/decryption into the video pipeline.
///
/// This provides a byte-identical alternative to Android's native
/// `FrameCryptor` on iOS builds where the insertable-streams API
/// is unavailable.
public final class SFrameVideoEncoderDecorator: NSObject, RTCVideoEncoder {
    private let delegate: RTCVideoEncoder
    private let sealerProvider: () -> SFrameVideoSealer?
    private var callback: RTCVideoEncoderCallback?

    public init(delegate: RTCVideoEncoder, sealerProvider: @escaping () -> SFrameVideoSealer?) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
        super.init()
    }

    public func setCallback(_ callback: @escaping RTCVideoEncoderCallback) {
        self.callback = callback
        delegate.setCallback { [weak self] (image, codecInfo) -> Bool in
            guard let self = self, let callback = self.callback else { return false }
            
            // If no sealer is provided, pass through as plain WebRTC.
            guard let sealer = self.sealerProvider() else {
                return callback(image, codecInfo)
            }

            // Intercept and seal.
            guard let sealedData = try? sealer.seal(
                plaintext: image.buffer,
                layer: .L,
                keyFrame: image.frameType == .videoFrameKey,
                padded: true // Match Android's 64-byte padding policy
            ) else {
                return callback(image, codecInfo)
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
            
            return callback(encryptedImage, codecInfo)
        }
    }

    public func release() -> Int {
        return delegate.release()
    }

    public func encode(_ frame: RTCVideoFrame, codecSpecificInfo: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        return delegate.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: frameTypes)
    }

    public func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int {
        return delegate.setBitrate(bitrateKbit, framerate: framerate)
    }

    public func implementationName() -> String {
        return "SFrame(\(delegate.implementationName()))"
    }
}

public final class SFrameVideoDecoderDecorator: NSObject, RTCVideoDecoder {
    private let delegate: RTCVideoDecoder
    private let sealerProvider: () -> SFrameVideoSealer?
    private var callback: RTCVideoDecoderCallback?

    public init(delegate: RTCVideoDecoder, sealerProvider: @escaping () -> SFrameVideoSealer?) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
        super.init()
    }

    public func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
        delegate.setCallback { [weak self] (frame) -> Void in
            self?.callback?(frame)
        }
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
        do {
            let plaintext = try sealer.open(image.buffer)
            
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
        } catch {
            print("[SFrameVideoDecoder] decryption failed: \(error)")
            // Drop the frame — better to skip a frame than to feed garbage to the decoder.
            return 0
        }
    }

    public func implementationName() -> String {
        return "SFrame(\(delegate.implementationName()))"
    }
}

public final class SFrameVideoEncoderFactoryDecorator: NSObject, RTCVideoEncoderFactory {
    private let delegate: RTCVideoEncoderFactory
    private let sealerProvider: () -> SFrameVideoSealer?

    public init(delegate: RTCVideoEncoderFactory, sealerProvider: @escaping () -> SFrameVideoSealer?) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
        super.init()
    }

    public func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        guard let encoder = delegate.createEncoder(info) else { return nil }
        return SFrameVideoEncoderDecorator(delegate: encoder, sealerProvider: sealerProvider)
    }

    public func supportedCodecs() -> [RTCVideoCodecInfo] {
        return delegate.supportedCodecs()
    }
}

public final class SFrameVideoDecoderFactoryDecorator: NSObject, RTCVideoDecoderFactory {
    private let delegate: RTCVideoDecoderFactory
    private let sealerProvider: () -> SFrameVideoSealer?

    public init(delegate: RTCVideoDecoderFactory, sealerProvider: @escaping () -> SFrameVideoSealer?) {
        self.delegate = delegate
        self.sealerProvider = sealerProvider
        super.init()
    }

    public func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        guard let decoder = delegate.createDecoder(info) else { return nil }
        return SFrameVideoDecoderDecorator(delegate: decoder, sealerProvider: sealerProvider)
    }

    public func supportedCodecs() -> [RTCVideoCodecInfo] {
        return delegate.supportedCodecs()
    }
}
#endif
