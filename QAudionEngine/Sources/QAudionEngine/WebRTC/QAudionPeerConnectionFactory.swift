import Foundation
#if canImport(WebRTC)
import WebRTC

/// Lazy singleton that initializes Google's libwebrtc once per process.
/// Mirrors Android's `feature/feature-call/.../webrtc/PeerConnectionFactoryProvider.kt`:
/// one factory shared by every PeerConnection, default audio device with
/// hardware AEC + NS, default video encoder/decoder factories.
///
/// **Cross-platform contract:**
/// - Both peers MUST use the same SDP m-line ordering (audio first, video
///   second when present) so the m-line indices in ICE candidates match.
/// - Audio track id `audio0` and video track id `video0` are stable across
///   builds — use `setRemoteTrackIdsStable` if you ever need to bump.
public final class QAudionPeerConnectionFactory: @unchecked Sendable {

    public static let shared = QAudionPeerConnectionFactory()

    private let lock = NSLock()
    private var _factory: RTCPeerConnectionFactory?

    private init() {}

    /// Lazy accessor for the underlying RTCPeerConnectionFactory.
    public var factory: RTCPeerConnectionFactory {
        lock.lock(); defer { lock.unlock() }
        if let f = _factory { return f }
        let f = createFactory()
        _factory = f
        return f
    }

    /// Create a new factory instance, optionally decorated with a video
    /// frame sealer provider. The provider is consulted per-frame so
    /// mid-call sealer changes (e.g. legacy → LiveKit after the cap
    /// handshake completes) are picked up without rebuilding the factory.
    /// `sealerProvider` is retained for source-compatibility with existing call
    /// sites but is NO LONGER USED: 1:1 video E2EE moved from the codec-layer
    /// `SFrameVideoEncoder/DecoderFactoryDecorator` to the native RTP-layer
    /// `RTCFrameCryptor` (NativeVideoFrameCryptor). Wrapping the codec factories
    /// would DOUBLE-ENCRYPT (codec-layer seal + native FrameCryptor). So we
    /// return the plain HEVC-preferred factories — they still advertise/build
    /// H265 (RTCVideoEncoderH265/Decoder), which the native cryptor then encrypts
    /// after packetization (codec-agnostic). See NativeVideoFrameCryptor.swift.
    public func createFactory(sealerProvider: @escaping () -> VideoFrameSealer? = { nil }) -> RTCPeerConnectionFactory {
        // RTCInitializeSSL is idempotent — safe to call once on first use.
        RTCInitializeSSL()

        let encoderFactory = HevcPreferredVideoEncoderFactory()
        let decoderFactory = HevcPreferredVideoDecoderFactory()

        return RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }

    /// Tear down — only call from app-shutdown hooks.
    public func teardown() {
        lock.lock()
        _factory = nil
        lock.unlock()
        RTCCleanupSSL()
    }

    /// Build the default `RTCConfiguration` used by all 1:1 calls.
    /// Caller passes `iceServers` (typically built from
    /// `RelayCredentialsProvider.RelayBundle.servers`).
    public static func defaultConfiguration(iceServers: [RTCIceServer]) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        // Trickle ICE: candidates flow as they're discovered, no pre-gather wait.
        config.iceTransportPolicy = .all
        return config
    }

    /// Convenience converter from our [RelayServer] DTO to WebRTC's [RTCIceServer].
    public static func iceServers(from relays: [RelayServer]) -> [RTCIceServer] {
        return relays.map { rs in
            RTCIceServer(urlStrings: rs.urls,
                          username: rs.username ?? "",
                          credential: rs.credential ?? "")
        }
    }
}
#endif
