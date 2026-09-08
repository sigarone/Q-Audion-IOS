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

    /// Lazy accessor for the underlying RTCPeerConnectionFactory. Callers
    /// that need the TX capture tap (native-audio-srtp) must go through
    /// `createFactory` instead — this cached instance has no reachable
    /// `RTCDefaultAudioProcessingModule` handle to attach one to.
    public var factory: RTCPeerConnectionFactory {
        lock.lock(); defer { lock.unlock() }
        if let f = _factory { return f }
        let f = createFactory().factory
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
    ///
    /// IOS-C4b TX-TAP FIX (2026-09-08) — also returns the
    /// `RTCDefaultAudioProcessingModule` backing this factory's audio
    /// pipeline, so a caller can attach an `RTCAudioCustomProcessingDelegate`
    /// (`NativeAudioCaptureTap`) to `capturePostProcessingDelegate` and
    /// actually observe the local mic's post-AEC PCM. `RTCAudioTrack.add(_:)`
    /// on the LOCAL (mic) track never delivers anything — libwebrtc's
    /// `LocalAudioSource::AddSink` (pc/local_audio_source.h) is an empty
    /// override in this pinned build (grep-verified, not assumed) — so the
    /// old `track.add(txTap)` wiring silently produced zero callbacks for the
    /// whole life of every call. `capturePostProcessingDelegate` is the real
    /// hook: it fires on the ACTUAL capture-side APM output, i.e. after
    /// hardware AEC/NS/AGC — the same signal that gets encoded and sent.
    ///
    /// Getting an `audioProcessingModule` handle at all requires switching
    /// off the argument-less `RTCPeerConnectionFactory(encoderFactory:
    /// decoderFactory:)` initializer this class used before: that path
    /// constructs the ADM via `webrtc::CreateAudioDeviceModule(env)`
    /// (`sdk/objc/native/api/audio_device_module.mm`), which builds
    /// `ios_adm::AudioDeviceModuleIOS` — a class with NO ObjC initializer
    /// that also accepts a custom `audioProcessingModule`. The only public
    /// initializer that takes one,
    /// `initWithAudioDeviceModuleType:bypassVoiceProcessing:...
    /// audioProcessingModule:`, offers exactly two `RTCAudioDeviceModuleType`
    /// values, neither of which is `AudioDeviceModuleIOS`:
    /// `.audioEngine` builds `webrtc::AudioEngineDevice`
    /// (`api/audio/create_audio_engine_device_module`), `.platformDefault`
    /// builds `AudioDeviceModuleImpl(kPlatformDefaultAudio)`
    /// (`api/audio/create_audio_device_module.cc`) — both confirmed via
    /// `gh api` against the exact pinned `webrtc-sdk/webrtc@m144_release`
    /// commit this binaryTarget builds from, not assumed. `.audioEngine` is
    /// used here — it is the SAME ADM class this app's own `LiveKit`
    /// dependency already runs in production for group calls
    /// (`client-sdk-swift`'s `RTC.swift`: `admType: .audioEngine,
    /// bypassVoiceProcessing: false`), so this is a proven-in-this-app
    /// configuration, not a novel one. `bypassVoiceProcessing: false`
    /// preserves hardware Voice-Processing-I/O (AEC+NS+AGC) exactly as this
    /// class's own top-of-file doc has always promised ("hardware AEC +
    /// NS"). Every 1:1 call's native audio device module changes with this
    /// commit — flagged and approved explicitly (not a silent swap); a live
    /// on-device echo/quality check is still warranted post-merge, CI
    /// compiling green does not cover that.
    public func createFactory(sealerProvider: @escaping () -> VideoFrameSealer? = { nil })
        -> (factory: RTCPeerConnectionFactory, audioProcessingModule: RTCDefaultAudioProcessingModule) {
        // RTCInitializeSSL is idempotent — safe to call once on first use.
        RTCInitializeSSL()

        let encoderFactory = HevcPreferredVideoEncoderFactory()
        let decoderFactory = HevcPreferredVideoDecoderFactory()
        // nil config/delegates = APM defaults (unchanged AEC/NS/AGC/HPF
        // toggle state versus today — same as LiveKit's own `.init()`, whose
        // designated initializer's params are all nullable so this is
        // equivalent). Delegates are attached later, per-call, via
        // `capturePostProcessingDelegate` — see `NativeAudioCaptureTap`.
        let audioProcessingModule = RTCDefaultAudioProcessingModule(
            config: nil,
            capturePostProcessingDelegate: nil,
            renderPreProcessingDelegate: nil)

        let factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: false,
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioProcessingModule: audioProcessingModule)
        return (factory, audioProcessingModule)
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
