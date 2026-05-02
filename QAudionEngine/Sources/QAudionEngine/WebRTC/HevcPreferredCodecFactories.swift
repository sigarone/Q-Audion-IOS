import Foundation
#if canImport(WebRTC)
import WebRTC

/// HEVC-prefer wrapper around RTCDefaultVideoEncoderFactory /
/// RTCDefaultVideoDecoderFactory. Mirror of Android's
/// `HevcAwareVideoEncoderFactory.kt`.
///
/// **Why we override:** the default WebRTC factory lists codecs in
/// alphabetical order, which means H264 is offered before H265. When both
/// peers support HEVC we want it first in the SDP so the negotiator
/// picks it (HEVC = ~30% lower bitrate at the same perceived quality;
/// matches Q-Audion's bandwidth budget on cellular).
///
/// On iPhone hardware HEVC is native (iOS 11+, all supported devices in
/// the 16+ deployment target) so the underlying RTCVideoEncoderH265
/// is always present — no availability gate needed (cf. Android, which
/// has to probe vendor HEVC encoders explicitly).
///
/// **Cross-platform contract:** Android's HevcAwareVideoEncoderFactory
/// puts H265 first when it's available; this iOS factory does the same.
/// The SDP negotiator on either side picks H265 if both advertise it,
/// otherwise falls back to H264 High Profile.
public final class HevcPreferredVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let delegate: RTCVideoEncoderFactory

    public override convenience init() {
        self.init(delegate: RTCDefaultVideoEncoderFactory())
    }

    public init(delegate: RTCVideoEncoderFactory) {
        self.delegate = delegate
        super.init()
    }

    public func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        return delegate.createEncoder(info)
    }

    public func supportedCodecs() -> [RTCVideoCodecInfo] {
        let base = delegate.supportedCodecs()
        // Push H265 to front so SDP negotiation prefers it.
        let h265 = base.filter { $0.name.uppercased() == "H265" }
        let other = base.filter { $0.name.uppercased() != "H265" }
        return h265 + other
    }
}

/// HEVC-prefer wrapper for the decoder factory. Mirrors the encoder.
public final class HevcPreferredVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let delegate: RTCVideoDecoderFactory

    public override convenience init() {
        self.init(delegate: RTCDefaultVideoDecoderFactory())
    }

    public init(delegate: RTCVideoDecoderFactory) {
        self.delegate = delegate
        super.init()
    }

    public func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        return delegate.createDecoder(info)
    }

    public func supportedCodecs() -> [RTCVideoCodecInfo] {
        let base = delegate.supportedCodecs()
        let h265 = base.filter { $0.name.uppercased() == "H265" }
        let other = base.filter { $0.name.uppercased() != "H265" }
        return h265 + other
    }
}
#endif
