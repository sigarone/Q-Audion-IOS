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
    private var _audioProcessingModule: RTCDefaultAudioProcessingModule?

    private init() {}

    /// Lazy accessor for the underlying RTCPeerConnectionFactory. Callers
    /// that need the TX capture tap (native-audio-srtp) must go through
    /// `sharedFactory` instead, to also get the `RTCDefaultAudioProcessingModule`
    /// handle to attach one to.
    public func factory() async -> RTCPeerConnectionFactory {
        await sharedFactory().factory
    }

    /// Builds the factory instance (called at most once per process by
    /// `sharedFactory()` below — see W-PERSISTENTFACTORY further down for
    /// why this is no longer per-call). `sealerProvider` on the public
    /// `sharedFactory()` entry point is retained for source-compatibility
    /// with existing call sites but is NO LONGER USED: 1:1 video E2EE moved
    /// from the codec-layer
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
    /// decoderFactory:)` initializer this class used before, to
    /// `initWithAudioDeviceModuleType:bypassVoiceProcessing:...
    /// audioProcessingModule:` — the only public initializer that accepts a
    /// custom `audioProcessingModule` at all.
    ///
    /// W-ADMPARITY (adversarial review, 2026-09-08) — an EARLIER version of
    /// this fix picked `.audioEngine` for that call, on the reasoning that
    /// this app's own `LiveKit` dependency already runs it in production —
    /// for GROUP calls. That reasoning does not carry over: `LiveKit` builds
    /// and owns an entirely separate `RTCPeerConnectionFactory` internally
    /// (see `LiveKitGroupCallRoom.swift`), with its own CallKit/session
    /// integration this class's 1:1 path does not share, and this app
    /// already fences the two apart precisely BECAUSE they cannot safely
    /// share one hardware audio unit (`AudioCapture.start()`'s group-call
    /// guard: "refusing 1:1 engine to avoid setVoiceProcessingEnabled
    /// SIGABRT"; `NativeAudioSessionGate`'s own doc records three earlier,
    /// independent attempts to hand this app's 1:1 session/ADM ownership to
    /// something other than the plain default, each of which measurably
    /// regressed a real call). `.audioEngine` selects a DIFFERENT concrete
    /// audio-device implementation than the one this class's argument-less
    /// initializer has always used — this app's entire 1:1 CallKit-activation
    /// / route-handling / VP-IO contract has zero hours of production
    /// history against it.
    ///
    /// `.platformDefault` is the behavior-preserving choice instead:
    /// read directly against the pinned `webrtc-sdk/webrtc@m144_release`
    /// factory source (`gh api`, not assumed), the SAME top-level
    /// device-module constructor this class's argument-less initializer
    /// already calls is the one `.platformDefault` reaches too — `.audioEngine`
    /// is the only one of the two enum cases that diverges to a different
    /// implementation. Selecting `.platformDefault` therefore gets the
    /// `audioProcessingModule` handle this fix needs while keeping the exact
    /// same underlying audio device this class shipped with before it — a
    /// verified swap of the CONSTRUCTOR PATH, not of the audio backend
    /// itself. `bypassVoiceProcessing: false` preserves hardware Voice-
    /// Processing-I/O (AEC+NS+AGC) on that path exactly as this class's own
    /// top-of-file doc has always promised ("hardware AEC + NS"). See
    /// `project_ios_native_capture_tap_adm_choice_2026_09_08.md` (session
    /// memory) for the full source-level verification this comment
    /// summarizes.
    ///
    /// W-PERSISTENTFACTORY (2026-09-09) — this factory (and the native
    /// AudioDeviceModule/AudioUnit underneath it) is now built ONCE per
    /// process and reused for every 1:1 call; only the `RTCPeerConnection`
    /// itself is created and closed per call (`QAudionWebRtcCallController`'s
    /// three call sites). Tonight's own live evidence — two independent,
    /// individually-correct CallKit/RTCAudioSession-activation fixes both
    /// landed and both executed cleanly, yet a call placed 6-9s (and, later,
    /// 22-25s) after a previous one still reproduced a permanently dead
    /// sender — traced the fault one layer below AVAudioSession: destroying
    /// and rebuilding the native AudioUnit on every call repeats a
    /// maintainer-acknowledged libwebrtc stop/teardown race (bug webrtc:5993)
    /// once per call instead of once per app run. A prior settle-delay
    /// mitigation here (1.5s, since removed) was verified insufficient live
    /// — a fixed delay can't beat a race with no platform completion signal.
    ///
    /// Sequential `RTCPeerConnection`s sharing one long-lived factory is
    /// WebRTC's own documented normal usage (`PeerConnectionFactoryInterface`'s
    /// own doc comment describes its `Options` as applying "to subsequently
    /// created PeerConnections" — plural, sequential creation is the
    /// intended case, with no stated requirement to wait for a prior
    /// connection's threads to quiesce first). `RTCAudioSession` itself is
    /// already a process-wide singleton independent of factory lifetime, so
    /// none of tonight's already-verified-live CallKit activation/
    /// deactivation bookkeeping (`CallKitProvider`, `CallKitCallLedger`)
    /// changes behavior here — only how many times the ADM object underneath
    /// gets constructed changes, from once-per-call to once-per-process.
    ///
    /// Deliberately NOT changed: `useManualAudio` stays `false`. Idling the
    /// audio unit via `RTCAudioSession.isAudioEnabled` is a documented no-op
    /// whenever `useManualAudio` is `false` (verified against WebRTC's own
    /// `RTCAudioSession.mm` source), so flipping it would only add a second,
    /// historically dangerous state gate (see `NativeAudioSessionGate`'s own
    /// doc — three prior regressions from exactly that combination) for zero
    /// benefit: WebRTC's automatic mode already starts/stops the unit on its
    /// own, driven by track add/remove, which is untouched by this change.
    private func buildFactory()
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
            audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: false,
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioProcessingModule: audioProcessingModule)
        return (factory, audioProcessingModule)
    }

    /// Returns the process-lifetime factory + ADM, building them once on
    /// first use and reusing them for every subsequent call.
    /// `sealerProvider` is retained for source-compatibility with existing
    /// call sites but is NO LONGER USED — see the class-level kdoc above
    /// this method's predecessor for why (native RTP-layer FrameCryptor,
    /// not codec-layer sealing, owns 1:1 video E2EE now).
    public func sharedFactory(sealerProvider: @escaping () -> VideoFrameSealer? = { nil }) async
        -> (factory: RTCPeerConnectionFactory, audioProcessingModule: RTCDefaultAudioProcessingModule) {
        lock.lock()
        defer { lock.unlock() }
        if let f = _factory, let apm = _audioProcessingModule {
            return (f, apm)
        }
        let built = buildFactory()
        _factory = built.factory
        _audioProcessingModule = built.audioProcessingModule
        return built
    }

    /// Tear down — only call from app-shutdown hooks. Also calls
    /// `RTCCleanupSSL()`, which is correct on final shutdown but NOT
    /// something to invoke mid-process — see `resetForWedgeRecovery()` for
    /// the mid-call safety-net equivalent.
    public func teardown() {
        lock.lock()
        _factory = nil
        _audioProcessingModule = nil
        lock.unlock()
        RTCCleanupSSL()
    }

    /// W-ADMWEDGERESET (2026-09-09) — mid-process escape hatch for
    /// `CallService`'s consecutive-audio-srtp-wedge safety net. Forces the
    /// NEXT `sharedFactory()` call to rebuild factory+ADM from scratch,
    /// mirroring WebRTC's own upstream mitigation for a wedged native audio
    /// unit (field trial `WebRTC-Audio-iOS-Holding`: stop → uninitialize →
    /// reinitialize the VoiceProcessingAudioUnit in place, no process
    /// restart needed) — this app's coarser version of the same idea, one
    /// level up at the factory/ADM instead of the raw AudioUnit, since
    /// Swift has no reachable hook into the AudioUnit itself. Deliberately
    /// does NOT call `RTCCleanupSSL()` — that call is for final process
    /// shutdown only; calling it here and re-initializing moments later on
    /// the next call would cycle global SSL state for no benefit, since
    /// `RTCInitializeSSL()` in `buildFactory()` is already idempotent and
    /// safe to call again without a matching cleanup in between.
    public func resetForWedgeRecovery() {
        lock.lock()
        _factory = nil
        _audioProcessingModule = nil
        lock.unlock()
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
