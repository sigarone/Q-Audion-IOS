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

    /// W-ADUNITRACE (2026-09-09) — see `createFactory()`'s kdoc for the full
    /// story. Timestamp of the most recent `close()`-triggered teardown
    /// (`noteTeardownStarted()`), so the next `createFactory()` on a fast
    /// back-to-back call knows whether to wait.
    private var lastTeardownAt: Date?

    private init() {}

    /// W-ADUNITRACE (2026-09-09) — called from `QAudionPeerConnection.close()`
    /// the instant the native `RTCPeerConnection.close()` returns. That
    /// return is NOT proof the underlying platform AudioUnit has actually
    /// finished stopping — libwebrtc dispatches that teardown onto its own
    /// internal threads and gives this app no completion signal. Recording
    /// when teardown STARTED is the only data `createFactory()` has to work
    /// with; see its kdoc for what it does with this.
    public func noteTeardownStarted() {
        lock.lock()
        lastTeardownAt = Date()
        lock.unlock()
    }

    /// Lazy accessor for the underlying RTCPeerConnectionFactory. Callers
    /// that need the TX capture tap (native-audio-srtp) must go through
    /// `createFactory` instead — this cached instance has no reachable
    /// `RTCDefaultAudioProcessingModule` handle to attach one to.
    public func factory() async -> RTCPeerConnectionFactory {
        let cached: RTCPeerConnectionFactory? = {
            lock.lock(); defer { lock.unlock() }
            return _factory
        }()
        if let cached { return cached }
        // W-ADUNITRACE (2026-09-09) — createFactory() is now async (settle-wait
        // for the fresh-factory-per-call race, see its kdoc); this is a
        // one-time-ever lazy init with no prior teardown to race against, so
        // the wait it might add here is harmless (elapsed-since-teardown is
        // nil on first use, per createFactory()'s own guard).
        let f = await createFactory().factory
        lock.lock(); _factory = f; lock.unlock()
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
    /// W-ADUNITRACE (2026-09-09) — every call gets a FRESH factory (this
    /// function), and therefore a fresh native AudioDeviceModule/AudioUnit,
    /// never the previous call's. `close()` returning is not proof the
    /// PRIOR call's AudioUnit finished stopping — libwebrtc dispatches that
    /// teardown onto its own internal threads with no completion signal
    /// this app can observe (no callback, no pollable state; confirmed by
    /// grep: this codebase has never once checked an AudioUnit busy/
    /// cannot-do-in-current-context OSStatus). Live evidence tonight: two
    /// independent CallKit/AVAudioSession-layer fixes both landed and both
    /// executed correctly, yet a call placed 6-9s after a previous one
    /// still reproduced a permanently dead sender — the race is one layer
    /// below AVAudioSession, at the AudioUnit itself.
    ///
    /// The documented production mitigation for exactly this class of race
    /// (no platform completion signal exists) is a settle delay before the
    /// next start — heuristic, not a guarantee, because no better signal
    /// exists to wait on. `settleDelayNanos` below is deliberately more
    /// generous than the ~100-500ms cited in that documented practice,
    /// because tonight's own reproductions show total TX starvation
    /// persisting far longer than that (up to ~70s in one case) — a
    /// fixed short delay may still be insufficient if what's actually
    /// happening is closer to a stuck teardown than a brief async lag; this
    /// is a mitigation grounded in the best documented technique available,
    /// not a proven fix, and needs its own live call-to-call verification
    /// before being trusted, same as everything else tonight.
    public func createFactory(sealerProvider: @escaping () -> VideoFrameSealer? = { nil }) async
        -> (factory: RTCPeerConnectionFactory, audioProcessingModule: RTCDefaultAudioProcessingModule) {
        let settleDelayNanos: UInt64 = 1_500_000_000  // 1.5s
        let sinceLastTeardown: TimeInterval? = {
            lock.lock(); defer { lock.unlock() }
            guard let last = lastTeardownAt else { return nil }
            return Date().timeIntervalSince(last)
        }()
        if let elapsed = sinceLastTeardown, elapsed < 1.5 {
            let remainingNanos = settleDelayNanos - UInt64(elapsed * 1_000_000_000)
            print("[QAudionPeerConnectionFactory] W-ADUNITRACE settling \(remainingNanos / 1_000_000)ms — prior call's teardown was only \(Int(elapsed * 1000))ms ago")
            try? await Task.sleep(nanoseconds: remainingNanos)
        }
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
