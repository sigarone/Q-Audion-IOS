import Foundation
import CryptoKit
import Network
#if canImport(WebRTC)
import WebRTC
#if os(iOS)
import AVFoundation
#endif

/// Orchestrates a single 1:1 WebRTC call from the iOS side. Bridges the
/// existing CallingApi signaling (call_offer / call_answer / call_ice /
/// call_hangup) onto a [QAudionPeerConnection].
///
/// **Caller flow:**
/// ```swift
///   let ctrl = QAudionWebRtcCallController(callingApi: callingApi,
///                                            relayProvider: relayProvider)
///   try await ctrl.startOutgoingCall(recipientId: peerId, audioOnly: true)
/// ```
/// `startOutgoingCall` fetches TURN credentials, builds the peer
/// connection, generates the SDP offer, and ships via
/// `CallingApi.sendCallOffer`. Subsequent inbound `call_answer` /
/// `call_ice` envelopes must be routed through the
/// `handleRemoteAnswer(sdp:)` / `handleRemoteIce(...)` methods.
///
/// **Callee flow:**
/// ```swift
///   try await ctrl.acceptIncomingCall(callerId: peerId, offerSdp: sdp)
/// ```
/// Builds the peer connection, applies the remote offer, generates the
/// answer, ships via `CallingApi.sendCallAnswer`. Subsequent inbound
/// `call_ice` envelopes are also routed through `handleRemoteIce(...)`.
public final class QAudionWebRtcCallController: NSObject, QAudionPeerConnection.Delegate, @unchecked Sendable {

    public enum State: Equatable {
        case idle
        case outgoingOffering
        case incomingAnswering
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((State) -> Void)?
    public var onIceConnectionState: ((RTCIceConnectionState) -> Void)?

    /// W-SHIELDWIRE (2026-08-17) — fired once per ICE connect/reconnect with
    /// the ACTUAL negotiated candidate-pair type ("relay", "srflx", "prflx",
    /// or "host"), read live from `RTCStatistics` — never re-derived from
    /// `TransportGate.forcesRelay`. Before this, the in-call shield's P2P/
    /// TURN/RELAY badge just echoed back the static Settings choice at the
    /// moment ICE connected, so it showed "P2P" under AUTO/P2P mode even on
    /// the real occasions ICE itself fell back to a relay candidate, and
    /// showed the identical "TURN" label for both the TURN-only and the
    /// (distinct, WS-relay) Relay-only settings — the shield could never
    /// actually disagree with what the user had picked, which is what made
    /// it look like the setting "did nothing" (Pavel, live device test).
    public var onActiveCandidatePairType: ((String) -> Void)?

    /// W-VPNCALLGATE (2026-08-26) — the selected candidate pair's REMOTE
    /// address (not the type — `onActiveCandidatePairType` above already
    /// covers that), for the VPN call-media gate: `AppState`/`VpnService`
    /// punch this one destination out of the WireGuard tunnel's `allowedIPs`
    /// for the call's duration (see `CidrExclusion` kdoc — mirrors Android's
    /// `07c517b9a` `CallController`-state gate, which iOS has no per-app
    /// exclusion API to replicate directly). `nil` when no pair has resolved
    /// yet or the resolved remote candidate's stat carries no address field.
    /// Fires from the SAME `resolveAndApplyRouteTier` poll as
    /// `onActiveCandidatePairType`, so it shares that method's cadence and
    /// the same "no confirmed delegate event, stats-polling only" gap noted
    /// in that method's doc.
    public var onActiveCandidatePairRemoteHost: ((String?) -> Void)?

    /// W419/W-ICEVIS — this engine target cannot reach `RTLog` (app-target
    /// only, same constraint `CallKitProvider.log` was added for earlier).
    /// Every `print("[WebRTC] ...")` in this file was therefore invisible
    /// in every remote log pull no matter how many calls were made — the
    /// ICE/DTLS state comments below say "crucial for diagnosing" while
    /// shipping nothing. Set from the app target alongside construction.
    public var log: ((String) -> Void)?
    public var onRemoteAudioTrack: ((RTCAudioTrack) -> Void)?
    public var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?

    /// IOS-C4b / PCM-TAP PARITY (2026-08-26) — fired with each little-endian
    /// Int16 mono 48 kHz chunk of the REMOTE peer's decoded native-SRTP
    /// audio. `CallService` wires this to
    /// `QAudionCallIntegration.feedNativeAudioSrtpRxPcm(_:)`, which reuses
    /// the exact same Guardian/VoiceAnalysis/ContactVoiceVerifier/
    /// VoiceLearningSession consumer chain the sealed-DataChannel decode
    /// path already feeds — see `NativeAudioPcmTap`'s doc for why this
    /// exists. May be invoked from WebRTC's own audio callback thread;
    /// consumers must not block (same contract as
    /// `QAudionCallIntegration.enqueueForAnalysis`).
    public var onNativeAudioSrtpRxPcm: ((Data) -> Void)?
    /// TX/local-mic counterpart — mirrors Android's `feedOwnerContinuity`
    /// wiring on `audioSrtpTxSink`. `CallService` wires this to
    /// `QAudionCallIntegration.feedNativeAudioSrtpTxPcm(_:)`.
    public var onNativeAudioSrtpTxPcm: ((Data) -> Void)?

    /// W-SRTPFALLBACK (2026-08-26) — fired when a native-audio-srtp call's
    /// ICE has been bad for the full debounce window (see
    /// `SrtpFallbackDecisions`). `CallService` wires this to (re-)start its
    /// manual AVAudioEngine capture/decode path — the one it bypasses for
    /// the whole call while native audio owns TX/RX — so the call does not
    /// go silent while ICE is down. Never fires on a call that did not
    /// negotiate `audioSrtpV1` (nothing to fall back from).
    public var onAudioSrtpFallbackEngage: (() -> Void)?
    /// Counterpart — fired the instant ICE recovers after an engage.
    /// `CallService` wires this to stop the manual capture path again so
    /// native audio resumes as the sole TX/RX owner (bounding the
    /// double-audio window).
    public var onAudioSrtpFallbackRecover: (() -> Void)?

    /// W-UPGRADEICEWATCHDOG-ANCHOR (2026-08-24, mirrors Android's
    /// W-ICEANCHOR / `remoteDescriptionAppliedAtMs`) — fired once
    /// `setRemoteOffer` has actually succeeded inside
    /// `acceptUpgradeOfferBuildingPeerConnection`, i.e. the moment ICE
    /// negotiation can genuinely begin. Exists so a caller-armed "give up on
    /// ICE after N seconds" watchdog can anchor its countdown here instead
    /// of at controller-construction time — `fetchIceServers()` (an await
    /// just above the call site) can itself eat part of a fixed budget
    /// otherwise, undercounting how long ICE actually had. `nil` by default;
    /// only `AppState.makeUpgradeResponderController()` currently sets it.
    public var onRemoteDescriptionApplied: (() -> Void)?

    /// WIRE_SPEC §8.7 — fired ONCE per call when the RECEIVER-side native
    /// video cryptor is BOTH attached to the inbound RTP receiver AND
    /// keyed (K_video published). The argument is the established inbound
    /// video mid, or `nil` when the transceiver mid could not be resolved.
    /// AppState wires this to `sendCallMediaReady(dir:"recv", keyEpoch:0)`
    /// so the sender forces an IDR the moment we can actually decrypt.
    /// May be invoked from the WebRTC signalling thread OR from whichever
    /// thread published the PQC key last — consumers must hop to
    /// @MainActor themselves (same contract as onRemoteVideoTrack).
    public var onInboundVideoReady: ((String?) -> Void)?

    /// WIRE_SPEC §8.7 (INT-4a) — fired when the RECEIVER-side video decode
    /// has STALLED: the inbound video track exists and bytes are arriving,
    /// but `framesDecoded` has not advanced for ~5s (the decoder is missing
    /// its keyframe — the E2EE frame-transform suppresses libwebrtc's native
    /// PLI, so recovery needs an explicit wire nudge). AppState wires this to
    /// `sendVideoKeyframeRequest` (rate-limited 1/s at the API layer per §8.7).
    ///
    /// INT-4a rails (updated): the receiver detects the stall (from the
    /// `framesDecoded` stat it already polls) and nudges the sender over
    /// the already-wired `video_keyframe_request`. On the WS-HEVC relay
    /// rail the sender's honor path is `videoPipeline.forceKeyFrame()`;
    /// on the pure WebRTC RTP rail it is `forceWebRtcKeyframe()` — the
    /// `KeyframeForcingVideoEncoder` wrapper installed by
    /// `HevcPreferredVideoEncoderFactory.createEncoder` rewrites the next
    /// `encode()` call's `frameTypes` to `.videoFrameKey` (exactly how
    /// libwebrtc itself requests an IDR on a PLI), plus a ~5s periodic
    /// safety net — mirroring Android's KeyframeForcingVideoEncoder.
    /// (An earlier note here claimed sender-side forcing was impossible
    /// on this binary; that was wrong — the ObjC encoder protocol makes
    /// `frameTypes` substitutable by any wrapper.)
    /// May fire from the WebRTC stats callback thread — consumers hop to
    /// @MainActor themselves.
    public var onVideoStallDetected: (() -> Void)?

    /// W-KFFAST (2026-08-25) — fired the moment the RECEIVER-side native
    /// video cryptor's own state callback reports DECRYPTIONFAILED /
    /// MISSINGKEY / INTERNALERROR (rekey skew, a storm of failing frames,
    /// ratchet gap). The E2EE frame transform suppresses libwebrtc's
    /// native PLI, so before this the only recovery signal was the
    /// multi-second `onVideoStallDetected` ladder above (3s poll x 2 ≈
    /// 6s minimum) — this fires within ONE frame of the cryptor detecting
    /// the failure, matching Android's `FrameCryptor.setObserver` hook in
    /// `PeerConnectionHolder.enableVideoFrameCryptorOnReceiver`
    /// (PeerConnectionHolder.kt:1551-1562, W-KFFAST 2026-08-25). AppState
    /// wires this to the SAME `requestKeyframeFromSender` AppState already
    /// uses for `onVideoStallDetected`, so the wire-layer 1/s limiter
    /// (`BCryptoCallingApiImpl.checkKeyframeRequestRateLimit`, matching
    /// Android's `KEYFRAME_WIRE_RATE_LIMIT_MS = 1_000L`) absorbs a storm
    /// of failing frames into one `video_keyframe_request` per second.
    /// Healthy states (NEW/OK/KEYRATCHETED) do not trigger. May fire from
    /// the WebRTC signalling thread (the native cryptor's own callback
    /// thread) — consumers hop to @MainActor themselves, same contract as
    /// `onVideoStallDetected`.
    public var onDecryptFailureDetected: (() -> Void)?

    /// W-DCAUDIO — inbound sealed-audio frames received over the WebRTC
    /// DataChannel ("qaudion-audio"). Set by the app layer (CallService) to route
    /// the raw WireRelayFrameCodec bytes into `handleIncomingEncryptedFrame`,
    /// exactly as the WS "audio_frame" handler does. Forwarded to the live
    /// `QAudionPeerConnection.onAudioDataChannelFrame` when the PC is created.
    public var onAudioDataChannelFrame: ((Data) -> Void)?

    /// W-DCMUX (2026-08-11) — sealed-audio DataChannel lifecycle as the raw
    /// `RTCDataChannelState` (0 connecting, 1 open, 2 closing, 3 closed). Set by
    /// the app layer, forwarded to the live `QAudionPeerConnection
    /// .onAudioDataChannelStateChange` at every PC construction site, exactly
    /// like `onAudioDataChannelFrame` beside it. Fires on the WebRTC signalling
    /// thread; the consumer hops to the main actor itself if it needs to.
    public var onAudioDataChannelStateChange: ((Int) -> Void)?

    /// W-DCAUDIO — send a sealed audio frame over the DataChannel if it is open.
    /// Returns `true` if queued on the DC; `false` if the DC is not open, in which
    /// case the caller (CallService) falls back to the WS relay.
    ///
    /// W-DCTXICEGATE (2026-08-30) — ALSO returns `false` while ICE is not
    /// actually carrying, because "the DataChannel is open" stops meaning
    /// "the DataChannel can deliver" the moment ICE goes down mid-call.
    /// This controller repairs a handoff with `restartIce` on the SAME
    /// PeerConnection, so the SCTP association and the `qaudion-audio`
    /// channel sit out an ICE `.disconnected`/`.failed`/`.checking`
    /// episode in `.open` — and with `maxRetransmits = 0` every frame
    /// written into it during the outage is simply gone. Before this gate,
    /// that was the WHOLE outage: the W-DCAUDIO relay escape below never
    /// fired, and the iOS leg was one-way silent for up to the full
    /// restart budget. Android hit the same two-timers gap and fixed it
    /// the same way (W-RELAYSENDWHILEGRACE,
    /// CallTransportFactory.shouldDivertToRelayLeg): route THIS frame to
    /// the leg that can deliver it, without touching the recovery machine.
    /// The instant ICE reports `.connected`/`.completed` again, the very
    /// next frame goes back to the DataChannel — no mode, no debounce.
    @discardableResult
    public func sendAudioFrameData(_ data: Data) -> Bool {
        guard Self.iceIsCarrying(lastIceConnectionState) else { return false }
        return peerConnection?.sendAudioFrameData(data) ?? false
    }

    /// W-DCTXICEGATE — the single definition of "ICE is actually carrying
    /// media". `.checking` is deliberately NOT carrying: during a mid-call
    /// restart the pair is being rebuilt and frames sent there are lost.
    /// On a fresh call this gate changes nothing — the DataChannel is not
    /// `.open` before ICE first connects, so both predicates were already
    /// `false` together.
    static func iceIsCarrying(_ s: RTCIceConnectionState) -> Bool {
        s == .connected || s == .completed
    }

    /// W-DCTXICEGATE — diagnostic twin for the W-DCMUX fallback-reason
    /// closure in AppState: `true` when the gate above (and nothing else)
    /// is what is diverting audio to the WS relay right now.
    public var audioTxIceGateClosed: Bool {
        !Self.iceIsCarrying(lastIceConnectionState)
    }

    /// W-DCMUX (2026-08-11) — the DataChannel's raw `RTCDataChannelState`, or
    /// `-1` when this controller has a PeerConnection but no channel object, or
    /// `-4` when it has no PeerConnection at all.
    ///
    /// Read-only diagnostic. `-4` is deliberately not `-2`: the app layer uses
    /// `-2` for "no controller", and "no controller" and "a controller whose PC
    /// is gone" are different failures — the first means this call never built a
    /// WebRTC leg, the second means it built one and lost it.
    /// ``sendAudioFrameData`` returns the same `false` for both.
    public var audioDataChannelStateRaw: Int {
        guard let pc = peerConnection else { return -4 }
        return pc.audioDataChannelStateRaw()
    }

    /// Diagnostic telemetry sink for the video pipeline (kind, attrs).
    /// Mirrors the Android `PeerConnectionHolder.videoTelemetry` hook so an
    /// iOS↔Android video failure is diagnosable REMOTELY from the admin
    /// telemetry API. Set by AppState to `TelemetryService.shared.emit`.
    /// The engine cannot reach the app-layer TelemetryService directly,
    /// hence the closure indirection.
    public var videoTelemetry: ((String, [String: Any]) -> Void)?
    /// Repeating timer that polls outbound/inbound video RTP stats while a
    /// call is connected. Created on ICE-connected, invalidated on close.
    private var videoStatsTimer: Timer?

    // ── W-NETVIS (Android→iOS parity, 2026-08-10) — media-path RTT ───────────
    //
    // Android reads RTT from the SELECTED ICE candidate pair
    // (`PeerConnectionHolder.collectDiagnostics`, PeerConnectionHolder.kt:3914
    // -3922: first a `candidate-pair` with state=="succeeded" AND
    // (nominated||selected), else any succeeded pair; `currentRoundTripTime`
    // × 1000). This is the identical statistic, read the identical way, so the
    // two platforms' RITARDO columns describe the same quantity during one
    // call.
    //
    // What is NOT copied from Android is WHEN the number is shown. On Android
    // the WS-relay downgrade never closes the PeerConnection
    // (`CallTransportFactory.downgradeToWsRelay`, CallTransportFactory.kt:944
    // -973) and the stats call is wired straight to it regardless of transport
    // mode (CallModule.kt:293-294), so a relay call — every Android↔iOS call —
    // still shows a plausible RTT measured on an ICE pair that carries no
    // voice at all. Here the reading is published only while the sealed-audio
    // DataChannel is open, i.e. only while this pair IS the leg carrying the
    // audio (`isAudioDataChannelOpen`, checked by the caller). On the WS-relay
    // path the value stays nil and the band renders "—", which is the honest
    // answer: no measurement of the media path exists there.
    private var _mediaRttMs: Double?
    /// NSLock-protected for the same reason as [answerLock]: `pc.statistics`
    /// delivers its report on a WebRTC-internal thread while the sampler that
    /// reads this runs on the main actor.
    private let mediaRttLock = NSLock()

    /// Last RTT measured on the selected ICE candidate pair, in milliseconds.
    /// `nil` when no succeeded pair exists yet (ICE still converging, ICE
    /// failed, or the peer connection is gone) — never a stale or invented
    /// number. Refreshed by [pollMediaRttOnce].
    public var mediaRttMs: Double? {
        mediaRttLock.lock()
        defer { mediaRttLock.unlock() }
        return _mediaRttMs
    }

    // ── IOS-E6 (W-DELAYSPLIT parity, 2026-08-25) ──────────────────────────
    //
    // Android's `CallDiagnostics.audioJitterBufferDelaySec` /
    // `audioJitterBufferEmittedCount` (feature-call
    // `.../diagnostics/CallDiagnostics.kt:79-80`) are the CUMULATIVE
    // `inbound-rtp` (kind=audio) `jitterBufferDelay` seconds /
    // `jitterBufferEmittedCount` samples straight off `RTCStatsReport`
    // (`PeerConnectionHolder.kt:5087-5088`). The ViewModel derives a
    // WINDOWED average playout-buffer delay in ms from the DELTA between
    // two consecutive polls (`CallViewModel.computeBufWindowMs`,
    // CallViewModel.kt:2469-2481) and shows it next to RTT as
    // "<rtt>+<buf>ms" once ≥10 ms (`InCallScreen.kt:1170-1176`).
    //
    // These two properties are the iOS mirror of the RAW cumulative pair —
    // the windowing/delta math lives in `AppState.sampleCallNetworkStats`
    // (the same layer that already owns the RTT windowing/gating), exactly
    // where Android's ViewModel owns it, not here.
    //
    // Honesty note (graph-verified iOS reality, not Android's): iOS has NO
    // SRTP audio track today — W574d disables the inbound SRTP audio track
    // at receiver-discovery (`QAudionPeerConnection.swift`, `didAdd
    // rtpReceiver`) and voice rides the sealed DataChannel / WS relay
    // instead. Android's OWN field is documented "Zero on the DataChannel
    // path" — so this reading zero on every iOS call today is not iOS-
    // specific breakage, it is the SAME documented behaviour the metric
    // already has on Android whenever DC carries the audio. This is
    // observability infrastructure for the day iOS/audio-srtp ships (or for
    // any future SRTP-audio call), not a dormant iOS-only feature — the
    // playbook explicitly asks for the instrumentation prerequisite ahead
    // of the capability, not gated behind it.
    private var _mediaJitterBufferDelaySec: Double = 0.0
    private var _mediaJitterBufferEmittedCount: Int64 = 0

    /// Cumulative seconds audio samples have spent in the jitter buffer,
    /// straight off `inbound-rtp.jitterBufferDelay` (kind=audio). Pair with
    /// [mediaJitterBufferEmittedCount] and diff across polls for a windowed
    /// average — see the class-level IOS-E6 note above for why the delta
    /// math belongs one layer up, not here.
    public var mediaJitterBufferDelaySec: Double {
        mediaRttLock.lock(); defer { mediaRttLock.unlock() }
        return _mediaJitterBufferDelaySec
    }

    /// Cumulative `inbound-rtp.jitterBufferEmittedCount` (kind=audio) paired
    /// with [mediaJitterBufferDelaySec].
    public var mediaJitterBufferEmittedCount: Int64 {
        mediaRttLock.lock(); defer { mediaRttLock.unlock() }
        return _mediaJitterBufferEmittedCount
    }

    /// True while the sealed-audio DataChannel ("qaudion-audio") is open AND
    /// ICE is actually carrying, i.e. while voice is riding the P2P WebRTC
    /// leg rather than the WS relay. Same predicate `sendAudioFrameData`
    /// itself tests — the DC-open half via `QAudionPeerConnection
    /// .isAudioDataChannelOpen` and the ICE half via W-DCTXICEGATE — so
    /// "is RTT meaningful" and "where does audio actually go" can never
    /// disagree. (Before W-DCTXICEGATE this was DC-open only, which during
    /// an ICE outage reported a meaningful RTT for a leg delivering
    /// nothing.)
    public var isAudioDataChannelOpen: Bool {
        Self.iceIsCarrying(lastIceConnectionState) &&
            (peerConnection?.isAudioDataChannelOpen() ?? false)
    }

    private func setMediaRttMs(_ value: Double?) {
        mediaRttLock.lock()
        _mediaRttMs = value
        mediaRttLock.unlock()
    }

    /// IOS-E6 — set the raw cumulative jitter-buffer counters read from the
    /// same statistics report `pollMediaRttOnce` already fetches.
    private func setMediaJitterBuffer(delaySec: Double, emittedCount: Int64) {
        mediaRttLock.lock()
        _mediaJitterBufferDelaySec = delaySec
        _mediaJitterBufferEmittedCount = emittedCount
        mediaRttLock.unlock()
    }

    /// Sample the selected candidate pair's `currentRoundTripTime` once, AND
    /// (IOS-E6) the audio `inbound-rtp` jitter-buffer counters, off the SAME
    /// `getStats` report — one poll, two readings, no extra async round trip
    /// per tick. Async (libwebrtc delivers the stats report on its own
    /// thread); results land in [mediaRttMs] / [mediaJitterBufferDelaySec] /
    /// [mediaJitterBufferEmittedCount] for the next read. Cheap enough for
    /// the 1 Hz call sampler — one `getStats` per second is well under the
    /// video telemetry poll this file already runs at 3 s.
    /// W-MEDIADEADSRTP (2026-08-29) — latest audio `inbound-rtp.bytesReceived`
    /// seen by ``pollMediaRttOnce()``, or -1 when the report carries no audio
    /// `inbound-rtp` row (every call whose audio rides the sealed
    /// DataChannel/WS relay). Read by `CallService`'s media-dead watchdog as
    /// its RTP-side liveness source; growth between ticks proves bytes really
    /// arrived from the network, which NetEQ concealment cannot fake.
    public private(set) var audioRtpBytesReceived: Int64 = -1

    /// W-SRTPWIREMETRICS (2026-08-29) — latest audio `outbound-rtp.bytesSent`
    /// seen by ``pollMediaRttOnce()``, or -1 when the report carries no audio
    /// `outbound-rtp` row (every call whose audio rides the sealed
    /// DataChannel/WS relay, where the app's own wire counters are the real
    /// measurement). Paired with ``audioRtpBytesReceived`` to drive the call
    /// UI's throughput readout on a native-SRTP call.
    public private(set) var audioRtpBytesSent: Int64 = -1

    /// W-SRTPCOUNTERS (2026-08-29) — audio RTP packet counts from
    /// ``pollMediaRttOnce()``, or -1 when the report carries no such row.
    /// These are the native path's answer to "how many units of audio has
    /// this call actually protected and moved", which is what the crypto
    /// activity meter and the TX/RX diagnostic rows are really asking —
    /// their own frame counters only ever count sealed DataChannel frames.
    public private(set) var audioRtpPacketsReceived: Int64 = -1
    public private(set) var audioRtpPacketsSent: Int64 = -1

    public func pollMediaRttOnce() {
        guard let pc = peerConnection?.peerConnection else {
            setMediaRttMs(nil)
            setMediaJitterBuffer(delaySec: 0.0, emittedCount: 0)
            return
        }
        pc.statistics { [weak self] report in
            guard let self else { return }
            // Android's pair choice, verbatim: a succeeded pair that is
            // nominated or selected; failing that, the first succeeded pair.
            // The RTT is carried out of the loop rather than the stats object
            // itself so this reads no SDK type name beyond what
            // `pollVideoStatsOnce` above already relies on.
            var havePreferred = false
            var haveFallback = false
            var preferredRttSec: Double?
            var fallbackRttSec: Double?
            // IOS-E6 — mirrors PeerConnectionHolder.kt:5087-5088 exactly:
            // `inbound-rtp` row, kind=audio, `jitterBufferDelay` (Double
            // seconds) / `jitterBufferEmittedCount` (integer samples). Zero
            // by default (see the class-level IOS-E6 note): no such row
            // exists while audio rides the sealed DataChannel.
            var jbDelaySec = 0.0
            var jbEmitted: Int64 = 0
            // W-MEDIADEADSRTP (2026-08-29) — read the audio RX byte counter
            // off the SAME report (no extra round trip) so the media-dead
            // watchdog has the liveness source an `audio-srtp-v1` call
            // actually produces. -1 = no audio inbound-rtp row at all, which
            // is every call that stays on the sealed DataChannel/WS relay:
            // the watchdog treats that as "no opinion" and keeps using the
            // decode stamp exactly as before.
            var audioRxBytes: Int64 = -1
            // W-SRTPWIREMETRICS (2026-08-29) — the outbound twin, for the same
            // reason: on an `audio-srtp-v1` call the app's own wire counters
            // never move (nothing rides the sealed DataChannel), so the UI's
            // CODEC and FLUSSO columns read zero while real audio is flowing.
            var audioTxBytes: Int64 = -1
            // W-SRTPCOUNTERS (2026-08-29) — packet counts, the native-path
            // equivalent of the app's own sealed/opened FRAME counters. Every
            // remaining readout that counted frames (crypto activity meter,
            // the TX/RX diagnostic rows) reported zero on an `audio-srtp-v1`
            // call for the same reason the byte counters did: nothing rides
            // the sealed DataChannel there.
            var audioRxPackets: Int64 = -1
            var audioTxPackets: Int64 = -1
            for (_, s) in report.statistics {
                if s.type == "inbound-rtp", (s.values["kind"] as? String) == "audio" {
                    jbDelaySec = (s.values["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0.0
                    jbEmitted = (s.values["jitterBufferEmittedCount"] as? NSNumber)?.int64Value ?? 0
                    audioRxBytes = (s.values["bytesReceived"] as? NSNumber)?.int64Value ?? -1
                    audioRxPackets = (s.values["packetsReceived"] as? NSNumber)?.int64Value ?? -1
                }
                if s.type == "outbound-rtp", (s.values["kind"] as? String) == "audio" {
                    audioTxBytes = (s.values["bytesSent"] as? NSNumber)?.int64Value ?? -1
                    audioTxPackets = (s.values["packetsSent"] as? NSNumber)?.int64Value ?? -1
                }
                guard s.type == "candidate-pair",
                      (s.values["state"] as? String) == "succeeded" else { continue }
                let rttSec = (s.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
                if !haveFallback {
                    haveFallback = true
                    fallbackRttSec = rttSec
                }
                let nominated = (s.values["nominated"] as? NSNumber)?.boolValue ?? false
                let selected = (s.values["selected"] as? NSNumber)?.boolValue ?? false
                if (nominated || selected), !havePreferred {
                    havePreferred = true
                    preferredRttSec = rttSec
                }
            }
            // No succeeded pair ⇒ ICE never converged (or has failed) ⇒ there
            // is nothing to report. nil, not a carried-over previous value.
            let seconds = havePreferred ? preferredRttSec : fallbackRttSec
            self.setMediaRttMs(seconds.map { $0 * 1000.0 })
            // W-MEDIADEADSRTP — see `audioRxBytes` above.
            self.audioRtpBytesReceived = audioRxBytes
            // W-SRTPWIREMETRICS — see `audioTxBytes` above.
            self.audioRtpBytesSent = audioTxBytes
            // W-SRTPCOUNTERS — see `audioRxPackets` above.
            self.audioRtpPacketsReceived = audioRxPackets
            self.audioRtpPacketsSent = audioTxPackets
            self.setMediaJitterBuffer(delaySec: jbDelaySec, emittedCount: jbEmitted)
        }
    }

    // WIRE_SPEC §8.7 (INT-4a) — receiver-side decode-stall detector state,
    // driven off the 3s `pollVideoStatsOnce` cadence. `framesDecoded` is
    // monotonic; when it fails to advance across consecutive polls WHILE
    // bytes are still arriving, the decoder is stuck on a missing keyframe.
    // Two stalled polls (~6s, ≥ the §8.7 ~5s guidance) trigger the nudge.
    private var _lastFramesDecoded: Int = -1
    private var _lastBytesReceived: Int = -1
    private var _videoStallPolls: Int = 0
    /// Consecutive stalled polls before firing (3s cadence × 2 ≈ 6s ≥ ~5s).
    private let videoStallPollThreshold: Int = 2

    // W-ROUTECLAMP (2026-08-25) / W-BWCAP (2026-08-25) / W-BACKPRESSURE
    // (2026-08-25) / W-BWECOMPOSE (2026-08-27) — sender-side video bitrate
    // ceiling state. The effective ceiling is composed as
    //   effectiveMaxBps = routeTier.senderMaxBitrateBps × backpressureFactor
    // then intersected with the peer's reported VBWCAP via
    // `VideoBandwidthCap.clamp`, then intersected with the locally-measured
    // GoogCC BWE ceiling (`BweSenderCeiling`, best-practices audit item 1) —
    // mirrors Android's documented `cap = min(local, remote-requested,
    // relay)` composition (`AdaptiveQualityRuntime.localCapBps` doc,
    // PeerConnectionHolder.kt W-ROUTECLAMP), now with a real local-BWE term
    // instead of just the two static ceilings. Driven off
    // `resolveAndApplyRouteTier` (called once on ICE-connect AND every 3s
    // from `pollVideoStatsOnce` — see that method's doc for the
    // event-driven verification gap), `evaluateBackpressure` (called every
    // 3s from `pollVideoStatsOnce`), and `_bweSenderCeiling.observe` (fed
    // every 3s poll from the SAME `pollVideoStatsOnce` stats callback that
    // already read `availableOutgoingBitrate` for telemetry — see that read
    // site's own kdoc).
    /// W-ROUTETIERDWELL (2026-08-26) — was a bare `RouteTier`, committing a
    /// Direct↔Relay reclassification (and its 4.5x ceiling swing) on a
    /// single poll. Now routed through `RouteTierDwell`, which requires the
    /// same multi-poll dwell agreement `evaluateBackpressure` already
    /// applies to the CPU-backpressure knob before committing a transition —
    /// see that type's doc (Item 3, best-practices audit 2026-08-26).
    private var _routeTierDwell = RouteTierDwell()
    /// W-BWECOMPOSE (2026-08-27, best-practices audit item 1) — GoogCC's own
    /// `availableOutgoingBitrate` congestion estimate, composed as one more
    /// narrowing clamp in the same chain. See `BweSenderCeiling`'s own kdoc
    /// for the full rationale and the asymmetric-hysteresis shape it
    /// mirrors from `AbrController`/`evaluateBackpressure`.
    private var _bweSenderCeiling = BweSenderCeiling()
    /// W-VPNCALLGATE — de-dupe guard for `onActiveCandidatePairRemoteHost`,
    /// same reset-at-teardown discipline as `_routeTierDwell` right above.
    private var _lastReportedRemoteHost: String?
    private var _cpuLimitedPolls: Int = 0
    private var _healthyPolls: Int = 0
    private var _backpressureSteps: Int = 0
    /// Consecutive CPU-limited polls before stepping DOWN (3s cadence × 2 ≈ 6s).
    private let backpressureSustainPolls: Int = 2
    /// Consecutive healthy polls before stepping back UP (3s cadence × 3 ≈ 9s
    /// — slower to recover than to back off, same asymmetry as Android's
    /// AIMD bitrate controller and this file's own AbrController sibling).
    private let backpressureRecoverPolls: Int = 3
    /// Same multiplicative decrease factor as `AbrController.abrDecreaseFactor`
    /// (VideoConstants.abrDecreaseFactor = 0.7) — kept as its own literal here
    /// because that legacy-pipeline constant lives in the app target, not
    /// this engine module.
    private let backpressureStepFactor: Double = 0.7
    /// Caps the step ladder so a persistently CPU-bound device never
    /// spirals the ceiling to near-zero (0.7^3 ≈ 34% of the route ceiling).
    private let backpressureMaxSteps: Int = 3
    /// Fired when the route tier ceiling actually CHANGES (not every poll)
    /// with the new tier's bps ceiling — AppState wires this to a VBWCAP
    /// wire emit (`CallPiggyBack.serializeVideoBwCap`), mirroring
    /// `onVideoStallDetected`'s contract. May fire from the WebRTC stats
    /// callback thread — consumers hop to @MainActor themselves.
    public var onLocalVideoCapBpsChanged: ((Int) -> Void)?

    /// W-PLPBWTIER (2026-08-25) — fired the same instant `_routeTier`
    /// actually changes (same guard as `onLocalVideoCapBpsChanged` right
    /// above, fired from `resolveAndApplyRouteTier`), carrying the raw
    /// tier rather than a derived bps number. AppState wires this to
    /// `CallService.updateRouteTier`, which feeds `PlpPolicy`'s route-
    /// tier-aware floor — see that overload's kdoc. Unlike
    /// `onLocalVideoCapBpsChanged` this is NOT video-gated: the resolve
    /// call fires on every call's ICE `.connected`/`.completed` (see the
    /// switch above), audio-only calls included — only the PERIODIC
    /// re-poll (inside `pollVideoStatsOnce`) is video-telemetry-gated, so
    /// an audio-only call still gets one real classification near call
    /// start, just not a live-updating one. May fire from the WebRTC
    /// stats callback thread — consumers hop to @MainActor themselves.
    public var onRouteTierChanged: ((RouteTier) -> Void)?

    /// W-BACKPRESSURE-RES (2026-08-26) — fired whenever `_backpressureSteps`
    /// actually changes (both the engage-side step-down and the recover-
    /// side step-up branches in `evaluateBackpressure`), carrying the new
    /// step count (`0...backpressureMaxSteps`). Before this, sustained CPU
    /// overuse only tightened the RTP sender's bitrate CEILING
    /// (`applyComposedVideoSenderClamp`) — the encoder kept doing the same
    /// per-frame work at the same source resolution/fps, just told to spend
    /// fewer bits on it. AppState wires this to `AbrController
    /// .applyCpuBackpressure(steps:)`, which composes it with that
    /// controller's own network-driven resolution/fps ladder (whichever
    /// wants the LOWER quality wins) and, when it's the binding constraint,
    /// actually calls `VideoCallPipeline.setEncoderResolution`/
    /// `setEncoderFps` — real work reduction, not just a bitrate number.
    /// This controller cannot make that call itself: `VideoCallPipeline`
    /// lives in the QAudionApp target, which this QAudionEngine-target
    /// class cannot import (same layering reason `onLocalVideoCapBpsChanged`
    /// is a callback rather than a direct call). May fire from the WebRTC
    /// stats callback thread — consumers hop to @MainActor themselves.
    public var onCpuBackpressureStepsChanged: ((Int) -> Void)?

    /// R-4 (vkey-v1 / sovereign-only) — injectable policy hook consulted
    /// when a remote VIDEO track arrives. When it returns `true` the
    /// controller REJECTS the incoming video: it disables the track and
    /// does NOT forward `onRemoteVideoTrack`, so nothing renders. The
    /// engine module cannot read the app-layer `CallsGate` directly, so
    /// the app wires this to `{ CallsGate.shouldRejectIncomingVideo }`
    /// (see `AppState`). Defaults to allowing video (`{ false }`) so
    /// engine-only / test targets are unaffected. Mirrors Android
    /// rejecting incoming video under the sovereign-only policy.
    public var shouldRejectIncomingVideo: () -> Bool = { false }

    /// R-4 (vkey-v1 / sovereign-only) — injectable filter applied to the
    /// capability list advertised on EVERY outgoing `call_offer` AND
    /// `call_answer` from this controller. The engine module cannot read
    /// the app-layer `CallsGate`, so the app wires this to
    /// `{ CallsGate.filterAdvertisedCapabilities($0) }` (see `AppState`),
    /// which strips `vkey-v1` when sovereign-only is on. Defaults to the
    /// identity transform so engine-only / test targets advertise the
    /// full local set. Applied to both the WebRTC-rail offer and the
    /// answer so a sovereign-only user who ANSWERS also strips `vkey-v1`,
    /// not just one who originates (DEFECT 2 fix). Read live (not
    /// captured) so a mid-session policy toggle takes effect on the next
    /// advertised envelope.
    public var advertisedCapabilitiesFilter: ([String]) -> [String] = { $0 }

    /// M-15 — call-session identifier to bind the HKDF-derived PQC key.
    /// Set this BEFORE (or atomically with) `pqcSessionKey` so the sealer
    /// uses the bound info string `"q-audion-srtp-master-v1:<pqcCallId>"`.
    /// Both parties must use the same callId (e.g. the CallKit UUID string).
    /// ⚠️ Requires coordinated update on Android + Desktop before deployment.
    public var pqcCallId: String = ""

    /// W383: optional PQC session key for the inner SRTP layer.
    /// When set BEFORE startOutgoingCall / acceptIncomingCall, the
    /// controller automatically installs PqcFrameEncryptor /
    /// PqcFrameDecryptor on every sender + receiver via
    /// `QAudionPeerConnection.installPqcSealer` (W382). Mid-call
    /// updates re-install the sealer on next set.
    /// W-KEYSLOTROTATE — the call-crypto epoch for the CURRENT
    /// `pqcSessionKey` (0 = first real key, +1 per completed rekey).
    /// Set by AppState BEFORE `pqcSessionKey` at every delivery site; the
    /// slot handed to the FrameCryptors is `epoch % 16`, matching
    /// Android's ring exactly.
    public var pqcSessionKeyEpoch: Int32 = 0

    public var pqcSessionKey: Data? {
        didSet {
            applyPqcSealerIfPossible()
            // W539 — when the PQC key arrives (or rotates), retry the
            // video pipeline pick. ensureVideoSealer needs BOTH the
            // peer's negotiated caps AND a 32-byte key to install the
            // LiveKit cryptor; whichever arrives last triggers the
            // install via this didSet or acceptPeerCapabilities below.
            _ = ensureVideoSealerInternal()
            // IOS-C4b — same "whichever arrives last" pattern for the
            // native audio-srtp path: install/rekey the moment BOTH the
            // peer's audioSrtpV1 negotiation AND a fresh key are available.
            installAudioSrtpIfPossible()
        }
    }

    /// `vkey-v1` — optional contact PSK (32 bytes) for the K_video HKDF
    /// salt. iOS has NO SovereignKeyVault today so this is always `nil`,
    /// which makes `deriveVideoKey` fall back to the fixed
    /// `Q-AUDION-PHONE-VIDEO-SALT-V1` salt — byte-identical to Android's
    /// PSK-absent path. The property exists so a future SovereignKeyVault
    /// landing can wire the per-contact PSK without touching the
    /// derivation call site. When set it MUST be exactly 32 bytes.
    public var videoContactPsk: Data?

    /// `vkey-v1` — true once the active video pipeline was keyed off the
    /// phone-level K_video (peer advertised `vkey-v1`). Used by the
    /// dual-trust UI indicator ("video is phone-level vs audio sovereign").
    /// `false` means video either ran legacy/DTLS-only or shared the
    /// audio session key (pre-vkey-v1 peer). Mirrors Android
    /// `videoKeyIsPhoneLevel`.
    public private(set) var videoKeyIsPhoneLevel: Bool = false

    /// W411 — optional override for the ICE server list. When set
    /// (typically by AppState reading TransportGate.preferredTurnUrl),
    /// the controller skips the relay-pool fetch and uses ONLY these
    /// servers. Useful for self-hosted TURN deployments + QA. Set
    /// before startOutgoingCall / acceptIncomingCall.
    public var iceServerOverride: [RTCIceServer]?

    /// W411 — optional override for the ICE transport policy. When
    /// `.relay` is forced, WebRTC bypasses host candidates and
    /// requires all media to flow through the relay. Maps from
    /// TransportGate.preferredMode: turn/relay → .relay,
    /// otherwise default `.all`.
    public var iceTransportPolicyOverride: RTCIceTransportPolicy?

    /// SFrame video sealer factory — DI seam retained for backwards
    /// compatibility with AppState wiring. As of W539 it is NO LONGER
    /// consulted by the default video pipeline pick: cross-platform
    /// 1:1 calls install ``LiveKitVideoFrameCryptor`` instead so iOS
    /// interoperates with Desktop and Android.
    ///
    /// Setting this is harmless — it is simply unused by
    /// ``ensureVideoSealer(pqcSessionKeyProvider:)``. The property is
    /// kept so existing AppState DI code continues to compile.
    public var sframeVideoSealerFactory: ((@escaping () -> Data) -> SFrameVideoSealer)?

    /// JWT bearer token forwarded to the WSS-TURN WebSocket handshake.
    /// Must be set (from AppState) before `startOutgoingCall` /
    /// `acceptIncomingCall` so the server-side auth check on
    /// `/api/v1/turn-ws` succeeds. Mirrors Desktop `WssTurnBridge.ts`
    /// `accessToken` option and Android's `@Named("ws")` OkHttpClient
    /// interceptor that auto-attaches the Bearer token.
    public var accessToken: String?

    /// Discriminator for the active video pipeline on this call.
    /// Resolved at video setup time by ``ensureVideoSealer()`` based
    /// on the peer's negotiated capabilities — once set it stays
    /// fixed for the call's lifetime (matches Android's "construct
    /// pipeline once" rule, NVIDIA Llama-3.3-70b reviewed).
    public enum VideoCallSealer {
        /// Legacy iOS video path — frames flow through plain WebRTC
        /// SRTP only (no E2EE on video). Used when the peer didn't
        /// advertise any compatible video sealer cap.
        case legacy
        /// SFrame v1 path — Q-Audion custom envelope, kept for future
        /// iOS-only group-call work or compile-time-flagged
        /// experimentation. NOT selected by default — the cross-platform
        /// 1:1 path uses ``livekit(_:)`` so iOS interoperates with
        /// Desktop and Android.
        case sframe(SFrameVideoSealer)
        /// W539 — LiveKit / libwebrtc native FrameCryptor envelope.
        /// This is the format Desktop (`LiveKitFrameCryptor.ts`) and
        /// Android (libwebrtc native `FrameCryptor`) actually emit and
        /// consume on 1:1 video calls; we MUST use it on iOS too so
        /// cross-platform calls render. AES-256-GCM (WS-7; was AES-128 —
        /// matches Android's AES-256-patched native FrameCryptor),
        /// HKDF-SHA256 (empty salt, 128-byte zero info, L=32), keyIndex=0.
        case livekit(LiveKitVideoFrameCryptor)
        /// Native libwebrtc RTCFrameCryptor (insertable streams), attached to
        /// the RTP video sender/receiver — the DEFAULT cross-platform 1:1 path
        /// on the webrtc-sdk binary. Replaces the codec-layer `.livekit` path
        /// (which the H265 RTP packetizer broke). Encrypts post-packetization so
        /// it is codec-agnostic (H265-safe) and byte-compatible with Android's
        /// native FrameCryptor. The cryptor objects live on `QAudionPeerConnection`.
        case native
    }
    public private(set) var videoSealer: VideoCallSealer?

    /// When `true`, `startOutgoingCall` / `acceptIncomingCall` add the
    /// local video track to the SDP (so the m=video section is present)
    /// but do NOT start `RTCCameraVideoCapturer`. Used when AppState's
    /// `VideoCallPipeline` already owns the camera and will bridge its
    /// captured frames into the `RTCVideoSource` — avoids the dual
    /// `AVCaptureSession` conflict on outgoing video calls.
    /// Set BEFORE `startOutgoingCall` / `acceptIncomingCall`.
    public var useExternalVideoSource: Bool = false

    /// W-SCREENPROFILE (2026-08-25) — true while the local video track
    /// carries screen-share content (ReplayKit) rather than camera frames.
    /// AppState sets this BEFORE `upgradeToVideo()` in `startScreenShare()`
    /// (mirroring how it already sets `useExternalVideoSource` there) so a
    /// freshly-created video source is flagged `isScreencast` at
    /// `QAudionPeerConnection.addLocalVideoTrack` — see that method's kdoc.
    /// The `didSet` below ALSO applies (or clears) the sender-level
    /// `degradationPreference` override directly, independent of whether a
    /// fresh source was created this call: it is the only fix that reaches
    /// the case where a camera video track already existed (an active
    /// video call that then shares its screen) and
    /// `addLocalVideoTrack`'s `localVideoTrack == nil` guard makes the
    /// `isScreencast` source flag a no-op for that reused source.
    public var isScreenSharing: Bool = false {
        didSet {
            guard isScreenSharing != oldValue else { return }
            peerConnection?.setVideoDegradationPreference(isScreenSharing ? .maintainResolution : nil)
        }
    }

    private let callingApi: CallingApi
    private let relayProvider: RelayCredentialsProvider?
    private var peerConnection: QAudionPeerConnection?
    private var wssTurnBridge: WssTurnBridge?
    private var recipientId: String?

    // MARK: - W-SILENTPATHDEATH / W-OFFERGLARE / W-RESTARTOFFERPARK
    // (2026-08-25) — ICE-restart recovery machine. Parity plan Fase E3,
    // ported from Android's `PeerConnectionHolder.restartIce` /
    // `.handleRemoteOffer` + `CallController.notifyNetworkChanged` /
    // `.iceFailedRecoveryJob` (qaudion-android-new). See
    // `RestartIceDecisions` for the pure decision logic these methods
    // drive.

    /// The ORIGINAL role of this call, fixed for its whole lifetime —
    /// `true` set by `startOutgoingCall`, `false` by `acceptIncomingCall`.
    /// This is iOS's equivalent of Android's `activeAsInitiator`: the
    /// restart-offer glare tiebreak in `applyRemoteRestartOffer` is keyed
    /// to this, never to the mutual-dial call-id comparison `GlareDecisions`
    /// uses (that mechanism doesn't apply to a same-call-id restart race).
    private(set) var isInitiator: Bool = false

    /// W-SILENTPATHDEATH — call-scoped path monitor. Deliberately owned by
    /// the controller (not the shared `BCryptoWebSocketClient` one, which
    /// only ever retunes WS ping cadence — see the item's kdoc in the
    /// parity plan) so the call layer gets its OWN OS network-change
    /// signal, independent of and un-coupled from the WS client's internal
    /// reconnect/debounce policy. Started in `startOutgoingCall`/
    /// `acceptIncomingCall`, stopped in `closeSynchronously()`.
    private var restartPathMonitor: NWPathMonitor?
    private let restartPathMonitorQueue = DispatchQueue(label: "qaudion.webrtc.restart-path-monitor")

    /// W-SILENTPATHDEATH — timestamp of the last EXTERNAL (OS-driven)
    /// network-change signal, excluding this controller's own recovery
    /// watchdog re-entrant calls. `nil` (never seen one this call) behaves
    /// like Android's zero-initialized `lastExternalNetworkChangeAtMs`
    /// default — see `RestartIceDecisions.selfRepairWindowMs`.
    private var lastExternalNetworkChangeAt: Date?

    /// W-PROACTIVEHANDOFF (2026-08-26) — the dominant interface type as of
    /// the LAST `armRestartPathMonitor` callback, so that handler can tell
    /// "the active interface actually changed" (wifi<->cellular<->wired,
    /// a real handover) apart from "some other path property changed on
    /// the SAME interface" (IP renewal, DNS change, etc. — `NWPathMonitor`
    /// fires its handler for any of these, not just interface swaps).
    /// `nil` until the first callback — deliberately not treated as a
    /// "change" (see `armRestartPathMonitor`'s kdoc: the very first
    /// callback on monitor start always looks like a transition from
    /// nothing and must not trigger a restart on a call that hasn't even
    /// connected yet).
    private var lastActiveInterfaceType: NWInterface.InterfaceType?

    /// Debounce guard mirroring Android's `lastIceRestartAtMs` +
    /// `ICE_RESTART_DEBOUNCE_MS` — a flapping interface must not spam
    /// fresh CallOffer frames.
    private var lastIceRestartAt: Date?
    /// Independent-review fix (nim.ps1 security pass, W-PROACTIVEHANDOFF/
    /// W-RESPONDERRESTART): `restartIce` now has THREE independent call
    /// sites that can race each other (the reactive ICE-failure watchdog,
    /// the new interface-change trigger, and any future caller) — before
    /// this lock, two concurrent invocations could both read
    /// `lastIceRestartAt` as "old enough" before either wrote a fresh
    /// timestamp, defeating the debounce exactly the flapping-interface
    /// case it exists for. Held ONLY for the synchronous
    /// check-then-set below, released BEFORE the `await pc.createOffer`
    /// that follows — same discipline this file already uses for
    /// `answerLock`/`shutdownLock` (see those properties' own kdoc): a
    /// lock spanning an `await` is a bug class this codebase deliberately
    /// avoids, not introduces.
    private let restartIceDebounceLock = NSLock()

    /// The recovery watchdog: armed the moment ICE first enters a bad
    /// state, cancelled the moment it genuinely recovers (`.connected`/
    /// `.completed`) or the call tears down. Mirrors Android's
    /// `iceFailedRecoveryJob`.
    private var iceRecoveryWatchdogTask: Task<Void, Never>?

    /// Latest ICE connection state, written once from the single
    /// `didChangeIceConnectionState` delegate callback — see that
    /// method's kdoc. Read by the watchdog to re-check "still bad?"
    /// without touching WebRTC objects from its own Task.
    private var lastIceConnectionState: RTCIceConnectionState = .new

    // ── IOS-C4b / W-SRTPFALLBACK (2026-08-26) ────────────────────────────

    /// Monotonic ms timestamp the CURRENT bad-ICE streak started, or `nil`
    /// when ICE is not currently bad. Feeds `SrtpFallbackDecisions
    /// .shouldEngageFallback`'s debounce. Reset to `nil` the instant ICE
    /// recovers.
    private var iceBadSinceMs: Int64?
    /// True once `onAudioSrtpFallbackEngage` has fired for the CURRENT
    /// outage and not yet recovered — the "never double-engage" guard
    /// `SrtpFallbackDecisions` checks.
    private var srtpFallbackEngaged: Bool = false
    /// Debounce task for the fallback engage decision. Cancelled on genuine
    /// ICE recovery (mirrors `iceRecoveryWatchdogTask`'s own cancel-on-heal
    /// discipline) so a self-healed blip never fires the engage callback
    /// after the fact.
    private var srtpFallbackTask: Task<Void, Never>?

    // ── W-VIDEOSENDGATE (2026-08-26) ──────────────────────────────────────
    //
    // Same shape as the audio pair above, inverted: audio debounces
    // ENGAGING a second capture path (the risky edge — opening a redundant
    // path). Here the risky edge is the OPPOSITE action — SKIPPING the
    // always-on WS-relay video send — so the debounce guards that instead,
    // and falling back to the relay (the safe direction) stays instant.
    // See `AppState`'s `onOutboundFragment` wiring and
    // reference_transport_fallback_audit_2026_08_26.md.

    /// Monotonic ms timestamp the CURRENT good-ICE streak started
    /// (`.connected`/`.completed`), or `nil` when ICE is not currently in a
    /// confirmed-good state. Feeds `isVideoSendConfirmedHealthy`'s debounce.
    /// Reset to `nil` the instant ICE leaves `.connected`/`.completed` —
    /// deliberately ungated, so a caller reading this after a bad-ICE edge
    /// falls back to the WS-relay safety net on the very next frame.
    private var iceGoodSinceMs: Int64?

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// `true` once ICE has connected at least once THIS call. Gates the
    /// recovery watchdog to MID-CALL path death (parity plan Fase E3's
    /// actual target — a handoff after the call is already up) rather
    /// than also taking over INITIAL connection-failure handling, which
    /// has its own existing path (the call never reaches `.connected` at
    /// all, and AppState/CallKit already surface that as a failed call).
    private var hasEverConnectedIce: Bool = false

    /// The most recently APPLIED remote restart-offer SDP — mirrors
    /// Android's `lastAppliedRemoteSdp` duplicate guard at the top of
    /// `handleRemoteOffer`. A retried/duplicated restart-offer resend
    /// (this controller's own park logic, or the peer's) must not be
    /// re-applied.
    private var lastAppliedRemoteRestartSdp: String?

    /// Fired once per restart ATTEMPT (offer creation kicked off, not
    /// necessarily sent) — AppState uses this to extend the pre-existing
    /// W-ICEGRACE teardown countdown so a live restart round-trip is not
    /// preempted by the short self-heal-only grace that timer was tuned
    /// for. See `AppState.handleIceTermination`'s kdoc for the full
    /// reasoning: without this, iOS's existing 3s ICE-disconnect grace
    /// would `endCall()` the call before any restart offer/answer round
    /// trip (which, across a real handoff, routinely takes several
    /// seconds) could possibly land — making this entire machine
    /// decorative in practice.
    public var onRestartAttemptStarted: (() -> Void)?
    #if os(iOS)
    private var localVideoCapturer: RTCCameraVideoCapturer?
    /// Non-nil when useExternalVideoSource == true. AppState wires
    /// VideoCallPipeline.onCapturedPixelBuffer → push() after
    /// startOutgoingCall / acceptIncomingCall returns.
    public private(set) var webrtcPixelBufferCapturer: WebRTCPixelBufferCapturer?
    #endif

    /// W418 — idempotency guard for `handleRemoteAnswer`. The WS layer
    /// has been observed dispatching `call_answer` twice in rapid
    /// succession (timestamp-identical), spawning two `Task { ... }`
    /// blocks that race into `setRemoteDescription`. Both read the
    /// underlying signaling state as `.haveLocalOffer` BEFORE either
    /// suspends; both call `setRemoteDescription`; the first succeeds
    /// (state → .stable), the second fails with `Code=-1 "wrong state:
    /// stable"` and surfaces as a visible error to the user.
    ///
    /// Fix: a synchronous flag set BEFORE the await suspension closes
    /// the race window — when Task 2 runs the early-return branch, it
    /// has already missed the window where it could have submitted a
    /// duplicate `setRemoteDescription`. NSLock-protected for safety
    /// because the controller is `@unchecked Sendable` (NOT @MainActor).
    private let answerLock = NSLock()
    private var _hasAppliedRemoteAnswer = false
    private var hasAppliedRemoteAnswer: Bool {
        get { answerLock.lock(); defer { answerLock.unlock() }; return _hasAppliedRemoteAnswer }
        set { answerLock.lock(); _hasAppliedRemoteAnswer = newValue; answerLock.unlock() }
    }
    /// Atomic test-and-set: returns `true` if the caller "won" the
    /// race and should proceed; returns `false` if another caller has
    /// already started the apply. Both branches release the lock
    /// before returning.
    private func tryAcquireAnswerSlot() -> Bool {
        answerLock.lock()
        defer { answerLock.unlock() }
        if _hasAppliedRemoteAnswer { return false }
        _hasAppliedRemoteAnswer = true
        return true
    }

    /// Bug-C guard (async-construction race — same class of bug already
    /// fixed on Desktop; see `test/calling/callLaunchAndUpgradeGuards.spec.ts`
    /// "Bug C"). Set synchronously as the first line of `closeSynchronously()`
    /// (and therefore also `hangup()` / `sendHangupAndClose()`, which both
    /// funnel through it), so a `startOutgoingCall` / `acceptIncomingCall` /
    /// `acceptUpgradeOfferBuildingPeerConnection` still suspended on
    /// `fetchIceServers()` can detect the teardown on resume and abort
    /// instead of installing an orphaned `RTCPeerConnection` — one that
    /// keeps sending ICE candidates via a `recipientId` nobody ever clears.
    /// NSLock-protected for the same reason as [answerLock]: the controller
    /// is `@unchecked Sendable`, not `@MainActor`.
    private let shutdownLock = NSLock()
    private var _intentionalShutdown = false
    private var intentionalShutdown: Bool {
        get { shutdownLock.lock(); defer { shutdownLock.unlock() }; return _intentionalShutdown }
        set { shutdownLock.lock(); _intentionalShutdown = newValue; shutdownLock.unlock() }
    }

    public init(callingApi: CallingApi, relayProvider: RelayCredentialsProvider? = nil) {
        self.callingApi = callingApi
        self.relayProvider = relayProvider
    }

    // MARK: - Outgoing

    /// Build the peer connection, generate an SDP offer, and ship via
    /// `CallingApi.sendCallOffer`. Returns once the offer has been sent;
    /// the call is connected later when the peer's answer arrives via
    /// `handleRemoteAnswer(sdp:)`.
    ///
    /// `callerDisplay` (optional) — pure-digits public phone number the
    /// caller wants the callee's CallKit caller-id to show. When nil,
    /// the field is omitted on the wire and the server fills it with the
    /// caller's internal extension. See `LocalCallerIdSettings`.
    /// W462-iOS ghost-call fix: when a `callId` is supplied the WebRTC
    /// offer reuses the SAME server call-session UUID that the PQC path
    /// already registered via `sendCallOfferWithId`. This prevents the
    /// server from creating a second call session and the callee from
    /// receiving a duplicate `call_incoming` that confuses the state
    /// machine. Defaults to nil (mints a fresh UUID) for backwards
    /// compatibility with callers that have no PQC session running.
    public func startOutgoingCall(
        recipientId: String,
        audioOnly: Bool = true,
        callerDisplay: String? = nil,
        callId: String? = nil
    ) async throws {
        guard state == .idle || state == .disconnected else {
            throw ControllerError.wrongState(String(describing: state))
        }
        hasAppliedRemoteAnswer = false   // W418 — fresh call, reset idempotency flag
        intentionalShutdown = false      // Bug-C guard — fresh call, clear any prior teardown latch
        state = .outgoingOffering
        self.recipientId = recipientId
        // W-SILENTPATHDEATH — this device placed the call: the original
        // initiator, fixed for the rest of the call's life.
        isInitiator = true
        armRestartPathMonitor()

        let iceServers = await fetchIceServers()
        // Bug-C guard: a hangup/closeSynchronously racing the fetchIceServers()
        // suspension must not go on to construct a PeerConnection nobody will
        // ever close.
        guard !intentionalShutdown else {
            throw ControllerError.wrongState("intentional-shutdown-raced-setup")
        }
        let factory = QAudionPeerConnectionFactory.shared.createFactory(sealerProvider: { [weak self] in
            // W539 — surface either SFrame or LiveKit sealer to the codec
            // decorator. The LiveKit path is the cross-platform default
            // (Desktop / Android emit this wire format); SFrame is kept
            // for potential iOS-only future paths.
            switch self?.videoSealer {
            case .sframe(let s):  return .sframe(s)
            case .livekit(let c): return .livekit(c)
            default:              return nil
            }
        })
        let pc = QAudionPeerConnection(
            factory: factory,
            iceServers: iceServers,
            iceTransportPolicy: iceTransportPolicyOverride ?? .all,
            delegate: self)
        // Bug-C guard: same race, closed a moment later — pc was just built
        // synchronously (no further suspension since the check above), but a
        // teardown could still have landed on another thread. Dispose rather
        // than orphan it.
        guard !intentionalShutdown else {
            pc.close()
            throw ControllerError.wrongState("intentional-shutdown-raced-setup")
        }
        peerConnection = pc
        pc.addLocalAudioTrack()
        // W-DCAUDIO — wire inbound DataChannel audio to the app, then create the
        // outbound sealed-audio DataChannel (CALLER side, BEFORE createOffer so
        // the SDP carries the m=application audio section). Voice rides this DC
        // (P2P) with the WS relay as fallback; there is no m=audio SRTP track.
        pc.onAudioDataChannelFrame = { [weak self] data in self?.onAudioDataChannelFrame?(data) }
        // W-DCMUX — wire the state hook BEFORE createAudioDataChannel(), which
        // fires it synchronously on success. Wiring it after would drop the
        // creation event, which is the one that proves the caller even got as
        // far as putting an m=application section in the offer.
        pc.onAudioDataChannelStateChange = { [weak self] st in self?.onAudioDataChannelStateChange?(st) }
        pc.createAudioDataChannel()
        if !audioOnly {
            // Add the local camera track before creating the offer so the
            // SDP m=video section is populated. Mirrors Android
            // VideoTrackManager called on the originator path.
            if let videoSource = pc.addLocalVideoTrack() {
                startCameraCapture(for: videoSource)
            }
        }
        // W383: install PQC sealer if a session key was set BEFORE
        // the call started. (Late arrivals via the
        // `pqcSessionKey` didSet also call this, but that path
        // requires the peerConnection already exist — we set both
        // up in the same task here so the order is safe.)
        applyPqcSealerIfPossible()

        let sdp: String = try await withCheckedThrowingContinuation { cont in
            pc.createOffer(audioOnly: audioOnly) { result in
                switch result {
                case .success(let sdp): cont.resume(returning: sdp)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
        // Commit 540b79c0 parity — advertise the local SFrame caps on
        // every outgoing call_offer. Pass hasVideo so the wire envelope
        // sets call_type:"video" and has_video:true for video calls,
        // matching Android WsCodec.kt CallOffer serialization.
        // W462-iOS: if a canonical callId was supplied (from the PQC
        // path), reuse it via sendCallOfferWithId so only ONE server
        // call session is created. Without this, the WebRTC rail minted
        // its own UUID and the callee received two call_incoming events.
        let callHasVideo: Bool = !audioOnly
        if let cid = callId {
            try await callingApi.sendCallOfferWithId(
                callId: cid,
                recipientId: recipientId,
                sdp: sdp,
                // R-4: same sovereign-only strip on the WebRTC-rail offer.
                capabilities: advertisedCapabilitiesFilter(CallCapabilities.localCaps()),
                callerDisplay: callerDisplay,
                hasVideo: callHasVideo
            )
        } else {
            try await callingApi.sendCallOffer(
                recipientId: recipientId,
                sdp: sdp,
                capabilities: advertisedCapabilitiesFilter(CallCapabilities.localCaps()),
                callerDisplay: callerDisplay,
                hasVideo: callHasVideo
            )
        }
        state = .connecting
    }

    /// Apply the remote answer SDP that arrived on `call_answer`.
    /// Idempotent: a duplicate `call_answer` dispatch (observed in
    /// production via the W417 LiveLogStreamer chunks) is silently
    /// swallowed instead of throwing the misleading "wrong state:
    /// stable" error. See `tryAcquireAnswerSlot()` doc above.
    public func handleRemoteAnswer(sdp: String) async throws {
        guard let pc = peerConnection else {
            throw ControllerError.noPeerConnection
        }
        // Synchronous test-and-set BEFORE any await — closes the race
        // window between concurrent Task{} blocks dispatched by a
        // duplicate WS event.
        guard tryAcquireAnswerSlot() else {
            // Another concurrent call already started the apply; this
            // is a duplicate call_answer dispatch. No-op.
            return
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                pc.setRemoteAnswer(sdp: sdp) { err in
                    if let err = err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        } catch {
            // Apply failed — release the slot so a subsequent retry
            // with valid SDP (different WS event) can succeed.
            hasAppliedRemoteAnswer = false
            throw error
        }
        // W-ICELATEQUEUE — caller side: the peer's candidates raced this
        // answer over the WS; hand the queued ones to ICE now.
        drainPendingRemoteIce()
    }

    // MARK: - Incoming

    public func acceptIncomingCall(callerId: String, offerSdp: String, audioOnly: Bool = true,
                                    peerCapabilities: [String]? = nil) async throws {
        guard state == .idle || state == .disconnected else {
            throw ControllerError.wrongState(String(describing: state))
        }
        hasAppliedRemoteAnswer = false   // W418 — fresh call, reset idempotency flag
        intentionalShutdown = false      // Bug-C guard — fresh call, clear any prior teardown latch
        pendingIceLock.withLock { remoteDescriptionApplied = false }  // W-ICELATEQUEUE
        state = .incomingAnswering
        self.recipientId = callerId
        // W-SILENTPATHDEATH — this device answered: the original
        // responder, fixed for the rest of the call's life.
        isInitiator = false
        armRestartPathMonitor()

        let iceServers = await fetchIceServers()
        // Bug-C guard: see startOutgoingCall's identical check.
        guard !intentionalShutdown else {
            throw ControllerError.wrongState("intentional-shutdown-raced-setup")
        }
        let factory = QAudionPeerConnectionFactory.shared.createFactory(sealerProvider: { [weak self] in
            // W539 — surface either SFrame or LiveKit sealer to the codec
            // decorator. The LiveKit path is the cross-platform default
            // (Desktop / Android emit this wire format); SFrame is kept
            // for potential iOS-only future paths.
            switch self?.videoSealer {
            case .sframe(let s):  return .sframe(s)
            case .livekit(let c): return .livekit(c)
            default:              return nil
            }
        })
        let pc = QAudionPeerConnection(
            factory: factory,
            iceServers: iceServers,
            iceTransportPolicy: iceTransportPolicyOverride ?? .all,
            delegate: self)
        // Bug-C guard: see startOutgoingCall's identical check.
        guard !intentionalShutdown else {
            pc.close()
            throw ControllerError.wrongState("intentional-shutdown-raced-setup")
        }
        peerConnection = pc
        // IOS-C4b BUGFIX (2026-08-26) — apply the peer's capabilities BEFORE
        // `setRemoteOffer` below, mirroring the caller-side fix already in
        // place at `AppState.handleIncomingWebRtcAnswer` ("Cache them before
        // applying the SDP so the pipeline pick has the right negotiation
        // state"). Root-caused from a real cross-platform call
        // (d7e7ece6..., Android caller -> iOS callee, 2026-08-26): the
        // caller previously applied `acceptPeerCapabilities` only AFTER this
        // whole function returned (AppState.swift, right after the
        // `acceptIncomingCall` await). `setRemoteOffer` is what fires
        // `didAdd rtpReceiver` for the inbound m=audio track, and
        // `QAudionPeerConnection`'s W574d hardening branch reads
        // `peerCallCapabilities` AT THAT EXACT MOMENT to decide whether the
        // inbound SRTP audio track is the real call audio (audioSrtpV1) or
        // must be disabled (`audio.isEnabled = false`, permanently — nothing
        // downstream ever re-enables it). With capabilities applied too
        // late, `peerCallCapabilities` was always nil at that moment, so
        // every incoming call answered by THIS device took the disable
        // branch even when both peers had negotiated audioSrtpV1 —
        // confirmed live: mic capture (TX, driven by the separately-timed
        // `activateNativeAudioSrtp`/`installLiveMediaKeys` path) worked, the
        // peer heard this device fine, but this device heard nothing at all
        // from the peer. Applying capabilities here, before `setRemoteOffer`,
        // closes the same race the caller path already closed.
        pc.acceptPeerCapabilities(peerCapabilities)
        pc.addLocalAudioTrack()
        // W-DCAUDIO — CALLEE side: wire inbound DataChannel audio to the app. The
        // caller created the sealed-audio DataChannel; we receive it via the PC's
        // `didOpen` delegate. No m=audio SRTP track is added.
        pc.onAudioDataChannelFrame = { [weak self] data in self?.onAudioDataChannelFrame?(data) }
        // W-DCMUX — on this side the hook's first firing IS the `didOpen`
        // receipt: it is how the callee proves the channel arrived at all.
        pc.onAudioDataChannelStateChange = { [weak self] st in self?.onAudioDataChannelStateChange?(st) }
        if !audioOnly {
            // Add the local camera track before creating the answer so the
            // SDP m=video section is populated. Mirrors Android
            // PeerConnectionHolder.addVideoTrack() called on the responder path.
            if let videoSource = pc.addLocalVideoTrack() {
                startCameraCapture(for: videoSource)
            }
        }
        // W383: install PQC sealer if a session key was set BEFORE
        // the call started. (Late arrivals via the
        // `pqcSessionKey` didSet also call this, but that path
        // requires the peerConnection already exist — we set both
        // up in the same task here so the order is safe.)
        applyPqcSealerIfPossible()

        // 1. Apply remote offer.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteOffer(sdp: offerSdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
        // W-ICELATEQUEUE — responder side: the caller's candidates arrived
        // with (or before) the offer and were queued; ICE can take them now.
        drainPendingRemoteIce()
        // 2. Build local answer — mirror the peer's video intent.
        let answerSdp: String = try await withCheckedThrowingContinuation { cont in
            pc.createAnswer(hasVideo: !audioOnly) { result in
                switch result {
                case .success(let sdp): cont.resume(returning: sdp)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
        // 3. Ship answer back. Commit 540b79c0 parity — advertise the
        //    local SFrame caps on every outgoing call_answer. Echo
        //    hasVideo so Android WsCodec.kt knows the callee's camera
        //    state and doesn't mute remote video on its side.
        try await callingApi.sendCallAnswer(
            recipientId: callerId,
            sdp: answerSdp,
            // R-4 (DEFECT 2): strip `vkey-v1` when sovereign-only is on so
            // a sovereign user who ANSWERS also refuses phone-level video.
            capabilities: advertisedCapabilitiesFilter(CallCapabilities.localCaps()),
            hasVideo: !audioOnly
        )
        state = .connecting
    }

    /// W-VIDUP — responder side with NO pre-existing PeerConnection.
    ///
    /// On an iOS↔Android call whose AUDIO runs over the sealed WS relay (not
    /// WebRTC), this controller has no live PC, so [acceptUpgradeOffer] (which
    /// requires `peerConnection`) cannot answer a peer's video-upgrade offer —
    /// the old code returned an empty SDP and the peer rolled the camera back.
    ///
    /// Here we build a FRESH PeerConnection from the peer's upgrade OFFER,
    /// generate the answer, and RETURN it (AppState ships it via
    /// `sendCallUpgradeResponse`, NOT `call_answer`). Because the peer's own PC
    /// never completed ICE/DTLS for the WS-relay call, this is a clean first
    /// offer/answer (externally reviewed): ICE + DTLS establish for the first
    /// time and video flows both ways. Mirrors [acceptIncomingCall] (audio +
    /// video tracks, PQC sealer) but does NOT send a call_answer and does not
    /// guard on `state == .idle` (the controller is freshly built).
    ///
    /// Falls through to [acceptUpgradeOffer] when a PC already exists (a call
    /// that started as video / already negotiated) — that path is a true
    /// renegotiation and must be preserved.
    public func acceptUpgradeOfferBuildingPeerConnection(
        callerId: String,
        remoteSdp: String,
        peerCapabilities: [String]?
    ) async throws -> String {
        if peerConnection != nil {
            if peerCapabilities != nil { acceptPeerCapabilities(peerCapabilities) }
            return try await acceptUpgradeOffer(remoteSdp: remoteSdp)
        }
        hasAppliedRemoteAnswer = false
        intentionalShutdown = false      // Bug-C guard — fresh build, clear any prior teardown latch
        self.recipientId = callerId
        let iceServers = await fetchIceServers()
        // Bug-C guard: this path builds a PC with NO `state == .idle` gate
        // (see the kdoc above), so it needs the check most — see
        // startOutgoingCall's identical check.
        guard !intentionalShutdown else {
            throw ControllerError.wrongState("intentional-shutdown-raced-setup")
        }
        let factory = QAudionPeerConnectionFactory.shared.createFactory(sealerProvider: { [weak self] in
            switch self?.videoSealer {
            case .sframe(let s):  return .sframe(s)
            case .livekit(let c): return .livekit(c)
            default:              return nil
            }
        })
        let pc = QAudionPeerConnection(
            factory: factory,
            iceServers: iceServers,
            iceTransportPolicy: iceTransportPolicyOverride ?? .all,
            delegate: self)
        // Bug-C guard: see startOutgoingCall's identical check.
        guard !intentionalShutdown else {
            pc.close()
            throw ControllerError.wrongState("intentional-shutdown-raced-setup")
        }
        peerConnection = pc
        pc.addLocalAudioTrack()
        pc.onAudioDataChannelFrame = { [weak self] data in self?.onAudioDataChannelFrame?(data) }
        // W-DCMUX — video-upgrade responder PC. Audio on this call shape is
        // pinned to the WS relay by AppState (`audioPinnedToWsRelay`), so this
        // hook is expected to stay quiet; that silence is itself the evidence
        // that distinguishes Phase 0 outcome (c) from (a).
        pc.onAudioDataChannelStateChange = { [weak self] st in self?.onAudioDataChannelStateChange?(st) }
        // Video track BEFORE createAnswer so the answer's m=video is sendrecv
        // with a real encoder-bound codec (avoids codec=null / purple video).
        if let videoSource = pc.addLocalVideoTrack() {
            startCameraCapture(for: videoSource)
        }
        applyPqcSealerIfPossible()
        // 1. Apply the peer's upgrade offer.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteOffer(sdp: remoteSdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
        // W-ICELATEQUEUE — fresh upgrade PC: drain candidates queued while
        // it was being built.
        drainPendingRemoteIce()
        // W-UPGRADEICEWATCHDOG-ANCHOR — remote description is applied; ICE
        // can genuinely start now. Fire before any further await (createAnswer
        // etc.) so a caller-armed give-up watchdog gets the full budget.
        onRemoteDescriptionApplied?()
        // 2. Build the local answer (mirror the peer's video intent).
        let answerSdp: String = try await withCheckedThrowingContinuation { cont in
            pc.createAnswer(hasVideo: true) { result in
                switch result {
                case .success(let s): cont.resume(returning: s)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
        // 3. Apply the peer caps NOW — AFTER the PC exists (caps live on the
        //    QAudionPeerConnection). This makes peerNegotiated() non-nil so
        //    ensureVideoSealer (called inside acceptPeerCapabilities) creates and
        //    KEYS the native video FrameCryptor with K_video. Applying caps before
        //    the PC was built silently dropped them → cryptor never keyed →
        //    discardFrameWhenCryptorNotReady drops every frame → black video.
        acceptPeerCapabilities(peerCapabilities)
        // W-ORPHANSENDER (2026-07-28) — this fresh PC has ZERO transceivers
        // when addLocalVideoTrack() (above, before setRemoteOffer) adds the
        // camera track: WebRTC creates one to hold it. setRemoteOffer then
        // negotiates Android's own m=video section against that same
        // brand-new transceiver in the common case — but when it doesn't
        // (an ambiguous/unmatched pairing), WebRTC ends up with the camera's
        // track sitting on a transceiver that never gets associated (no mid,
        // never answered), while a SEPARATE transceiver carries the real,
        // negotiated m=video Android actually receives an answer for — with
        // no track attached. The answer SDP still looks correct (every
        // offered m-line must be answered) and ICE/DTLS connect fine, so the
        // peer sees a fully "healthy" call that simply never gets any video:
        // acceptPeerCapabilities -> ensureVideoSealer just kept the cryptor
        // on `videoSender`, captured from addLocalVideoTrack() BEFORE this
        // negotiation ran — the wrong, orphaned sender either way.
        // Live-reproduced 2026-07-28 (call ef6307dd...): the camera pipeline
        // pushed 12,000+ real frames into the RTCVideoSource the whole call
        // (confirmed via W-CAPTUREDIAG), delegate always set, yet the peer's
        // rx-arrived counter stayed at literal 0 throughout.
        // rebindVideoSenderCryptorPostNegotiation() re-queries pc.senders
        // NOW — after setRemoteOffer + createAnswer have both completed, so
        // the transceiver is guaranteed associated — updates `videoSender`
        // to whichever sender is CURRENTLY carrying a video track, and
        // rebinds the cryptor onto it. Exact same pair of calls
        // applyUpgradeAnswer already runs after setRemoteAnswer for the
        // INITIATOR side of a video upgrade (BUG2 fix, 2026-07-11) — this
        // fresh-PC-build RESPONDER path never got the equivalent call.
        // rebindVideoReceiverCryptorPostNegotiation() alongside it for the
        // same reason on the receive side, mirroring applyUpgradeAnswer's
        // pairing of the two calls.
        _ = pc.rebindVideoReceiverCryptorPostNegotiation()
        _ = pc.rebindVideoSenderCryptorPostNegotiation()
        // WIRE_SPEC §8.7 (SHOULD) — upgradee path (fresh-PC build):
        // same TX-hold as acceptUpgradeOffer above.
        beginVideoTxHold()
        state = .connecting
        return answerSdp
    }

    // MARK: - W536 — mid-call audio↔video upgrade

    /// Idempotency flag for upgradeToVideo. Set BEFORE the awaits on
    /// addLocalVideoTrack / createOffer so a concurrent
    /// acceptUpgradeOffer (peer-initiated upgrade racing with our
    /// own button press) cannot double-add the video track. Cleared
    /// on applyUpgradeAnswer success or any failure path.
    private var videoUpgradeInProgress: Bool = false

    /// W536 — initiator side. Add a local video track to the live
    /// peer connection, generate a fresh SDP offer that contains the
    /// new m=video section, and return the SDP for AppState to ship
    /// via `CallingApi.sendCallUpgradeRequest`. AppState awaits the
    /// peer's response then calls `applyUpgradeAnswer(sdp:)`.
    ///
    /// Mirrors qaudion-desktop PeerConnectionManager.upgradeToVideo
    /// at the same wire boundary, so iOS↔desktop↔Android upgrades
    /// interoperate.
    ///
    /// Throws:
    /// - `.noPeerConnection` if the call has no live PC.
    /// - `.alreadyHasVideo` if the PC already carries video (either
    ///   the call started with video=true, or the peer raced us).
    /// - `.videoAddFailed` if addLocalVideoTrack returned nil.
    /// - Any underlying WebRTC error from createOffer /
    ///   setLocalDescription.
    public func upgradeToVideo() async throws -> String {
        guard let pc = peerConnection else {
            throw ControllerError.noPeerConnection
        }
        if pc.hasLocalVideoTrack() || videoUpgradeInProgress {
            throw ControllerError.alreadyHasVideo
        }
        videoUpgradeInProgress = true

        // Adding the track BEFORE createOffer is what gets the
        // m=video section into the SDP. RTCPeerConnection's offer
        // generation enumerates current transceivers — order matters.
        // W-SCREENPROFILE — `isScreenSharing` is set by AppState's
        // `startScreenShare()` BEFORE this call (mirroring
        // `useExternalVideoSource` just above it there) so a freshly
        // created source is flagged screencast; see addLocalVideoTrack's
        // kdoc for why this alone doesn't cover every case.
        let source: RTCVideoSource? = pc.addLocalVideoTrack(isScreencast: isScreenSharing)
        guard let videoSource = source else {
            videoUpgradeInProgress = false
            throw ControllerError.videoAddFailed
        }
        // startCameraCapture branches on useExternalVideoSource:
        // - true  → creates WebRTCPixelBufferCapturer, AppState will
        //           re-wire VideoCallPipeline.onCapturedPixelBuffer.
        // - false → opens the front camera via RTCCameraVideoCapturer.
        startCameraCapture(for: videoSource)

        // W-VIDTELGAP (2026-07-20, call 40f6d641) — a mid-call upgrade adds
        // m=video to an ALREADY-negotiated PeerConnection (audio was live
        // long before the user tapped video). `startVideoStatsTelemetry()`
        // was previously reachable ONLY from `didChangeIceConnectionState`'s
        // `.connected`/`.completed` cases — but ICE reached `.connected`
        // during the ORIGINAL audio handshake and, since neither this
        // method nor `acceptUpgradeOffer` requests an ICE restart, never
        // transitions through `.connected` again for this renegotiation.
        // Net effect: iOS silently emits ZERO `video.stats` telemetry for
        // the rest of the call — the tuning card shows the peer's leg with
        // real (if sentinel) values while iOS's leg is entirely absent
        // ("! video tx: ios blind"), which reads as "iOS never touched the
        // camera" even when it did. Starting the poll here (idempotent —
        // guarded by `videoStatsTimer == nil`) makes telemetry track
        // "a local video track now exists" instead of "ICE just connected",
        // which is the condition that actually matters and is still true
        // on call start (ICE connects once, this call remains a no-op
        // there since the ICE-connected path already started it).
        startVideoStatsTelemetry()

        // SENDER-CRYPTOR MID-CALL-UPGRADE FIX (2026-07-10) — root cause of
        // Desktop receiving 100% garbage/plaintext H265 from an iOS CALLER
        // (this initiator/offerer path) that started AUDIO-ONLY then
        // upgraded (device-confirmed via per-SSRC rxdiag: a single ssrc,
        // ZERO successful FrameCryptor opens for the whole call, trailer
        // bytes not our wire format at all = literal plaintext, not a
        // parse bug).
        //
        // Exact same bug class as `acceptUpgradeOffer`'s (line ~1007) and
        // `acceptUpgradeOfferBuildingPeerConnection`'s callee-side fixes —
        // just never applied HERE, the offerer/initiator path. On an
        // audio-only call, `ensureVideoSealerInternal()` runs (idempotent/
        // latched) the moment peer caps + PQC key are ready — i.e. at call
        // setup, before ANY video track exists — so `attachVideoSenderCryptor()`
        // sees `videoSender == nil`, returns false, and (being latched to
        // `.native`) never re-runs its install branch again. `addLocalVideoTrack()`
        // above creates the sender for the FIRST time in THIS call, but
        // nothing re-attaches the already-latched cryptor to it, so
        // libwebrtc's Insertable-Streams sender transform is never
        // installed and every outbound frame goes out unencrypted.
        // `ensureVideoSealerInternal()` re-run while `videoSealer == .native`
        // takes its top "rekey" branch, which unconditionally re-calls
        // `setKey` + `attachVideoSenderCryptor()` — the same call used by
        // the two already-fixed callee paths. A call-from-the-start video
        // call is unaffected (its sender already existed when
        // ensureVideoSealerInternal first ran, so this is a no-op there).
        _ = ensureVideoSealerInternal()

        // Reset the answer-applied flag so the upgrade response isn't
        // mistaken for a duplicate call_answer (the original audio-
        // call answer already set hasAppliedRemoteAnswer=true).
        hasAppliedRemoteAnswer = false

        do {
            let sdp: String = try await withCheckedThrowingContinuation { cont in
                pc.createOffer(audioOnly: false) { result in
                    switch result {
                    case .success(let s): cont.resume(returning: s)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }
            return sdp
        } catch {
            videoUpgradeInProgress = false
            throw error
        }
    }

    /// W536 — initiator side. Apply the SDP answer the peer shipped
    /// in `call_upgrade_response`. Idempotent: a duplicate response
    /// from the relay is silently swallowed via the
    /// `tryAcquireAnswerSlot()` gate.
    public func applyUpgradeAnswer(sdp: String) async throws {
        guard let pc = peerConnection else {
            throw ControllerError.noPeerConnection
        }
        guard tryAcquireAnswerSlot() else {
            // Duplicate call_upgrade_response. No-op.
            return
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                pc.setRemoteAnswer(sdp: sdp) { err in
                    if let err = err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
            videoUpgradeInProgress = false
            // OFFERER-UPGRADE DECODE FIX (2026-07-05) — this is the ONLY
            // flow where our video transceiver was created by a LOCAL
            // addTrack on a second-round offer; the receiver cryptor
            // attached at didAdd-time binds before the receiver's RTP
            // channel is live and inbound video then reaches the decoder
            // STILL ENCRYPTED (framesDecoded pinned at 0 forever — the
            // black-screen bug). Re-create it now, against the receiver as
            // it exists AFTER the answer associated the transceiver. See
            // QAudionPeerConnection.rebindVideoReceiverCryptorPostNegotiation.
            _ = pc.rebindVideoReceiverCryptorPostNegotiation()
            // BUG2 fix (2026-07-11) — SENDER half of the exact same
            // pre-negotiation-attach-timing bug. upgradeToVideo()'s
            // attachVideoSenderCryptor() call ran right after
            // addLocalVideoTrack(), before this answer ever came back —
            // rebind it now against the sender as it exists post-
            // negotiation, mirroring the receiver rebind above. See
            // QAudionPeerConnection.rebindVideoSenderCryptorPostNegotiation.
            _ = pc.rebindVideoSenderCryptorPostNegotiation()
            // WIRE_SPEC §8.7 (SHOULD) — upgrader path: we start sending
            // video now that the answer is applied. Hold TX until the
            // peer's call_media_ready (or 2s), then enable + force IDR.
            beginVideoTxHold()
        } catch {
            videoUpgradeInProgress = false
            throw error
        }
    }

    /// W536 — initiator side, decline/timeout rollback. Undo everything
    /// `upgradeToVideo()` did so the call cleanly returns to audio-only and
    /// a LATER upgrade (ours or the peer's) starts from a clean slate.
    ///
    /// Without this, a single decline (or 30s response timeout) poisoned the
    /// call permanently: `videoUpgradeInProgress` stayed latched and the
    /// local video track stayed attached (so our retries threw
    /// `.alreadyHasVideo` and sent nothing), and the PC stayed parked in
    /// `have-local-offer` (so the PEER's next upgrade offer failed
    /// setRemoteOffer wrong-state and got auto-declined) — upgrades dead in
    /// both directions for the rest of the call.
    ///
    /// Steps mirror Android CallController's decline path: stop camera,
    /// remove the upgrade's video track, JSEP-rollback the pending offer,
    /// re-latch the answer slot (the ORIGINAL audio answer had been applied;
    /// `upgradeToVideo` cleared the slot for the upgrade answer, so a stray
    /// late `call_upgrade_response` must be swallowed as a duplicate again).
    /// Safe no-op when no upgrade is in flight.
    /// 2026-07-04 fix — responder-side counterpart of `cancelVideoUpgrade()`.
    /// When `acceptUpgradeOffer(remoteSdp:)` fails (a live-call renegotiation
    /// on this ALREADY-EXISTING controller, as opposed to the on-demand PC
    /// built by `makeUpgradeResponderController`), the shared PeerConnection
    /// can be left parked in `have-local-offer` — see
    /// `QAudionPeerConnection.rollbackLocalOffer`'s kdoc for the exact
    /// mechanism (libwebrtc's "Called in wrong state" on the next
    /// `setRemoteOffer`). Unlike `cancelVideoUpgrade()`, this does NOT gate
    /// on `videoUpgradeInProgress` (that flag is caller-side-only — a pure
    /// responder failure never sets it, which made calling
    /// `cancelVideoUpgrade()` here a no-op) and does NOT touch camera
    /// capture / TX-hold / `videoUpgradeInProgress` — those belong to a
    /// LOCAL upgrade attempt, not this device's incoming-offer failure.
    /// `rollbackLocalOffer` is self-guarding (no-op unless
    /// signalingState == .haveLocalOffer), so this is safe to call
    /// unconditionally and never touches a healthy PC or the live audio leg.
    public func recoverPeerConnectionAfterFailedIncomingUpgrade() async {
        guard let pc = peerConnection else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pc.rollbackLocalOffer { _ in cont.resume() }
        }
    }

    public func cancelVideoUpgrade() async {
        guard videoUpgradeInProgress else { return }
        stopCameraCapture()
        if let pc = peerConnection {
            pc.removeLocalVideoTrack()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                pc.rollbackLocalOffer { _ in cont.resume() }
            }
        }
        hasAppliedRemoteAnswer = true
        videoUpgradeInProgress = false
        // §8.7 TX-hold — a hold can only be armed AFTER a successful
        // answer, so none should exist here; clear defensively so a
        // rolled-back upgrade can't leave the track latched disabled.
        clearVideoTxHold()
        print("[WebRTC] video upgrade cancelled — rolled back to audio-only stable state")
    }

    /// WIRE_SPEC §8.3 — glare, polite side ONLY. Roll back OUR pending
    /// upgrade OFFER's JSEP state so the peer's colliding offer can be
    /// applied right after — but, unlike `cancelVideoUpgrade()`, do NOT stop
    /// the camera or remove the local video track.
    ///
    /// Device-confirmed (call acd516b8, 2026-07-28, camera confirmed ON):
    /// `AppState.handleGlareCollision`'s polite branch called
    /// `cancelVideoUpgrade()` before accepting the peer's offer, on the
    /// assumption (its own comment: "accepting the peer's upgrade means
    /// bidirectional video anyway") that our camera/track would survive.
    /// `cancelVideoUpgrade()` calls `removeLocalVideoTrack()`, which calls
    /// `pc.removeTrack(sender)` — a JSEP-level operation, not just clearing
    /// `.track`, that marks the transceiver for a sendrecv→recvonly downgrade
    /// on the NEXT negotiation. The immediately-following
    /// `acceptUpgradeOffer()` → `addLocalVideoTrack()` only does
    /// `existing.sender.track = track` (a soft reattach) on that SAME
    /// transceiver, which cannot undo `removeTrack()`'s effect — so our own
    /// answer to the peer's upgrade came back `recvonly` despite the camera
    /// being on and a track being set. Skipping the camera-stop/track-remove
    /// here makes the existing comment's assumption actually hold.
    public func rollbackLocalVideoOfferForGlare() async {
        guard videoUpgradeInProgress else { return }
        if let pc = peerConnection {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                pc.rollbackLocalOffer { _ in cont.resume() }
            }
        }
        hasAppliedRemoteAnswer = true
        videoUpgradeInProgress = false
        clearVideoTxHold()
        print("[WebRTC] video upgrade offer rolled back for glare — camera/track kept for peer accept")
    }

    // MARK: - WIRE_SPEC §8.7 — sender-side IDR forcing + TX-hold

    /// §8.7 TX-hold state. `true` while the LOCAL video track is held
    /// disabled waiting for the peer's `call_media_ready` (or the 2s
    /// timeout). NSLock-protected because the controller is
    /// `@unchecked Sendable` (upgrade methods resume on arbitrary
    /// executors; the release can come from the WS handler hop).
    private let txHoldLock = NSLock()
    private var _videoTxHoldArmed = false
    private var _videoTxHoldTimeoutTask: Task<Void, Never>?
    /// §8.7 — true once the peer's `call_media_ready` has been seen this
    /// call. `call_media_ready` is sent once per (callId, mid) and will
    /// NOT be re-sent on a re-upgrade of the same mid, so arming a fresh
    /// TX-hold after it arrived would ALWAYS run into the 2s timeout
    /// (2s of pointless black on every camera off→on). Mirrors Android
    /// CallController's `peerMediaReadySeen` skip in `armVideoTxHold`.
    /// Reset in `closeSynchronously()` for the next call.
    private var _peerMediaReadySeen = false

    /// WIRE_SPEC §8.7 (INT-4a) — force an IDR on the next WebRTC-rail
    /// `encode()`: sets the process-wide force-next flag consumed by the
    /// `KeyframeForcingVideoEncoder` wrapper that
    /// `HevcPreferredVideoEncoderFactory` installs around every encoder.
    /// Harmless no-op when no video encoder is live (flag is consumed by
    /// the next encoder that starts). Callable from any thread.
    public func forceWebRtcKeyframe() {
        VideoKeyframeController.shared.requestKeyFrame()
    }

    /// VIDEODIAG (§8.7 self-heal watchdog) — read-only diagnostic: is the
    /// RECEIVER-side native video cryptor BOTH attached and keyed right
    /// now? Mirrors the `notifyInboundVideoReadyIfNeeded` readiness pair
    /// so the watchdog's stall log can pinpoint "frames arrive but the
    /// cryptor can't open them" vs a renderer problem. Callable from any
    /// thread (reads only).
    public var inboundVideoCryptorReady: Bool {
        guard let pc = peerConnection,
              let cryptor = pc.nativeVideoCryptor else { return false }
        return cryptor.keyIsSet && cryptor.receiverIsAttached
    }

    /// WIRE_SPEC §8.7 (SHOULD) — hold LOCAL video TX at upgrade time:
    /// disable the local video track until EITHER the peer's
    /// `call_media_ready` arrives (`releaseVideoTxHold`) OR a 2s timeout
    /// elapses. Never blocks: the timeout path degrades to today's
    /// behavior (signal-not-kill). One-shot per upgrade — re-arming
    /// replaces any previous hold. No-op without a local video track.
    func beginVideoTxHold() {
        guard let pc = peerConnection, pc.hasLocalVideoTrack() else { return }
        txHoldLock.lock()
        // §8.7 skip (Android armVideoTxHold parity): the peer's receiver
        // was already proven ready this call — media_ready is once per
        // (callId, mid), so a fresh hold could only end by timeout.
        if _peerMediaReadySeen {
            txHoldLock.unlock()
            print("[WebRTC] §8.7 TX-hold skipped — peer call_media_ready already seen this call")
            return
        }
        _videoTxHoldArmed = true
        _videoTxHoldTimeoutTask?.cancel()
        // Mute INSIDE the lock — otherwise an early release (peer's
        // call_media_ready racing the arm) could unmute BEFORE this
        // mute lands, latching the track disabled until endCall.
        pc.setVideoMuted(true)
        _videoTxHoldTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.releaseVideoTxHold(reason: "2s timeout")
        }
        txHoldLock.unlock()
        print("[WebRTC] §8.7 TX-hold armed — local video held until peer call_media_ready (max 2s)")
    }

    /// §8.7 — record that the peer's `call_media_ready` was seen this
    /// call, so any LATER TX-hold arm (re-upgrade / camera off→on on the
    /// same mid) is skipped instead of dying on the 2s timeout. Called by
    /// AppState's `handleInboundKeyframeSignal` alongside
    /// `releaseVideoTxHold` (kept separate: the timeout release must NOT
    /// set this). Callable from any thread.
    public func notePeerMediaReadySeen() {
        txHoldLock.lock()
        _peerMediaReadySeen = true
        txHoldLock.unlock()
    }

    /// Release the §8.7 TX-hold: enable the local video track and force
    /// one keyframe so the (now-ready) peer decoder bootstraps from a
    /// clean IDR. Idempotent — the first caller (peer readiness or
    /// timeout) wins, later calls are no-ops. Callable from any thread.
    public func releaseVideoTxHold(reason: String) {
        txHoldLock.lock()
        let wasArmed = _videoTxHoldArmed
        _videoTxHoldArmed = false
        _videoTxHoldTimeoutTask?.cancel()
        _videoTxHoldTimeoutTask = nil
        // Unmute inside the lock, symmetric with beginVideoTxHold's mute
        // (see the race note there).
        if wasArmed { peerConnection?.setVideoMuted(false) }
        txHoldLock.unlock()
        guard wasArmed else { return }
        forceWebRtcKeyframe()
        print("[WebRTC] §8.7 TX-hold released (\(reason)) — video track enabled + IDR forced")
    }

    /// Drop TX-hold state WITHOUT touching the track (teardown paths —
    /// the PC is going away or the upgrade was rolled back).
    private func clearVideoTxHold() {
        txHoldLock.lock()
        _videoTxHoldArmed = false
        _videoTxHoldTimeoutTask?.cancel()
        _videoTxHoldTimeoutTask = nil
        txHoldLock.unlock()
    }

    /// W536 — responder side. Accept a `call_upgrade_request`: add a
    /// local video track if not already present, apply the remote
    /// offer, generate the local answer, and return the answer SDP.
    /// AppState ships the answer via
    /// `CallingApi.sendCallUpgradeResponse(accepted: true)`.
    public func acceptUpgradeOffer(remoteSdp: String) async throws -> String {
        guard let pc = peerConnection else {
            throw ControllerError.noPeerConnection
        }
        if !pc.hasLocalVideoTrack() {
            if let source = pc.addLocalVideoTrack() {
                startCameraCapture(for: source)
            }
        }
        // Re-run the sealer pick now that a local video track exists.
        // The audio-only call already ran ensureVideoSealerInternal via
        // acceptPeerCapabilities (CallCapabilities.swift advertises
        // sframe-v1 on every call, video or not) — that attempt silently
        // failed to attach the sender cryptor because videoSender was
        // still nil. Without this call, the peer-initiated (Android→iOS)
        // upgrade path never retries the attach: iOS ships UNSEALED video
        // RTP, and the peer's discardFrameWhenCryptorNotReady receiver
        // drops every frame — bytes/packets arrive, framesDecoded stays 0
        // (purple screen). Mirrors the same fix already applied to the
        // fresh-PC-build upgrade path below (see the W536 comment there)
        // and to acceptPeerCapabilities.
        _ = ensureVideoSealerInternal()
        // 1. Remote offer (with new m=video section).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteOffer(sdp: remoteSdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
        // 2. Local answer.
        let answerSdp: String = try await withCheckedThrowingContinuation { cont in
            pc.createAnswer(hasVideo: true) { result in
                switch result {
                case .success(let s): cont.resume(returning: s)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
        // WIRE_SPEC §8.7 (SHOULD) — upgradee path: our answer is built,
        // video TX starts once it ships. Hold TX until the peer's
        // call_media_ready (or 2s), then enable + force IDR.
        beginVideoTxHold()
        // W-VIDTELGAP (2026-07-20, call 40f6d641) — same gap as
        // `upgradeToVideo()` above, responder side: this renegotiation
        // reuses the ALREADY-connected PC from the audio phase, so
        // `didChangeIceConnectionState` will not fire `.connected`/
        // `.completed` again and `startVideoStatsTelemetry()` would
        // otherwise never run for a peer-initiated mid-call upgrade.
        // Idempotent (guarded by `videoStatsTimer == nil`).
        startVideoStatsTelemetry()
        return answerSdp
    }

    // MARK: - ICE

    // W-ICELATEQUEUE (2026-08-30) — remote candidates that arrive before
    // this controller's peer connection exists AND has its remote
    // description applied. Two silent drops used to stack here: AppState's
    // W-ICEQUEUE flush runs the moment the controller is BUILT — before
    // `acceptIncomingCall`/`startOutgoingCall` has even created the
    // RTCPeerConnection — so `peerConnection?.` swallowed the whole batch;
    // and even with a PC, `pc.add(candidate)` before setRemoteDescription
    // fails with an error the completion discarded. Measured live (call
    // 19638b21, 2026-08-30): "ice candidate flush n=7" on the iOS leg,
    // then ZERO connectivity checks ever sent — on a LAN the peer's
    // direct pings still rescued the pair via triggered checks, which is
    // why same-WiFi calls connected all day while EVERY cross-network
    // call sat in CHECKING forever (no outbound ping ⇒ no NAT hole toward
    // srflx, no TURN permission toward the peer's relay — both paths need
    // OUR first packet). Android buffers and pumps candidates after open;
    // this queue is that same discipline.
    private let pendingIceLock = NSLock()
    private var pendingRemoteIceQueue: [(sdp: String, mid: String?, mline: Int32)] = []
    private var remoteDescriptionApplied = false

    public func handleRemoteIce(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        let queued: Int? = pendingIceLock.withLock {
            guard peerConnection != nil, remoteDescriptionApplied else {
                pendingRemoteIceQueue.append((candidate, sdpMid, sdpMLineIndex))
                return pendingRemoteIceQueue.count
            }
            return nil
        }
        if let n = queued {
            log?("ice queued_pc=1 n=\(n)")
            return
        }
        peerConnection?.addRemoteIce(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
    }

    /// W-ICELATEQUEUE — mark the remote description applied and hand every
    /// queued candidate to the ICE agent. Called from the three SRD
    /// success sites (incoming offer, caller answer, restart offer).
    private func drainPendingRemoteIce() {
        let toApply: [(sdp: String, mid: String?, mline: Int32)] = pendingIceLock.withLock {
            remoteDescriptionApplied = true
            let q = pendingRemoteIceQueue
            pendingRemoteIceQueue.removeAll()
            return q
        }
        guard !toApply.isEmpty else { return }
        log?("ice drain n=\(toApply.count)")
        for c in toApply {
            peerConnection?.addRemoteIce(candidate: c.sdp, sdpMid: c.mid, sdpMLineIndex: c.mline)
        }
    }

    /// W-ICEBATCH (2026-08-25) — batch-form candidate removal (`removed:
    /// true` entry in a `candidates` array): the peer withdrew this
    /// candidate, prune it from the ICE agent immediately.
    public func handleRemoteIceRemoval(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        peerConnection?.removeRemoteIce(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
    }

    // MARK: - Mute / hangup

    public func setMicrophoneMuted(_ muted: Bool) {
        peerConnection?.setMicrophoneMuted(muted)
    }

    public func hangup() async {
        if let rid = recipientId {
            try? await callingApi.sendHangup(recipientId: rid)
        }
        closeSynchronously()
    }

    /// H-6 — synchronous teardown of the local media stack. Closes the
    /// RTCPeerConnection and clears per-call state WITHOUT the async
    /// `sendHangup` network round-trip. Idempotent: a second call is a
    /// no-op once `peerConnection` is already nil. AppState.endCall()
    /// calls this directly (before dropping its controller reference)
    /// so a double endCall can't leak the RTCPeerConnection while a
    /// fire-and-forget `hangup()` Task is still in flight.
    public func closeSynchronously() {
        // Bug-C guard — set BEFORE the early-return so it fires even when
        // this teardown races a start method that hasn't assigned
        // `peerConnection` yet (the exact gap the early-return used to miss).
        intentionalShutdown = true
        // W-SILENTPATHDEATH — stop the call-scoped path monitor and the
        // recovery watchdog/park unconditionally, even on the early-return
        // below: `armRestartPathMonitor()` can have started them during a
        // `startOutgoingCall`/`acceptIncomingCall` that then failed before
        // `peerConnection` was ever assigned (Bug-C guard race), same class
        // of leak this early-return already exists to close for other
        // per-call resources.
        restartPathMonitor?.cancel()
        restartPathMonitor = nil
        iceRecoveryWatchdogTask?.cancel()
        iceRecoveryWatchdogTask = nil
        // NOTE: `sendIceRestartOffer`'s own W-RESTARTOFFERPARK resend
        // (BCryptoCallingApiImpl) is intentionally NOT cancelled here — it
        // is a detached, fire-and-forget Task scoped to the CallingApi
        // layer, not this controller. If it fires after this call already
        // ended, the envelope carries a call_id the server no longer
        // tracks; the server's W-STALEOFFER path (`recentCallEndings`)
        // bounces a `call_hangup` back at the sender, which this app's
        // existing idempotent hangup handler absorbs as a no-op — same
        // safety argument `deliverHangup`'s identically-shaped park
        // already relies on for a hangup landing after the call is gone.
        lastExternalNetworkChangeAt = nil
        lastIceRestartAt = nil
        lastAppliedRemoteRestartSdp = nil
        lastIceConnectionState = .new
        hasEverConnectedIce = false
        iceGoodSinceMs = nil
        guard peerConnection != nil else {
            state = .disconnected
            return
        }
        stopCameraCapture()
        stopVideoStatsTelemetry()
        // W-NETVIS — the pair this was measured on is gone; the band must show
        // "—" for the next call rather than the previous call's last RTT.
        setMediaRttMs(nil)
        wssTurnBridge?.stop()
        wssTurnBridge = nil
        peerConnection?.close()
        peerConnection = nil
        recipientId = nil
        hasAppliedRemoteAnswer = false   // W418 — reset for next call
        videoSealer = nil                // commit 3db2cd81 parity — reset
                                         // pipeline pick so the next call
                                         // re-runs ensureVideoSealer().
        videoKeyIsPhoneLevel = false     // vkey-v1 — reset dual-trust flag.
        videoContactPsk = nil            // vkey-v1 — clear per-call PSK.
        // WIRE_SPEC §8.7 — re-arm the one-shot inbound-video-ready latch
        // so the NEXT call fires onInboundVideoReady again.
        inboundReadyLock.lock()
        _inboundVideoReadyFired = false
        inboundReadyLock.unlock()
        // WIRE_SPEC §8.7 (INT-4a) — reset the receiver decode-stall detector
        // so the next call's monotonic counters start from a clean baseline.
        _lastFramesDecoded = -1
        _lastBytesReceived = -1
        _videoStallPolls = 0
        // W-ROUTECLAMP / W-BWCAP / W-BACKPRESSURE — per-call state must not
        // bleed into the next call (mirrors Android's
        // `PeerBitrateCap.reset()` at call teardown).
        _routeTierDwell.reset()
        if _lastReportedRemoteHost != nil {
            _lastReportedRemoteHost = nil
            onActiveCandidatePairRemoteHost?(nil)
        }
        _cpuLimitedPolls = 0
        _healthyPolls = 0
        _backpressureSteps = 0
        VideoBandwidthCap.reset()
        // W-BWECOMPOSE — same per-call reset discipline as the other three
        // clamp-chain state holders right above.
        _bweSenderCeiling.reset()
        // WIRE_SPEC §8.7 — drop any armed TX-hold (endCall funnels through
        // here via sendHangupAndClose): cancel the 2s watchdog and clear
        // the one-shot latch so the next call/upgrade starts clean. The
        // track itself is gone with the closed PC — nothing to unmute.
        clearVideoTxHold()
        // §8.7 — the peer-readiness memo is per call: the NEXT call's
        // upgrades must arm a real TX-hold again.
        txHoldLock.lock()
        _peerMediaReadySeen = false
        txHoldLock.unlock()
        state = .disconnected
    }

    /// W495 — send WS call_hangup THEN close the peer connection.
    ///
    /// Problem fixed: the old AppState.endCall() pattern was:
    ///   closeSynchronously()        // sets recipientId = nil
    ///   Task { await ctrl.hangup() } // reads recipientId — already nil!
    /// → call_hangup was NEVER sent → remote waited for ICE timeout (~3s)
    ///   before ending the call.
    ///
    /// This method captures recipientId BEFORE closeSynchronously() clears
    /// it, closes the peer connection synchronously (no leak), then fires
    /// the WS hangup on a detached Task (unblocked by MainActor teardown).
    public func sendHangupAndClose() {
        let rid = recipientId          // capture BEFORE closeSynchronously
        let api = callingApi           // W497 — strong capture: after closeSynchronously()
                                       // AppState sets webRtcController = nil which
                                       // releases the controller; [weak self] would
                                       // then see self == nil and skip sendHangup.
                                       // Capturing `api` directly keeps the CallingApi
                                       // alive for the lifetime of the Task regardless
                                       // of whether `self` has been released.
        closeSynchronously()           // closes peer connection, clears fields
        guard let r = rid else { return }
        Task.detached(priority: .userInitiated) {
            try? await api.sendHangup(recipientId: r)
        }
    }

    // MARK: - W-SILENTPATHDEATH — ICE-restart recovery machine
    //
    // Parity plan Fase E3 (docs/interop/2026-08-25-cross-platform-parity-
    // plan.md), ported from Android's real, shipped implementation:
    // `PeerConnectionHolder.restartIce`/`.handleRemoteOffer` +
    // `CallController.notifyNetworkChanged`/`.iceFailedRecoveryJob`
    // (qaudion-android-new, graph-verified against
    // feature/feature-call/.../data/webrtc/PeerConnectionHolder.kt and
    // .../domain/CallController.kt). See `RestartIceDecisions` for the
    // pure decision logic (self-repair window sizing, glare verdicts) —
    // this section is the imperative wiring around it.

    /// W-PROACTIVEHANDOFF: numeric-safe encoding of an interface type for
    /// `log?(...)` lines (this repo's redactor rule — see
    /// `reference_ios_log_pipeline_limits` — blobs any non-numeric free
    /// text token, so a raw `\(type)` interpolation would be silently
    /// dropped before it ever reaches Loki; every other log line in this
    /// file already encodes enum/bool state as an Int for the same
    /// reason, e.g. `route tier=\(tier == .relay ? 1 : 0)` above).
    private static func interfaceTypeCode(_ type: NWInterface.InterfaceType?) -> Int {
        switch type {
        case .none: return 0
        case .some(.wifi): return 1
        case .some(.cellular): return 2
        case .some(.wiredEthernet): return 3
        case .some(.loopback): return 4
        case .some: return 5 // .other, or any future case
        }
    }

    /// W-PROACTIVEHANDOFF: best-effort "which interface is actually
    /// carrying this path" classification — `NWPath` can report several
    /// interfaces simultaneously usable, so this picks ONE in the same
    /// wifi > cellular > wired > loopback > other priority order most iOS
    /// networking code uses for display purposes. Good enough for "did the
    /// ACTIVE interface change" purposes, not meant as a precise routing
    /// decision.
    private static func dominantInterfaceType(of path: NWPath) -> NWInterface.InterfaceType? {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        if path.usesInterfaceType(.loopback) { return .loopback }
        if path.usesInterfaceType(.other) { return .other }
        return nil
    }

    /// Start the call-scoped OS network-change signal. Idempotent — a
    /// second call (e.g. a defensive re-invocation) is a no-op.
    private func armRestartPathMonitor() {
        guard restartPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // ANY path callback is an external, OS-driven network signal
            // (interface up/down, transport switch). Mirrors Android's
            // `NetworkChangeReactor` -> `CallController
            // .notifyNetworkChanged`: timestamps the signal so the
            // recovery watchdog below can size its self-repair window
            // (W-SILENTPATHDEATH: a bad ICE state shortly after a real
            // OS event gets the FULL self-repair window because fresh
            // candidates are probably already arriving; a bad ICE state
            // with NO such event is the silent-path-death case this item
            // is named for — same-SSID AP roam, carrier NAT rebind — and
            // gets a SHORT window because nothing is coming). The
            // watchdog itself reacts to the PeerConnection's OWN ICE
            // state (`didChangeIceConnectionState`), which fires
            // independent of any OS event at all — that native
            // consent-freshness/STUN-check detection, not this monitor,
            // is what covers the silent case.
            self.lastExternalNetworkChangeAt = Date()

            // W-PROACTIVEHANDOFF (2026-08-26) — a SECOND, PROACTIVE
            // trigger on top of the reactive watchdog above: a genuine
            // active-interface change (wifi<->cellular<->wired) on an
            // ALREADY-connected call is near-certain to invalidate the
            // existing ICE candidate pair's local IP (the old candidates
            // are bound to an interface that's no longer the one
            // carrying traffic) — restart preemptively instead of only
            // waiting for ICE to independently degrade and the reactive
            // watchdog to notice. Gated on:
            //   - `path.status == .satisfied` — a new USABLE path exists
            //     to move onto; `.unsatisfied`/`.requiresConnection`
            //     means the interface just went DOWN with nothing to
            //     restart onto yet — the reactive watchdog (ICE will
            //     independently go bad) already covers that half.
            //   - the resolved interface actually DIFFERS from last
            //     time, AND there WAS a last time (`previous != nil`) —
            //     the very first callback on monitor start always looks
            //     like a transition from nothing and must not fire on a
            //     call that hasn't even connected yet.
            //   - `hasEverConnectedIce` — only an already-connected call
            //     benefits from a preemptive refresh.
            //   - `!isIceStateBad(lastIceConnectionState)` (independent-
            //     review fix, nim.ps1 security pass) — if ICE is ALREADY
            //     in a bad state, the reactive watchdog above is already
            //     the one driving recovery; this trigger's whole value is
            //     getting AHEAD of a failure that hasn't happened yet, not
            //     firing a second, redundant restart attempt into a
            //     recovery the watchdog is already running.
            // `restartIce`'s own `iceRestartDebounceMs` (3s), now made
            // race-safe against concurrent callers by
            // `restartIceDebounceLock` (independent-review fix — this
            // trigger and the reactive watchdog can now genuinely fire
            // concurrently, which the plain unguarded debounce read+write
            // wasn't safe against), is the
            // safety net against a flapping interface spamming restart
            // offers — the SAME mechanism its own kdoc already documents
            // for exactly this case, not a new debounce invented here.
            // Known, accepted trade-off (not solvable without live-device
            // tuning this pass didn't have): a bearer-type flag CAN flip
            // for reasons that aren't a real handover (radio-technology
            // renegotiation, a VPN adapter re-registering), so this can
            // occasionally fire a restart offer for a link that didn't
            // actually need one. That is a harmless extra renegotiation,
            // not a correctness risk: `RestartIceDecisions`' existing
            // glare tiebreak (reachable from either role as of this same
            // change — see `restartIce` below) resolves any resulting
            // race safely either way.
            let interfaceType = Self.dominantInterfaceType(of: path)
            let previous = self.lastActiveInterfaceType
            // W-PATHMEMLOSS (2026-08-30) — remember only a REAL, satisfied
            // interface. This used to assign unconditionally, so the
            // transportless callback a handoff emits first (old interface
            // gone, new one not up yet -> `nil`) erased the memory of WiFi,
            // and the "cellular is up" callback ~2 s later found
            // `previous == nil`, failed the `let previous` bind below, and
            // the proactive restart was silently dropped — recovery then
            // waited on the reactive watchdog instead (~5-10 s of dead P2P
            // where this trigger fires in ~2 s). Same defect class Android
            // fixed as W-RESTARTDEBOUNCEBURN (the useless network-loss
            // event spending state the useful arrival event needs), and the
            // same fix this repo already applied to three other
            // NWPathMonitor consumers (see BCryptoRestClient's
            // satisfied-sentinel). An unsatisfied callback now changes
            // nothing at all.
            if path.status == .satisfied, let realInterface = interfaceType {
                self.lastActiveInterfaceType = realInterface
            }
            if path.status == .satisfied,
               let interfaceType, let previous, interfaceType != previous,
               self.hasEverConnectedIce,
               !self.isIceStateBad(self.lastIceConnectionState) {
                self.log?("restart_ice trigger=1 from_if=\(Self.interfaceTypeCode(previous)) to_if=\(Self.interfaceTypeCode(interfaceType))")
                // `[weak self]` again here even though `self` is already a
                // strongly-unwrapped local in this scope (from the `guard
                // let self` above) — capturing that strong local directly
                // would keep the controller alive for this Task's whole
                // duration (bounded by `restartIce`'s own ~45s worst-case
                // park budget, but still an avoidable extension past
                // teardown) — same discipline `iceRecoveryWatchdogTask`
                // already uses for its own `restartIce` call.
                Task { [weak self] in await self?.restartIce(reason: "interface-change") }
            }
        }
        monitor.start(queue: restartPathMonitorQueue)
        restartPathMonitor = monitor
    }

    private func isIceStateBad(_ s: RTCIceConnectionState) -> Bool {
        s == .failed || s == .disconnected
    }

    /// W-SILENTPATHDEATH — cancel the recovery watchdog. Called on genuine
    /// ICE recovery (`.connected`/`.completed`) and on `.closed`/teardown.
    private func disarmIceRecoveryWatchdog() {
        iceRecoveryWatchdogTask?.cancel()
        iceRecoveryWatchdogTask = nil
    }

    /// W-SILENTPATHDEATH — arm the recovery watchdog if ICE just went bad
    /// and nothing is already running. Mirrors Android's
    /// `iceFailedRecoveryJob`: size a self-repair window (short if no
    /// recent OS network event — silent path death — long otherwise),
    /// wait it out, and if ICE is STILL bad afterwards escalate to
    /// `restartIce`, retrying on a backed-off settle-window cadence for as
    /// long as ICE stays bad. Cooperative cancellation (Task.sleep
    /// throwing on `.cancel()`) is what makes this event-driven rather
    /// than polling: `disarmIceRecoveryWatchdog` cancels this task the
    /// INSTANT `didChangeIceConnectionState` reports recovery, so a
    /// self-heal that lands mid-window is not waited out.
    private func armIceRecoveryWatchdogIfNeeded() {
        guard hasEverConnectedIce else { return }
        guard iceRecoveryWatchdogTask == nil else { return }
        let elapsedMs: Int64? = lastExternalNetworkChangeAt.map {
            Int64(Date().timeIntervalSince($0) * 1000)
        }
        let repairWindowMs = RestartIceDecisions.selfRepairWindowMs(msSinceLastExternalNetworkChange: elapsedMs)
        let silentPathDeath = (elapsedMs == nil) || (elapsedMs! > RestartIceDecisions.silentPathDeathLookbackMs)
        // Numeric-safe (this repo's redactor rule): no free-text word run.
        log?("ice_recovery armed=1 silent=\(silentPathDeath ? 1 : 0) window_ms=\(repairWindowMs)")
        iceRecoveryWatchdogTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(repairWindowMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            guard self.isIceStateBad(self.lastIceConnectionState) else {
                self.log?("ice_recovery self_healed=1")
                self.iceRecoveryWatchdogTask = nil
                return
            }
            self.log?("ice_recovery escalate=1")
            var settleMs = RestartIceDecisions.recoverySettleInitialMs
            while !Task.isCancelled && self.isIceStateBad(self.lastIceConnectionState) {
                await self.restartIce(reason: "ice-failed-recovery-watchdog")
                guard !Task.isCancelled else { return }
                // W-WATCHDOGDEBOUNCE (2026-08-30) — sleep at least past
                // `iceRestartDebounceMs` before the next attempt. The raw
                // 1.5 s initial settle put the second `restartIce` inside
                // the 3 s debounce, where it was ALWAYS dropped — so the
                // real ladder was 0 s, then nothing until 4.5 s, with a
                // wasted wakeup in between that logged an attempt it never
                // made. The settle backoff itself is unchanged; only the
                // floor is new. See RestartIceDecisions
                // .recoveryRetrySettleMs for the pinned rule.
                let sleepMs = RestartIceDecisions.recoveryRetrySettleMs(proposedMs: settleMs)
                try? await Task.sleep(nanoseconds: UInt64(sleepMs) * 1_000_000)
                guard !Task.isCancelled else { return }
                if !self.isIceStateBad(self.lastIceConnectionState) { break }
                settleMs = min(settleMs * 2, RestartIceDecisions.recoverySettleMaxMs)
            }
            self.iceRecoveryWatchdogTask = nil
        }
    }

    /// W-SRTPFALLBACK — arm the fallback-engage debounce if ICE just went
    /// bad on a native-audio-srtp call and nothing is already running.
    /// Independent of `armIceRecoveryWatchdogIfNeeded` above — that watchdog
    /// tries to RECOVER ICE itself (restart offers); this one only decides
    /// whether to reopen the manual audio capture path while ICE stays down,
    /// on a completely separate timer (`SrtpFallbackDecisions
    /// .fallbackEngageDebounceMs`, 1 s — deliberately shorter than the ICE
    /// self-repair window, because every second of an audio-srtp outage is
    /// a second of one-way silence, not merely a routing inefficiency).
    private func armSrtpFallbackIfNeeded() {
        guard peerConnection?.usingNativeAudioSrtp == true else { return }
        guard iceBadSinceMs == nil else { return }
        let since = Self.nowMs()
        iceBadSinceMs = since
        guard srtpFallbackTask == nil else { return }
        // W-SRTPFALLBACKRETRY (2026-08-30) — a LOOP, not a one-shot. The
        // one-shot evaluated exactly once per outage: if ICE happened to sit
        // in `.checking` at the 1 s mark (the recovery watchdog fires
        // `restartIce` on the same edge, so it often does), `engage` came
        // back false, the task nilled itself WITHOUT clearing
        // `iceBadSinceMs`, and every later bad-ICE edge of the same outage
        // bounced off the `guard iceBadSinceMs == nil` above — the whole
        // outage passed with the fallback never engaging. Re-evaluate every
        // debounce period for as long as the streak is officially alive
        // (`iceBadSinceMs` set; only genuine recovery clears it via
        // `disarmSrtpFallbackIfRecovered`, which also cancels this task).
        // A `.checking` round simply keeps waiting; the next `.disconnected`
        // round engages. `shouldEngageFallback` itself is unchanged.
        srtpFallbackTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(SrtpFallbackDecisions.fallbackEngageDebounceMs) * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                let engage = SrtpFallbackDecisions.shouldEngageFallback(
                    usingNativeAudioSrtp: self.peerConnection?.usingNativeAudioSrtp == true,
                    iceBad: self.isIceStateBad(self.lastIceConnectionState),
                    iceBadSinceMs: self.iceBadSinceMs,
                    nowMs: Self.nowMs(),
                    fallbackAlreadyEngaged: self.srtpFallbackEngaged
                )
                if engage {
                    self.srtpFallbackTask = nil
                    self.srtpFallbackEngaged = true
                    self.log?("audiosrtp_fallback engage=1")
                    self.onAudioSrtpFallbackEngage?()
                    return
                }
                if !SrtpFallbackDecisions.shouldKeepWaitingToEngage(
                    streakAlive: self.iceBadSinceMs != nil,
                    fallbackAlreadyEngaged: self.srtpFallbackEngaged
                ) {
                    self.srtpFallbackTask = nil
                    return
                }
            }
        }
    }

    /// W-SRTPFALLBACK — the recover edge is deliberately ungated (no
    /// debounce): the moment ICE leaves the bad states, native audio is
    /// carrying the call again and the second capture path must stop
    /// promptly. Cancels any still-pending engage debounce too, so a blip
    /// that heals inside the debounce window never fires the engage
    /// callback after the fact.
    private func disarmSrtpFallbackIfRecovered() {
        srtpFallbackTask?.cancel()
        srtpFallbackTask = nil
        iceBadSinceMs = nil
        guard SrtpFallbackDecisions.shouldRecoverFromFallback(
            fallbackEngaged: srtpFallbackEngaged,
            iceBad: false
        ) else { return }
        srtpFallbackEngaged = false
        log?("audiosrtp_fallback recover=1")
        onAudioSrtpFallbackRecover?()
    }

    /// W-VIDEOSENDGATE (2026-08-26) — true only once ICE has stayed in a
    /// confirmed-good state (`.connected`/`.completed`) for at least
    /// `debounceMs`. `AppState`'s video WS-relay send leg
    /// (`onOutboundFragment`) reads this — alongside confirming
    /// `webrtcPixelBufferCapturer` is actually wired — before treating the
    /// custom relay as redundant with native RTP for this frame. `false`
    /// covers every other case exactly like today's unconditional send did:
    /// not yet negotiated (this call never reached `.connected`), an
    /// in-progress ICE restart, or ICE genuinely down. Debounce defaults to
    /// `SrtpFallbackDecisions.fallbackEngageDebounceMs` — same 1 s constant,
    /// reused rather than forked, for the same risky-edge reasoning
    /// documented on `iceGoodSinceMs` above.
    public func isVideoSendConfirmedHealthy(
        debounceMs: Int64 = SrtpFallbackDecisions.fallbackEngageDebounceMs
    ) -> Bool {
        // W-VIDEOSENDHEALTH (2026-08-27) — ICE being connected proves the
        // TRANSPORT is healthy, not that THIS call's video sender cryptor
        // ever actually attached. `attachVideoSenderCryptor()`'s own Bool
        // result was discarded at both its call sites — a transient
        // RTCFrameCryptor init failure left native RTP video silently
        // sending nothing (or nothing the peer's own cryptor would accept)
        // while this gate, keyed only on ICE timing, still declared native
        // video "confirmed healthy" and shut off the one working transport
        // (WS-relay) covering it. Live-call evidence (2026-08-27, two
        // consecutive iOS-iOS calls): video_frame relay traffic stopped
        // dead almost exactly at the 1s debounce mark every time, and no
        // video reached either peer for the rest of either call.
        guard let cryptor = peerConnection?.nativeVideoCryptor,
              cryptor.senderIsAttached, cryptor.keyIsSet else { return false }
        guard let since = iceGoodSinceMs else { return false }
        return Self.nowMs() - since >= debounceMs
    }

    /// Trigger an ICE restart by sending a fresh restart offer.
    ///
    /// W-RESPONDERRESTART (2026-08-26): BOTH roles ship a fresh offer now
    /// — previously only the ORIGINAL call initiator did, with the
    /// responder side a documented no-op (Android's own
    /// `pc.restartIce()` proactive-priming call for the responder side
    /// was never ported, for lack of toolchain to grep-verify that native
    /// symbol against this app's vendored webrtc-sdk binary). That left a
    /// real gap: a mid-call network change on the RESPONDER's own device
    /// had no fast recovery path of its own — only the initiator's
    /// independent ICE-bad detection eventually re-offering, strictly
    /// sequential and only as fast as the SLOWER side's own watchdog.
    ///
    /// This is safe to lift, verified against the real call graph rather
    /// than assumed:
    ///   - `sendIceRestartOffer` (`BCryptoCallingApiImpl.swift`) is
    ///     already role-agnostic — a plain `call_offer` envelope keyed by
    ///     `call_id`/`recipient_id`, nothing initiator-specific.
    ///   - `AppState`'s `call_incoming` restart-offer ROUTING (the check
    ///     that recognizes "this is a mid-call restart for my live call,
    ///     not a fresh call") is also role-agnostic — it matches on
    ///     `call_id`/sender/call-state alone, never `isInitiator`.
    ///   - `applyRemoteRestartOffer` already documents that its
    ///     `.responderRollbackThenApply` branch "can be reached by
    ///     either role" and was only unreachable for the initiator
    ///     because the responder never used to offer — i.e. the
    ///     receiving side was ALREADY built to expect this.
    ///   - `RestartIceDecisions.resolveIncomingOffer`'s glare tiebreak is
    ///     keyed on the call's FIXED original role (`isInitiator`), never
    ///     on who sent the offer that raced — so a responder's own offer
    ///     racing the initiator's still correctly loses under the exact
    ///     same, already-unit-tested politeness rule, no new conflict
    ///     resolution needed.
    /// The one thing genuinely NOT reproduced from Android's responder
    /// path is the proactive-priming HEAD START (local candidates already
    /// gathering the instant the network changes, before any offer is
    /// even built) — this responder-side call still goes through the
    /// same `createOffer(iceRestart: true)` + send path the initiator
    /// uses, so the correctness guarantee holds but the responder's own
    /// restart is exactly as fast as the initiator's, not faster.
    ///
    /// Debounced by `RestartIceDecisions.iceRestartDebounceMs` — a
    /// flapping interface must not spam fresh CallOffer frames. This is
    /// also what protects the new `W-PROACTIVEHANDOFF` interface-change
    /// trigger (`armRestartPathMonitor` above) from spamming on a bearer
    /// flag that flips without a real handover.
    public func restartIce(reason: String) async {
        guard peerConnection != nil, !intentionalShutdown else { return }
        guard let rid = recipientId else { return }
        // Atomic check-then-set — see `restartIceDebounceLock`'s own kdoc
        // for why this can no longer be a plain unguarded read+write now
        // that more than one trigger can call this method concurrently.
        let now = Date()
        // W-ASYNCLOCK (2026-08-29) — scoped `withLock` instead of a bare
        // `lock()`/`unlock()` pair: this method is `async`, where manual
        // lock/unlock is unavailable (a hard error under the Swift 6
        // language mode) because the two calls can land on different threads
        // and a suspension between them would hold the lock across an await.
        // The check-then-set stays exactly as atomic as before — that
        // atomicity is the whole point of this lock, and the scoped form
        // preserves it while making the no-suspension-inside guarantee
        // structural rather than a thing to remember.
        let debounced: Bool = restartIceDebounceLock.withLock {
            if let last = lastIceRestartAt,
               now.timeIntervalSince(last) * 1000 < Double(RestartIceDecisions.iceRestartDebounceMs) {
                return true
            }
            lastIceRestartAt = now
            return false
        }
        guard !debounced else {
            log?("restart_ice debounced=1 reason=\(reason)")
            return
        }
        onRestartAttemptStarted?()
        // W-RESPONDERREQFIRST (2026-08-30) — the RESPONDER asks the
        // offering leg to drive the fresh offer (`restart_ice_request`)
        // whenever the peer negotiated `restart-ice-req-v1`, instead of
        // shipping an offer of its own. W-RESPONDERRESTART's "both roles
        // offer" held only against iOS's own receive path: Android's
        // mid-call offer pump applies a crossing offer ONLY on the
        // responder (`!activeAsInitiator`) and its ring layer suppresses
        // the same call_incoming as a stale replay — so a responder offer
        // toward an Android initiator is discarded on arrival, and a
        // simultaneous two-sided handoff becomes offer-glare where BOTH
        // offers die (live: call 9df47801, 2026-08-30 — initiator stuck
        // CHECKING for minutes, responder convinced it recovered).
        // Request-first also removes the glare by construction: exactly
        // one leg ever authors restart offers. The fresh-offer path below
        // remains as the fallback for peers that never advertised the
        // request capability (old builds), where the receive paths that
        // DO accept responder offers are the only recovery there is.
        if !isInitiator, peerNegotiated()?.useRestartIceRequest == true {
            let reqSent = await callingApi.sendRestartIceRequest(recipientId: rid)
            log?("restart_ice req_sent=\(reqSent ? 1 : 0) reason=\(reason)")
            return
        }
        guard let pc = peerConnection else { return }
        // `audioOnly: true` here does NOT mean "drop video on restart" —
        // it only gates `createOffer`'s BUG2 pre-allocation of an EMPTY
        // sendrecv video transceiver when none exists yet. By the time a
        // restart can happen the call is already connected, so this PC's
        // transceivers (video included, if the call has video) are
        // whatever the ORIGINAL negotiation already established; that
        // existing state, not this flag, is what `createOffer` renegotiates
        // around — exactly the same as every other renegotiation path in
        // this class (e.g. `upgradeToVideo`) reusing the same `pc`. Android
        // mirrors this: its restart `createOffer(pc, iceRestart=true)` has
        // no audio/video distinction at all.
        let offerSdp: String? = await withCheckedContinuation { cont in
            pc.createOffer(audioOnly: true, iceRestart: true) { result in
                switch result {
                case .success(let sdp): cont.resume(returning: sdp)
                case .failure: cont.resume(returning: nil)
                }
            }
        }
        guard let sdp = offerSdp else {
            log?("restart_ice create_offer_failed=1 reason=\(reason)")
            return
        }
        log?("restart_ice offer_created=1 reason=\(reason)")
        // W-RESTARTOFFERPARK — `sendIceRestartOffer` owns the send+park
        // budget end to end (BCryptoCallingApiImpl, up to 45s under the
        // server's 60s disconnect-grace ceiling); this call does not block
        // on the park itself finishing beyond that method's own 5s
        // fast-path attempt.
        let sent = await callingApi.sendIceRestartOffer(
            recipientId: rid,
            sdp: sdp,
            capabilities: advertisedCapabilitiesFilter(CallCapabilities.localCaps())
        )
        log?("restart_ice sent=\(sent ? 1 : 0) reason=\(reason)")
    }

    /// W-OFFERGLARE — apply an incoming restart-offer `call_offer` for
    /// THIS already-connected call (same call_id, a NEW SDP body — the
    /// initiator's `restartIce` fresh offer). `AppState`'s `call_incoming`
    /// handler routes here INSTEAD OF `handleIncomingWebRtcOffer`'s
    /// "always build a fresh controller" path, which would discard this
    /// live call's entire PQC/audio/video state.
    ///
    /// SIGNALING-LOCK REENTRANCY CHECK (2026-08-25) — Android's
    /// `handleRemoteOffer` paid for this exact lesson live: the glare
    /// rollback is done INLINE, never via a helper that re-acquires
    /// `signalingMutex`, because Kotlin's coroutine `Mutex` is NOT
    /// reentrant and a nested `withLock` there deadlocks the call forever
    /// (see that method's own kdoc, `PeerConnectionHolder.kt`). Before
    /// writing the rollback call below, `QAudionPeerConnection.swift` was
    /// read in full for iOS's own analog of that lock. FINDING: this class
    /// holds NO app-level serializing lock/actor around its SDP operation
    /// sequence AT ALL — `createOffer`/`setRemoteOffer`/`createAnswer`/
    /// `rollbackLocalOffer` are thin completion-handler wrappers directly
    /// over `RTCPeerConnection`'s OWN native signaling-thread
    /// serialization, with no NSLock/DispatchQueue/actor wrapping the
    /// CALL CHAIN of "read state, decide, act" the way Android's
    /// `signalingMutex.withLock { ... }` wraps `handleRemoteOffer`'s
    /// entire body. The NSLock-guarded flags this file DOES use for the
    /// analogous class of race (`answerLock`/`hasAppliedRemoteAnswer`,
    /// `shutdownLock`/`intentionalShutdown`) are, by this codebase's own
    /// established convention, held ONLY for a synchronous test-and-set
    /// and released BEFORE any `await` — never spanning an SDP operation —
    /// which structurally rules out the reentrancy bug class Android hit,
    /// rather than requiring an "inline vs. helper" workaround to dodge
    /// it. This method follows that same discipline: it calls
    /// `pc.rollbackLocalOffer` / `pc.setRemoteOffer` / `pc.createAnswer`
    /// DIRECTLY, introduces no new lock of its own, and therefore cannot
    /// re-enter anything already held by its caller (the plain
    /// `DispatchQueue.main.async`-hopped WS handler closure in AppState —
    /// not a lock, just serial main-actor dispatch, which this `async`
    /// method suspends across normally, exactly like every other
    /// controller method already does).
    public func applyRemoteRestartOffer(sdp: String) async {
        guard let pc = peerConnection, let rid = recipientId else {
            log?("restart_offer_apply dropped=1 reason=noPeerConnection")
            return
        }
        guard sdp != lastAppliedRemoteRestartSdp else {
            log?("restart_offer_apply dropped=1 reason=duplicate")
            return
        }
        let localState: RestartIceDecisions.LocalSignalingState
        switch pc.signalingState {
        case .some(.stable):         localState = .stable
        case .some(.haveLocalOffer): localState = .haveLocalOffer
        default:                     localState = .other
        }
        switch RestartIceDecisions.resolveIncomingOffer(signalingState: localState, isInitiator: isInitiator) {
        case .initiatorIgnoreKeepPendingOffer:
            log?("restart_offer_apply glare=1 verdict=initiator_wins")
        case .ignoreUnexpectedState:
            log?("restart_offer_apply dropped=1 reason=unexpectedState")
        case .responderRollbackThenApply:
            log?("restart_offer_apply glare=1 verdict=responder_rollback")
            // W-SILENTPATHDEATH — real SDP work is about to happen on THIS
            // side too (rollback + setRemoteOffer + createAnswer, a real
            // round trip): extend the base W-ICEGRACE grace here as well,
            // mirroring `restartIce`'s own call on the offering side. Fires
            // on whichever role actually ends up doing the work — this
            // branch can be reached by either role (see
            // `RestartIceDecisions.resolveIncomingOffer`'s kdoc: an
            // initiator can land here too on a genuine glare loss, though
            // that never happens for the initiator by construction).
            onRestartAttemptStarted?()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                pc.rollbackLocalOffer { _ in cont.resume() }
            }
            await applyRestartOfferAndAnswer(pc: pc, sdp: sdp, recipientId: rid)
        case .applyNormally:
            onRestartAttemptStarted?()
            await applyRestartOfferAndAnswer(pc: pc, sdp: sdp, recipientId: rid)
        }
    }

    /// Second half of `applyRemoteRestartOffer`: set the (possibly
    /// post-rollback) remote offer, create the answer, ship it back.
    /// Extracted so both the glare and non-glare branches above share one
    /// copy. `hasVideo: true` unconditionally on `createAnswer` mirrors
    /// this class's OWN `createOffer`'s unconditional
    /// `"OfferToReceiveVideo": "true"` mandatory constraint (see
    /// `QAudionPeerConnection.createOffer`) — on a RENEGOTIATION the
    /// actual negotiated direction is governed by the already-established
    /// transceivers, not by this legacy constraint, so it is not read as
    /// "this restart turns video on".
    private func applyRestartOfferAndAnswer(pc: QAudionPeerConnection, sdp: String, recipientId: String) async {
        let setOk: Bool = await withCheckedContinuation { cont in
            pc.setRemoteOffer(sdp: sdp) { err in cont.resume(returning: err == nil) }
        }
        guard setOk else {
            log?("restart_offer_apply set_remote_failed=1")
            return
        }
        // W-ICELATEQUEUE — the restart offer's fresh candidates may have
        // raced it over the WS; drain whatever queued during the SRD.
        drainPendingRemoteIce()
        lastAppliedRemoteRestartSdp = sdp
        let answerSdp: String? = await withCheckedContinuation { cont in
            pc.createAnswer(hasVideo: true) { result in
                switch result {
                case .success(let s): cont.resume(returning: s)
                case .failure: cont.resume(returning: nil)
                }
            }
        }
        guard let answer = answerSdp else {
            log?("restart_offer_apply create_answer_failed=1")
            return
        }
        do {
            // W-SETUPRETRY's ladder is a no-op post-connection (see
            // `sendIceRestartOffer`'s kdoc for the same reasoning applied
            // to the offer side) — sent once, best-effort. The robustness
            // net here is the OFFERER's own recovery watchdog: if this
            // answer is lost, ICE stays bad on the initiator's side and
            // its watchdog re-fires `restartIce` on its backed-off settle
            // cadence, exactly mirroring how Android's watchdog loop (not
            // a dedicated answer-retry) is what actually makes a lost
            // restart-answer self-heal there too.
            try await callingApi.sendCallAnswer(
                recipientId: recipientId,
                sdp: answer,
                capabilities: advertisedCapabilitiesFilter(CallCapabilities.localCaps()),
                hasVideo: true
            )
            log?("restart_offer_apply answered=1")
        } catch {
            log?("restart_offer_apply send_answer_failed=1")
        }
    }

    // MARK: - Capability handshake (commit 540b79c0 parity)

    /// Forward the peer's `capabilities` array (extracted from the
    /// raw `call_offer` / `call_answer` / `call_incoming` envelope
    /// data dictionary) to the underlying peer connection for caching.
    ///
    /// `peer` is `nil` when the field is absent from the envelope —
    /// that's a legacy peer and the negotiated `useSFrame` will be
    /// `false` (no SFrame). Idempotent — calling twice in a row
    /// (e.g. duplicate call_answer like W418) is a no-op semantically.
    ///
    /// **Wiring** (AppState side, mirrors Kotlin
    /// `CallSetupHandler.onCallOfferEvent`):
    /// ```swift
    ///   ws.registerHandler(type: "call_offer") { _, data in
    ///       let caps = data["capabilities"] as? [String]
    ///       webRtcController.acceptPeerCapabilities(caps)
    ///       …
    ///   }
    /// ```
    public func acceptPeerCapabilities(_ peer: [String]?) {
        peerConnection?.acceptPeerCapabilities(peer)
        // WIRE_SPEC §8.7 / .legacy-latch fix — UPWARD re-evaluation only.
        // The AES-256 fail-close path (ensureVideoSealer) latches
        // `videoSealer = .legacy` when the caps known AT THAT MOMENT don't
        // advertise sframe-aes256-v1 (e.g. a caps-less duplicate envelope
        // negotiated an empty tag set first). Before this fix the latch was
        // permanent until closeSynchronously: a LATER caps update that DOES
        // satisfy the AES-256 requirement left the receiver cryptor
        // attached-but-unkeyed and discardFrameWhenCryptorNotReady dropped
        // every inbound frame — permanent black video. Clear the latch and
        // let ensureVideoSealerInternal below re-run the pick ONLY when the
        // fresh negotiation would now select the native path (useSFrame AND
        // the AES-256 gate satisfied). Strictly an upgrade: a peer that
        // still does NOT advertise aes256 keeps the fail-closed .legacy
        // latch (never auto-downgrade — downgrades stay explicit/close-only,
        // and `.native`/`.sframe`/`.livekit` picks are never touched).
        if case .legacy = videoSealer,
           let negotiated = peerNegotiated(),
           negotiated.useSFrame,
           !CallCapabilities.v4SFrameAes256Enabled || negotiated.useSFrameAes256 {
            let tags = negotiated.agreedTags
            print("[WebRtcCallController] .legacy latch CLEARED — caps update satisfies the video-sealer requirements (agreed=\(tags)); re-running pipeline pick")
            videoSealer = nil
        }
        // W539 — opportunistic install: if the PQC key is already
        // present (typical on responder path where the PQC handshake
        // ran BEFORE the WebRTC offer applied), install the LiveKit
        // cryptor now. On the caller path the key arrives later
        // via the pqcSessionKey didSet which also calls this.
        _ = ensureVideoSealerInternal()
        // F-02 — the re-run above may have installed the native cryptor after an
        // earlier evaluation fail-closed the lane. Lift the latch only once the
        // pick actually landed on `.native`: reopening on the strength of the caps
        // alone would send the frames before the cryptor exists.
        if case .native = videoSealer {
            peerConnection?.reopenVideoAfterE2eeAgreed()
        }
        // IOS-C4b — opportunistic install, same reasoning as the video
        // cryptor above: on the responder path the PQC key can already be
        // held by the time the peer's caps arrive.
        installAudioSrtpIfPossible()
    }

    /// IOS-C4b (2026-08-26) — install/rekey the native SRTP audio path the
    /// moment BOTH the peer's negotiated capabilities (`audioSrtpV1` in the
    /// intersection) AND a 32-byte PQC session key are available. Mirrors
    /// `ensureVideoSealerInternal` exactly: called from the SAME two trigger
    /// sites (`pqcSessionKey` didSet, `acceptPeerCapabilities`) plus the
    /// `didReceiveNativeAudioSrtpReceiver` opportunistic-install call —
    /// whichever of the three fires last completes the activation.
    /// Idempotent: `QAudionPeerConnection.activateNativeAudioSrtp` only
    /// creates the mic track/cryptor once; repeat calls (rekey) just
    /// re-publish the key.
    ///
    /// W-AUDIOSENDERGATE (2026-08-27) — `activateNativeAudioSrtp` now
    /// honestly reports whether the native FrameCryptor actually attached
    /// (it used to silently claim success and enable the mic regardless —
    /// see its own doc for the live-call symptom that produced). The three
    /// opportunistic trigger sites above cover the common "not ready yet"
    /// case, but none of them specifically retries a genuine attach
    /// *failure* (a transient RTCFrameCryptor construction race) — this
    /// bounded retry closes that gap without inventing new call-state:
    /// `installAudioSrtpIfPossible` already re-checks every precondition
    /// and is safe to call from any thread (NativeAudioFrameCryptor's own
    /// NSLock, RTCRtpTransceiver access unchanged from the existing
    /// multi-trigger design).
    private func installAudioSrtpIfPossible(retriesRemaining: Int = 5) {
        // W-SRTPKEYFWDRACE (2026-08-29) — these two guards used to return
        // completely silently. Live evidence (calls 27f4fb2a/3b184c12,
        // iOS<->iOS): audio-srtp negotiated true on both legs yet this
        // function never produced a single "audiosrtp tx=1", nor a retry
        // line, nor an exhaustion line — proof it was bailing HERE, at one
        // of these two guards, every single time it was invoked, with zero
        // way to tell which one without exactly this kind of archaeology.
        // Mirrors Android's loud PQC_DIAG-style logging at every such gate.
        // Numeric-only fields (see `startAudioIOIfReady`'s gate=N precedent
        // in CallService.swift): the remote-log redactor drops any
        // word=word field or compound word that isn't a bare number.
        guard let negotiated = peerNegotiated(), negotiated.useAudioSrtp else {
            print("audiosrtp install skip=1 reason=1")
            return
        }
        guard let key = pqcSessionKey, key.count == 32 else {
            print("audiosrtp install skip=1 reason=2")
            return
        }
        // W-AUDIORXPOSTNEG (2026-08-28) — this call site is reached only
        // once `negotiated.useAudioSrtp` is confirmed, which means the SDP
        // round that negotiated it has completed — the same "safe to
        // rebind" point the video path's post-negotiation rebind calls run
        // from. `didReceiveNativeAudioSrtpReceiver`'s own attach (fired
        // earlier, the moment the receiver track first appears) may have
        // bound against a pre-negotiation receiver object; re-binding here
        // is a no-op when it didn't (same receiver, cryptor already live)
        // and a real fix when it did. See NativeAudioFrameCryptor.
        // rebindReceiver's own doc for the live-call failure this closes.
        _ = peerConnection?.rebindAudioReceiverCryptorPostNegotiation()
        let participant = recipientId ?? "peer"
        let installed = peerConnection?.activateNativeAudioSrtp(
            key: key,
            participantId: participant,
            slot: pqcSessionKeyEpoch % 16,
            txSink: { [weak self] pcm in
                // PCM-TAP PARITY (TX/local mic) — mirrors Android's
                // `feedOwnerContinuity` wiring on `audioSrtpTxSink`. Tier 1
                // ("voce come chiave") is the only TX-side consumer; RX has
                // the larger consumer set (see the RX sink above).
                self?.onNativeAudioSrtpTxPcm?(pcm)
            },
            // W-AUDIOSENDDIAG — route the engine's decision line to the
            // remote log; the engine itself can only print().
            diag: { [weak self] line in self?.log?(line) }
        ) ?? false
        if installed {
            print("[WebRtcCallController] IOS-C4b: native audio-srtp TX activated (participant=\(participant))")
            print("audiosrtp tx=1")
        } else if retriesRemaining > 0 {
            print("[WebRtcCallController] IOS-C4b: native audio-srtp TX attach failed, retrying (\(retriesRemaining) left)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.installAudioSrtpIfPossible(retriesRemaining: retriesRemaining - 1)
            }
        } else {
            print("[WebRtcCallController] IOS-C4b: native audio-srtp TX attach exhausted retries — mic stays muted this call")
        }
    }

    /// Read the current peer-negotiated capability set. Returns `nil`
    /// when the peer has not yet been heard from (call_offer/answer
    /// not yet processed) — callers should treat that as "not ready
    /// to pick the video pipeline" and defer.
    public func peerNegotiated() -> CallCapabilities.Negotiated? {
        peerConnection?.peerNegotiated()
    }

    /// WIRE_SPEC §8.7 — one-shot latch for `onInboundVideoReady`. Set via
    /// the atomic test-and-set below (the controller is `@unchecked
    /// Sendable`: the receiver attach fires on the WebRTC signalling
    /// thread while the key can land from MainActor). Reset in
    /// `closeSynchronously()` for the next call.
    private let inboundReadyLock = NSLock()
    private var _inboundVideoReadyFired = false
    private func tryMarkInboundVideoReadyFired() -> Bool {
        inboundReadyLock.lock()
        defer { inboundReadyLock.unlock() }
        if _inboundVideoReadyFired { return false }
        _inboundVideoReadyFired = true
        return true
    }

    /// WIRE_SPEC §8.7 — fire `onInboundVideoReady` exactly once per call,
    /// the moment the receiver-side native cryptor is BOTH attached and
    /// keyed. Called from every site that can complete the pair last:
    /// the receiver attach (`didReceiveRemoteVideoReceiver`) and the
    /// keying paths (`ensureVideoSealerInternal`, reached from the
    /// `pqcSessionKey` didSet and `acceptPeerCapabilities`). Cheap no-op
    /// until both halves are true.
    private func notifyInboundVideoReadyIfNeeded() {
        guard let pc = peerConnection,
              let cryptor = pc.nativeVideoCryptor,
              cryptor.keyIsSet,
              cryptor.receiverIsAttached else { return }
        guard tryMarkInboundVideoReadyFired() else { return }
        let mid = pc.establishedVideoReceiverMid
        let midDesc: String = mid ?? "nil"
        print("[WebRtcCallController] inbound video READY (receiver cryptor attached+keyed, mid=" + midDesc + ") — signalling call_media_ready")
        // Android parity (PeerConnectionHolder.flushPendingCryptors): the
        // moment OUR receiver cryptor is ready, force OUR encoder's next
        // frame to be an IDR too — the peer's decoder gets a fresh
        // reference in <1s instead of waiting for the next ~5s periodic
        // one. Flag-queue only (consumed by KeyframeForcingVideoEncoder on
        // the next encode); harmless no-op if we are not sending video.
        VideoKeyframeController.shared.requestKeyFrame()
        onInboundVideoReady?(mid)
    }

    /// W539 — internal autopilot: install the LiveKit video cryptor as
    /// soon as BOTH the peer's negotiated caps and a 32-byte PQC key
    /// are available. Called from `acceptPeerCapabilities` and from
    /// the `pqcSessionKey` didSet so whichever arrives last triggers
    /// the install. Idempotent — once `videoSealer` is set, this is a
    /// no-op for the rest of the call. The keyProvider closure used by
    /// the LiveKit cryptor reads `self.pqcSessionKey` lazily on every
    /// frame, so audio-driven rekey rotations continue to be picked
    /// up transparently.
    ///
    /// `vkey-v1`: when the peer advertised `vkey-v1` (negotiated
    /// `useVideoKey == true`) the closure returns the dedicated 32-byte
    /// K_video derived from the CURRENT session key on every frame —
    /// `INSTEAD of` the raw `pqcSessionKey`. K_video binds the negotiated
    /// capability tags via the HKDF `info` (transcriptHash), so it is
    /// recomputed from `peerNegotiated().agreedTags` each frame. The
    /// per-frame HKDF is identical in cost to the existing one already
    /// done inside `LiveKitVideoFrameCryptor` (a second SHA-256-based
    /// HKDF, ~2 µs). When the peer did NOT advertise `vkey-v1` the
    /// closure returns the raw session key, preserving the W539 behaviour
    /// for older peers. The FrameCryptor params are UNCHANGED — K_video
    /// is the INPUT key fed to the cryptor's own internal HKDF, not the
    /// final AES key.
    @discardableResult
    private func ensureVideoSealerInternal() -> VideoCallSealer? {
        let sealer = ensureVideoSealer { [weak self] in
            guard let self = self else { return Data() }
            let sessionKey = self.pqcSessionKey ?? Data()
            // Only swap to K_video when BOTH sides advertised vkey-v1 and
            // we hold a full 32-byte session key. Anything else falls back
            // to the raw session key (legacy/pre-vkey-v1 wire behaviour).
            guard sessionKey.count == 32,
                  let negotiated = self.peerNegotiated(),
                  negotiated.useVideoKey else {
                return sessionKey
            }
            // CROSS-PLATFORM K_video: feed ONLY the canonical transcript tags
            // {sframe-v1, ratchet-v3, vkey-v1} — exactly what Android
            // `videoTranscriptTags` (PqcHandshake.kt:502) and Desktop
            // `agreedTagsFromFlags` build, and what the frozen
            // PhoneVideoKeyKatTests vector pins. `negotiated.agreedTags` also
            // contains `sframe-aes256-v1` / `dc-mux-v1`, which Android/Desktop
            // EXCLUDE — feeding the full set made iOS's HKDF transcriptHash
            // differ → a different K_video → Android/Desktop could not decrypt
            // iOS video and vice-versa (black/garbage). The KAT passed only
            // because it used the canonical 3-tag set, masking the runtime drift.
            let canonicalTags = negotiated.agreedTags.filter {
                $0 == CallCapabilities.sframeV1
                    || $0 == CallCapabilities.ratchetV3
                    || $0 == CallCapabilities.vkeyV1
            }
            return QAudionCallIntegration.deriveVideoKey(
                sessionKey: sessionKey,
                agreedTags: canonicalTags,
                psk: self.videoContactPsk
            )
        }
        // WIRE_SPEC §8.7 — a successful pick/rekey above may have just
        // completed the "receiver cryptor attached AND keyed" pair
        // (key/caps arriving AFTER the receiver attach). One-shot inside.
        notifyInboundVideoReadyIfNeeded()
        return sealer
    }

    /// Idempotently pick the video pipeline based on the peer's
    /// negotiated capabilities. Mirrors Android
    /// `CallController.ensureVideoSealer()` (commit 3db2cd81):
    ///
    /// - If ``videoSealer`` is already set → no-op (one pick per call).
    /// - If `peerNegotiated()` is `nil` (peer not heard from yet) →
    ///   leaves `videoSealer` unset; caller should defer.
    /// - W539: If `useSFrame=true` (peer advertised `sframe-v1`) AND
    ///   a 32-byte PQC session key is available → builds a
    ///   ``LiveKitVideoFrameCryptor`` and stores `.livekit(...)`. This
    ///   matches the wire format Desktop and Android actually emit
    ///   (despite the legacy `sframe-v1` tag name on the wire — see
    ///   `LiveKitFrameCryptor.ts` for the format spec).
    /// - Otherwise → stores `.legacy`, preserving today's behaviour
    ///   for legacy peers + tests.
    ///
    /// - Parameter pqcSessionKeyProvider: closure returning the
    ///   current 32-byte PQC session key. Typically backed by
    ///   `{ self.pqcSessionKey ?? Data() }` from the app layer.
    ///   The closure is captured by the resulting cryptor and called
    ///   on every frame so audio-driven rekey rotations are picked
    ///   up transparently.
    /// - Returns: the resolved sealer, or `nil` if the peer hasn't
    ///   been heard from yet.
    @discardableResult
    /// Non-reversible 3-byte (6 hex char) fingerprint of a key, for cross-
    /// platform key-match diagnostics only — never logs the key itself.
    /// Mirrors Android's matching helper in PeerConnectionHolder.kt so the
    /// two hex strings are directly comparable from one test call's logs.
    static func shortFingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    public func ensureVideoSealer(
        pqcSessionKeyProvider: @escaping () -> Data
    ) -> VideoCallSealer? {
        // REKEY: once the native cryptor is active, re-publish K_video on
        // session-key rotation (the native KeyProvider replaces the shared key
        // at index 0 in place — no cryptor rebuild). Do NOT no-op like the
        // other cases below.
        if case .native = videoSealer {
            let k = pqcSessionKeyProvider()
            if k.count == 32, let c = peerConnection?.nativeVideoCryptor {
                c.setKey(k, slot: pqcSessionKeyEpoch % 16)
                peerConnection?.attachVideoSenderCryptor()  // idempotent
                print("video key fp=\(Self.shortFingerprint(k)) rekey=1")
            }
            return videoSealer
        }
        if let existing = videoSealer { return existing }
        let negotiated = peerNegotiated()

        // F-02 — the three-way decision now lives in [VideoE2eeGate], shared verbatim
        // with Android and Desktop. It was an inline `if` on each platform and two of
        // the three drifted into a silent plaintext degrade; the drift WAS the finding.
        //
        // The key check stays below (the all-zero earbud placeholder has to be rejected
        // too), so `hasSessionKey` is passed conservatively as "the peer agreed" — the
        // gate's job here is to separate DEFER from FAIL_CLOSED, which is the
        // distinction that was missing.
        switch VideoE2eeGate.decide(
            hasSessionKey: true,
            peerHeardFrom: negotiated != nil,
            useSFrame: negotiated?.useSFrame ?? false
        ) {
        case .`defer`:
            return nil
        case .failClosed:
            if let n = negotiated {
                peerConnection?.failClosedVideo(reason: "peer did not advertise sframe-v1")
                videoSealer = .legacy
                print("[WebRtcCallController] video pipeline → FAIL-CLOSED (peerCaps=\(n.agreedTags), useSFrame=false)")
                return videoSealer
            }
            return nil
        case .install:
            break
        }
        guard let negotiated else { return nil }

        // When the peer advertised `sframe-v1` we install the NATIVE
        // RTCFrameCryptor (cross-platform-compatible, H265-safe). Until the PQC
        // key is available we DEFER (return nil) so a later key arrival via the
        // `pqcSessionKey` didSet retries — never latch `.legacy` while waiting.
        if negotiated.useSFrame {
            let kVideo = pqcSessionKeyProvider()
            // Fail closed: need a real 32-byte key; reject the all-zero
            // earbud-SPE placeholder (Android PeerConnectionHolder.kt:346-353).
            guard kVideo.count == 32, kVideo.contains(where: { $0 != 0 }) else {
                return nil  // defer until a real key arrives
            }

            // AES-256 kill-switch gate (v4SFrameAes256Enabled). When this build
            // requires AES-256 but the peer didn't advertise sframe-aes256-v1,
            // peer can't do our frame cipher: fall back to the .legacy sealer,
            // i.e. transport-only DTLS-SRTP (video still flows, without
            // frame-level E2EE). This is a DEGRADE, not a hard block — unlike
            // Android, which disables the video track outright. Reached only
            // against a legacy peer (all current clients advertise the tag).
            if CallCapabilities.v4SFrameAes256Enabled && !negotiated.useSFrameAes256 {
                // F-02 (2026-07-26) — this used to DEGRADE to DTLS-SRTP and keep
                // sending. The comment even said so: "video still flows, without
                // frame-level E2EE ... unlike Android, which disables the video
                // track outright". That asymmetry was the whole attack: strip one
                // plaintext capability string from the relayed caps and iOS is the
                // leg that keeps emitting readable video.
                print("[WebRtcCallController] sframe-aes256-v1 not advertised by peer (agreed=\(negotiated.agreedTags)); video FAIL-CLOSED")
                peerConnection?.failClosedVideo(reason: "peer did not advertise sframe-aes256-v1")
                videoSealer = .legacy
                return videoSealer
            }

            // Native libwebrtc RTCFrameCryptor on the RTP sender (and the
            // receiver, attached from the didReceiveRemoteVideoReceiver
            // delegate). Encrypts AFTER packetization → codec-agnostic / H265-
            // safe, byte-compatible with Android's native FrameCryptor. The
            // codec-layer LiveKit decorator is NO LONGER used (it broke H265).
            let participant = recipientId ?? "peer"
            let cryptor = peerConnection?.ensureNativeVideoCryptor(participantId: participant)
            cryptor?.setKey(kVideo, slot: pqcSessionKeyEpoch % 16)
            // W-VIDEOSENDHEALTH (2026-08-27) — attachVideoSenderCryptor()'s
            // Bool result used to be discarded here, and videoSealer is set
            // to .native unconditionally right below regardless of whether
            // the attach actually succeeded — the early-return guard above
            // (`if let existing = videoSealer { return existing }`) then
            // means this install branch never runs again for the rest of
            // the call, so the ONLY other retry was an incidental future
            // rekey (not guaranteed to ever happen). isVideoSendConfirmedHealthy
            // now honestly reflects real attach state either way, but a
            // bounded retry here gets native RTP video actually working
            // again instead of leaving the call stuck on WS-relay for its
            // whole duration.
            retryVideoSenderCryptorAttachIfNeeded(retriesRemaining: 5)
            videoSealer = .native
            videoKeyIsPhoneLevel = negotiated.useVideoKey
            let aes256Active = CallCapabilities.v4SFrameAes256Enabled && negotiated.useSFrameAes256
            let keyKind = negotiated.useVideoKey ? "K_video (phone-level)" : "session-key (legacy)"
            print("[WebRtcCallController] video pipeline → NATIVE RTCFrameCryptor key=\(keyKind) aes256=\(aes256Active) (peerCaps=\(negotiated.agreedTags))")
            print("video key fp=\(Self.shortFingerprint(kVideo)) uvk=\(negotiated.useVideoKey ? 1 : 0) rekey=0")
            return videoSealer
        }

        // Unreachable: the gate above already returned for every non-`useSFrame`
        // case. Kept as an assertion rather than deleted, because "the peer declined
        // and we fell through to here" is precisely the state that must never send.
        peerConnection?.failClosedVideo(reason: "unreachable fallthrough — refusing video")
        videoSealer = .legacy
        print("[WebRtcCallController] video pipeline → FAIL-CLOSED (unreachable fallthrough, peerCaps=\(negotiated.agreedTags))")
        return videoSealer
    }

    /// W-VIDEOSENDHEALTH (2026-08-27) — bounded retry for a transient
    /// `attachVideoSenderCryptor()` failure (RTCFrameCryptor init race,
    /// same class already fixed for native-audio-srtp today). Safe to call
    /// unconditionally: `attachSender` is idempotent (no-ops once already
    /// attached), so a retry after a success just confirms the same state.
    private func retryVideoSenderCryptorAttachIfNeeded(retriesRemaining: Int) {
        guard let pc = peerConnection, let cryptor = pc.nativeVideoCryptor else { return }
        if cryptor.senderIsAttached { return }
        let attached = pc.attachVideoSenderCryptor()
        if attached {
            print("[WebRtcCallController] W-VIDEOSENDHEALTH: video sender cryptor attach succeeded")
        } else if retriesRemaining > 0 {
            print("[WebRtcCallController] W-VIDEOSENDHEALTH: video sender cryptor attach failed, retrying (\(retriesRemaining) left)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.retryVideoSenderCryptorAttachIfNeeded(retriesRemaining: retriesRemaining - 1)
            }
        } else {
            print("[WebRtcCallController] W-VIDEOSENDHEALTH: video sender cryptor attach exhausted retries — staying on WS-relay this call")
        }
    }

    // MARK: - Camera capture

    /// Start the front-facing camera, targeting 1280×720@30fps, and wire
    /// its frames into the supplied RTCVideoSource. Gracefully picks the
    /// closest available format when 720p is not listed. iOS-only — the
    /// guard compiles away on macOS / Swift package unit-test targets.
    /// No-op when `useExternalVideoSource == true` (AppState's
    /// VideoCallPipeline owns the camera on that path).
    private func startCameraCapture(for source: RTCVideoSource) {
        #if os(iOS)
        if useExternalVideoSource {
            // VideoCallPipeline owns the camera. Create a pixel-buffer
            // capturer backed by this source so AppState can push frames
            // from the pipeline's AVCaptureSession into the WebRTC track.
            webrtcPixelBufferCapturer = WebRTCPixelBufferCapturer(delegate: source)
            return
        }
        #endif
        #if os(iOS)
        let devices: [AVCaptureDevice] = RTCCameraVideoCapturer.captureDevices()
        guard let camera: AVCaptureDevice = devices.first(where: { $0.position == .front }) ?? devices.first else {
            print("[WebRTC] startCameraCapture: no camera device found")
            return
        }
        let formats: [AVCaptureDevice.Format] = RTCCameraVideoCapturer.supportedFormats(for: camera)
        let targetW: Int32 = 1280
        let targetH: Int32 = 720
        let bestFormat: AVCaptureDevice.Format? = formats.min { a, b in
            let da: CMVideoDimensions = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db: CMVideoDimensions = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let diffA: Int32 = abs(da.width - targetW) + abs(da.height - targetH)
            let diffB: Int32 = abs(db.width - targetW) + abs(db.height - targetH)
            return diffA < diffB
        }
        guard let selectedFormat: AVCaptureDevice.Format = bestFormat else {
            print("[WebRTC] startCameraCapture: no supported format")
            return
        }
        let fps: Int = selectedFormat.videoSupportedFrameRateRanges
            .compactMap { Int($0.maxFrameRate) }
            .filter { $0 <= 30 }
            .max() ?? 30
        let capturer: RTCCameraVideoCapturer = RTCCameraVideoCapturer(delegate: source)
        localVideoCapturer = capturer
        capturer.startCapture(with: camera, format: selectedFormat, fps: fps) { [weak self] error in
            if let err = error {
                let desc: String = err.localizedDescription
                let line: String = "[WebRTC] camera capture failed: " + desc
                print(line)
                self?.localVideoCapturer = nil
            } else {
                // W466 — confirm the camera actually started so the
                // telemetry distinguishes "no video frames captured"
                // from "captured but not rendered/sent".
                print("[WebRTC] camera capture started ok — front camera streaming")
            }
        }
        #endif
    }

    private func stopCameraCapture() {
        #if os(iOS)
        localVideoCapturer?.stopCapture()
        localVideoCapturer = nil
        webrtcPixelBufferCapturer = nil
        #endif
    }

    // MARK: - Internal

    /// W383 — install (or re-install) the PqcRtpFrameSealer on the
    /// active peer connection. Safe to call on a nil key (no-op) or
    /// before the peer connection is up (no-op until next call to
    /// applyPqcSealerIfPossible after the connection is built).
    private func applyPqcSealerIfPossible() {
        guard let key = pqcSessionKey, key.count == 32 else { return }
        guard let pc = peerConnection else { return }
        do {
            // M-15: bind derived key to this call session. pqcCallId is set
            // by AppState before/alongside pqcSessionKey so both parties
            // derive the same per-call master key.
            let sealer = try PqcRtpFrameSealer(pqcSessionKey: key, callId: pqcCallId)
            pc.installPqcSealer(sealer)
            // C-1: installPqcSealer is intentionally a no-op on this
            // WebRTC binary (no RTCFrameEncryptor/Decryptor) — do NOT
            // claim PQC media protection. Media on the SRTP path is
            // protected by DTLS-SRTP only.
            let line: String = "[WebRtcCallController] PQC frame sealing UNAVAILABLE on this WebRTC build — media uses DTLS-SRTP only"
            print(line)
        } catch {
            let edesc: String = error.localizedDescription
            let eline: String = "[WebRtcCallController] PQC sealer construction failed: " + edesc
            print(eline)
        }
    }

    private func fetchIceServers() async -> [RTCIceServer] {
        // W411: when the user has explicitly configured a custom TURN
        // server in TransportSettings, bypass the server-side relay
        // pool fetch and use the override directly.
        if let override = iceServerOverride, !override.isEmpty {
            return override
        }
        guard let provider = relayProvider else { return [] }
        guard let bundle = await provider.currentOrRefresh() else { return [] }

        // W-RELAYGEO (2026-08-26, audit item 5) — order the relay list by
        // a lightweight client-measured RTT probe before handing it to
        // libwebrtc, so the nearest-measured relay(s) start ICE gathering
        // first. Bounded to ~1.2s worst case (`RelayOrderingConstants
        // .overallBudgetSec`) and never throws — a probe round that times
        // out, or a bundle with nothing probeable, degrades to the
        // server's original order exactly like before this change (see
        // `RelayOrdering.order`'s empty-map short-circuit). Does not
        // change which relay ICE ultimately SELECTS, only which candidates
        // it tries first.
        let relayRttByUrl = await RelayLatencyProbe().measureAll(bundle.servers)
        let orderedRelays = RelayOrdering.order(bundle.servers, rttMsByFirstUrl: relayRttByUrl)
        var servers = QAudionPeerConnectionFactory.iceServers(from: orderedRelays)

        // WSS-TURN bridge — last-resort bypass for corporate firewalls
        // that block UDP 3478, TCP 3478, and TURNS 5349. The server
        // exposes a WebSocket TURN proxy at /api/v1/turn-ws; we relay
        // raw TURN frames between a loopback UDP socket and that WSS
        // endpoint, presenting libwebrtc with a standard
        // turn:127.0.0.1:<port>?transport=udp entry.
        // Mirrors Android WssTurnBridge.kt and Desktop WssTurnBridge.ts.
        //
        // W-RELAYGATE (2026-08-26, P2 audit item 3) — this used to allocate
        // and insert the bridge UNCONDITIONALLY on every call that had TURN
        // credentials, ahead of the plain STUN/TURN entries `servers`
        // already carries. That is backwards for a "last-resort bypass":
        // the bridge was never actually gated behind any evidence the
        // direct UDP path needed bypassing.
        //
        // `relayRttByUrl` above is exactly that evidence, already paid for:
        // it is the real UDP STUN Binding round trip (`StunClient
        // .measureRttMs`, RFC 5389) to every relay's `turn:`/`stun:` URL,
        // run two lines up for latency ORDERING. A non-empty result means
        // at least one relay in OUR OWN fleet answered a raw UDP packet on
        // its STUN/TURN port — i.e. outbound UDP to this exact service
        // class is not blocked on this network, so the corporate-firewall
        // scenario the bridge exists for is, on this call's own measured
        // evidence, not what's happening. An EMPTY result — every probe in
        // the round timed out or the round itself hit its own overall
        // budget (`RelayLatencyProbe.measureAll`'s doc) — is the
        // "connectivity-check failure signal" the bridge should actually be
        // gated behind: no positive evidence direct UDP works, so fail
        // toward allocating the bypass exactly like before this change.
        // This adds no new network round trip and never makes call setup
        // slower than the ordering probe already made it.
        if relayRttByUrl.isEmpty,
           let wssUrlStr = bundle.wssTurnUrl,
           let wssUrl = URL(string: wssUrlStr),
           // Skip if bundle has no TURN entry with credentials — libwebrtc
           // needs real credentials inside the TURN ALLOCATE request.
           let firstTurn = bundle.servers.first(where: { s in
               s.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
           }),
           firstTurn.username != nil,
           firstTurn.credential != nil {
            // Route this bridge's WSS-TURN socket through the SAME Reality/Tor
            // tunnel the signaling socket uses when active (see
            // WssTurnBridge.socksPort doc) — otherwise a call's TURN media
            // traffic dials clearnet directly even while signaling is
            // tunneled. `activeSocksPort` is `nil` when Reality isn't
            // running, which preserves today's direct-dial behavior.
            let socksPort = await RealityManager.shared.activeSocksPort
            let bridge = WssTurnBridge(
                wssUrl: wssUrl,
                username: firstTurn.username,
                credential: firstTurn.credential,
                accessToken: accessToken,
                socksPort: socksPort.map(Int.init)
            )
            if let result = try? await bridge.start() {
                wssTurnBridge?.stop()
                wssTurnBridge = bridge
                servers.insert(
                    RTCIceServer(
                        urlStrings: [result.iceUrl],
                        username: firstTurn.username ?? "",
                        credential: firstTurn.credential ?? ""
                    ),
                    at: 0
                )
            }
        }

        return servers
    }

    public enum ControllerError: Error, Equatable {
        case wrongState(String)
        case noPeerConnection
        /// W536 — upgradeToVideo invoked but the PC already carries a
        /// local video track (a crossing acceptUpgradeOffer or an
        /// initial-video call). Treat as "already done", not a real
        /// failure; AppState surfaces it as a no-op.
        case alreadyHasVideo
        /// W536 — addLocalVideoTrack returned nil at upgrade time
        /// (PC tear-down race, factory failure, etc.).
        case videoAddFailed
    }

    // MARK: - QAudionPeerConnection.Delegate

    public func peerConnection(_ pc: QAudionPeerConnection,
                               didDiscoverLocalIceCandidate candidate: String,
                               sdpMid: String?,
                               sdpMLineIndex: Int32) {
        guard let rid = recipientId else { return }
        let mid: String? = sdpMid
        let mlineIdx: Int32 = sdpMLineIndex
        Task {
            try? await callingApi.sendIceCandidate(
                recipientId: rid,
                candidate: candidate,
                sdpMid: mid,
                sdpMLineIndex: mlineIdx
            )
        }
    }

    /// W-TURNSUSPECT (playbook §IOS-E4) — ICE gathering for this call
    /// finished with ZERO relay-type local candidates. `RelayCredentialsProvider`
    /// already forces a refresh after an explicit TURN auth failure; this is
    /// the complementary trigger for the failure mode that never surfaces one
    /// — a TURN allocation that silently returns nothing (expired secret,
    /// revoked realm) looks identical to "no relay servers were configured"
    /// from here, so any zero-count with a live provider is worth refreshing
    /// for. Never awaited / never blocks call setup: this call has already
    /// gathered what it's going to gather, so the refresh can only help the
    /// NEXT call on this provider.
    public func peerConnection(_ pc: QAudionPeerConnection,
                               didCompleteIceGatheringWithRelayCandidates count: Int) {
        guard count == 0, let provider = relayProvider else { return }
        // Verified against scripts/ship-ios-logs.py's redact_body (iOS
        // log-line rule): "turnsuspect count=0 refresh=1" survives the
        // structured-shape gate (the bracketed class-name prefix itself
        // gets blob-redacted, everything after it stays greppable
        // verbatim); the longer key names originally here
        // ("relay_candidates=0 forcing_refresh=1") pushed the free/
        // structural-word ratio over the gate's threshold and dropped the
        // whole line — re-verified 2026-08-25.
        print("[WebRtcCallController] turnsuspect count=0 refresh=1")
        Task {
            _ = try? await provider.credentials(forceRefresh: true)
        }
    }

    /// W-ROUTETIEREVENT (2026-08-26, P2 audit item 4) — react to a real
    /// libwebrtc "selected candidate pair changed" event instead of waiting
    /// for the next 3s `pollVideoStatsOnce` tick. `resolveAndApplyRouteTier`
    /// already de-duplicates internally (`_routeTierDwell.observe`, plus its
    /// own `pc.statistics` re-derivation of the actually-committed pair), so
    /// calling it early/often here is safe — worst case it repeats work the
    /// poll would have done anyway a little sooner. The 3s poll itself is
    /// UNCHANGED and keeps running for the whole call: this is additive
    /// belt-and-braces, not a replacement, matching how
    /// `didChangeIceConnectionState` below already triggers the same
    /// resolution once on connect.
    public func peerConnection(_ pc: QAudionPeerConnection,
                               didChangeSelectedCandidatePairChangeReason reason: String) {
        resolveAndApplyRouteTier()
    }

    public func peerConnection(_ pc: QAudionPeerConnection,
                               didChangeIceConnectionState s: RTCIceConnectionState) {
        // W-SILENTPATHDEATH — snapshot for the recovery watchdog's
        // "still bad after the self-repair window?" re-check. Written
        // here (the single ICE-state delegate callback) so the watchdog
        // never has to touch WebRTC objects off whatever thread this
        // fires on.
        lastIceConnectionState = s
        if s == .connected || s == .completed { hasEverConnectedIce = true }
        // W419 — log every ICE state transition. Crucial for diagnosing
        // "audio drops after 30s" bugs: typically ICE goes connected →
        // disconnected → failed when network is unstable, or stays
        // .checking forever if relays are blocked. Without this log we
        // had NO visibility into why audio stopped flowing.
        let stateName: String
        switch s {
        case .new:          stateName = "new"
        case .checking:     stateName = "checking"
        case .connected:    stateName = "connected"
        case .completed:    stateName = "completed"
        case .failed:       stateName = "failed"
        case .disconnected: stateName = "disconnected"
        case .closed:       stateName = "closed"
        case .count:        stateName = "count"
        @unknown default:   stateName = "unknown(\(s.rawValue))"
        }
        print("[WebRTC] ICE state → \(stateName)")
        // Numeric, not `stateName`: the redactor drops any line carrying a
        // run of 12+ base64-alphabet characters, and "disconnected" alone
        // is exactly 12 lowercase letters — the same trap the dcmux "why="
        // codes were already shortened to dodge. `s.rawValue` is what
        // survives to Loki; decode it against RTCIceConnectionState.
        log?("ice state=\(s.rawValue)")
        switch s {
        case .connected, .completed:
            state = .connected
            // Start outbound/inbound video RTP telemetry once media can flow.
            startVideoStatsTelemetry()
            resolveAndApplyRouteTier()
            // W-SILENTPATHDEATH — ICE genuinely recovered: stand the
            // recovery watchdog down. Mirrors Android's loop `continue`ing
            // past `self.first { !isBad(it) }`.
            disarmIceRecoveryWatchdog()
            // W-SRTPFALLBACK — same recovery instant, independent gate.
            disarmSrtpFallbackIfRecovered()
            // W-VIDEOSENDGATE — start (or leave running) the good-ICE
            // streak `isVideoSendConfirmedHealthy` debounces against.
            if iceGoodSinceMs == nil { iceGoodSinceMs = Self.nowMs() }
        case .failed, .disconnected:
            if s == .failed { state = .failed("ICE failed") }
            else { state = .disconnected; stopVideoStatsTelemetry() }
            // W-SILENTPATHDEATH — arm (or leave running) the recovery
            // watchdog. `.closed` is deliberately excluded — that is a
            // terminal, intentional teardown (closeSynchronously already
            // cancels the watchdog directly), not a recoverable path
            // death.
            armIceRecoveryWatchdogIfNeeded()
            // W-SRTPFALLBACK — same bad-ICE instant, independent debounce.
            armSrtpFallbackIfNeeded()
            // W-VIDEOSENDGATE — ungated: the video WS-relay send leg must
            // resume on the very next frame, not after any debounce.
            iceGoodSinceMs = nil
        case .closed:
            state = .disconnected
            stopVideoStatsTelemetry()
            disarmIceRecoveryWatchdog()
            srtpFallbackTask?.cancel()
            srtpFallbackTask = nil
            iceGoodSinceMs = nil
        default:
            break
        }
        onIceConnectionState?(s)
    }

    /// Aggregate ICE+DTLS state — distinct from the ICE-only handler above.
    /// ICE can report `.connected` while DTLS fails independently (bad cert,
    /// version mismatch, etc.), and only THIS callback observes that half.
    /// Same asymmetric-observer gap already found + fixed this session on
    /// Android (missing onConnectionChange). Transition to `.failed` on
    /// `.failed` here too, independent of the ICE path, so a DTLS-only
    /// failure is not silently unobserved.
    public func peerConnection(_ pc: QAudionPeerConnection,
                               didChangeConnectionState s: RTCPeerConnectionState) {
        let stateName: String
        switch s {
        case .new:          stateName = "new"
        case .connecting:   stateName = "connecting"
        case .connected:    stateName = "connected"
        case .disconnected: stateName = "disconnected"
        case .failed:       stateName = "failed"
        case .closed:       stateName = "closed"
        @unknown default:   stateName = "unknown(\(s.rawValue))"
        }
        print("[WebRTC] PeerConnection (ICE+DTLS) state → \(stateName)")
        // Numeric for the same redactor reason as the ICE branch above.
        log?("dtls state=\(s.rawValue)")
        if s == .failed {
            state = .failed("DTLS/connection failed")
        }
    }

    // MARK: - Video diagnostics telemetry

    /// Poll RTCPeerConnection statistics every 3 s and ship outbound +
    /// inbound video frame counts / codec to the telemetry sink. The iOS
    /// caller is the SENDER in the "iPad calls Android" scenario, so
    /// `out_frames_enc` answers "did the iPad actually encode+send video?"
    /// — the missing half of the Android-side `video.stats`.
    private func startVideoStatsTelemetry() {
        guard videoTelemetry != nil, videoStatsTimer == nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollVideoStatsOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        videoStatsTimer = timer
    }

    private func stopVideoStatsTelemetry() {
        videoStatsTimer?.invalidate()
        videoStatsTimer = nil
    }

    /// W-SHIELDWIRE — read the live, succeeded `candidate-pair` stat and
    /// resolve its `candidateType` ("relay"/"srflx"/"prflx"/"host") through
    /// the matching local/remote-candidate stats objects, then report the
    /// local type via `onActiveCandidatePairType` (UI shield badge).
    ///
    /// W-ROUTECLAMP (2026-08-25) — ALSO classifies the pair as
    /// `RouteTier.direct`/`.relay` (Android `PeerConnectionHolder
    /// .classifyFromStats`: relay if EITHER end's candidateType is
    /// "relay") and, on a REAL tier transition (including the first
    /// resolution of the call, not just later demotions — mirrors
    /// Android's W-ROUTECLAMP fix which explicitly stopped applying the
    /// policy "only once on the first Direct classification"), clamps the
    /// outgoing video sender's bitrate ceiling
    /// (`applyComposedVideoSenderClamp`) and fires
    /// `onLocalVideoCapBpsChanged` so AppState reports the new ceiling to
    /// the peer as our own W-BWCAP `VBWCAP:<bps>`.
    ///
    /// CALL SITES (mirrors Android's event callback + belt-and-braces
    /// poll, `PeerConnectionHolder.onSelectedCandidatePairChanged` +
    /// `startPairPolling`): once per ICE connect/reconnect from
    /// `didChangeIceConnectionState` (cheap — the common "settled on the
    /// first pair" case), on every real libwebrtc pair-selection event via
    /// `didChangeSelectedCandidatePairChangeReason` (see below — closes the
    /// gap this kdoc used to flag), AND every 3s from `pollVideoStatsOnce`
    /// for the WHOLE call as a belt-and-braces fallback (kept running,
    /// unshortened, unlike Android's 30s-post-connect-then-event-only cap —
    /// see the CPU-backpressure note below for why the poll cannot simply be
    /// narrowed to route-tier's own needs).
    ///
    /// VERIFICATION GAP — CLOSED (2026-08-26, P2 audit item 4). This kdoc
    /// used to say the equivalent of Android's `PeerConnection.Observer
    /// .onSelectedCandidatePairChanged` "could NOT be grep-verified" because
    /// no local xcframework header existed on this box to check against. It
    /// does now, verified for real rather than guessed: the pinned
    /// webrtc-sdk/webrtc `m144_release` tag's
    /// `sdk/objc/api/peerconnection/RTCPeerConnection.h` (fetched and
    /// grepped, not assumed) declares exactly the speculated selector,
    /// `@optional`, on `RTCPeerConnectionDelegate`:
    ///   `peerConnection:didChangeLocalCandidate:remoteCandidate:
    ///    lastReceivedMs:changeReason:`
    /// Wired in `QAudionPeerConnection` via an explicit `@objc(selector)`
    /// (see that method's own kdoc for why — the "wrong guess is silently
    /// never called" risk this comment used to warn about is sidestepped by
    /// pinning the literal selector string instead of trusting Swift's
    /// automatic Objective-C name import to guess it), forwarded here as
    /// `didChangeSelectedCandidatePairChangeReason`.
    ///
    /// The 3s poll stays, for a signal this event does NOT cover: outbound
    /// RTP `qualityLimitationReason` (the CPU-backpressure input to
    /// `evaluateBackpressure`) has no equivalent push event anywhere in the
    /// fetched `RTCPeerConnectionDelegate` header — only the stats API
    /// exposes it — so that half of this poll has no event-driven
    /// replacement and stays on the timer.
    ///
    /// RE-VERIFIED (2026-08-27, best-practices audit item 3) — the prior
    /// conclusion right above was checked ONLY against
    /// `RTCPeerConnectionDelegate`. This pass re-fetched and grepped the
    /// pinned `webrtc-sdk/webrtc` `m144_release` tag's ENTIRE ObjC SDK
    /// surface a CPU/encoder-load push event could plausibly live on, not
    /// just that one protocol:
    ///   - `sdk/objc/api/peerconnection/RTCPeerConnection.h` — the complete
    ///     `RTCPeerConnectionDelegate` protocol (both the `@required` block
    ///     and the `@optional` block) has exactly 14 methods: signaling
    ///     state, add/remove stream, renegotiation-needed, ICE connection/
    ///     gathering state, ICE candidate generate/remove, data channel
    ///     open, standardized ICE state, overall connection state,
    ///     start-receiving-on-transceiver, add/remove receiver, the
    ///     candidate-pair-changed one already wired above, and ICE-gather
    ///     failure. None carry an encoder-load/quality-limitation payload.
    ///   - `sdk/objc/api/peerconnection/RTCRtpSender.h` +
    ///     `RTCRtpSender+Native.h` — the sender is a plain property bag
    ///     (`parameters`, `track`, `streamIds`, `dtmfSender`) plus one
    ///     native-only method (`setFrameEncryptor:`). No delegate protocol,
    ///     no observer registration API of any kind.
    ///   - `sdk/objc/api/peerconnection/RTCPeerConnection+Stats.mm` — the
    ///     ACTUAL implementation backing every stats entry point
    ///     (`statisticsForSender:`, `statisticsForReceiver:`,
    ///     `statisticsWithCompletionHandler:`, `statsForTrack:...`) shows
    ///     they all route through `nativePeerConnection->GetStats(...)`
    ///     with a `StatsCollectorCallbackAdapter`/`StatsObserverAdapter`
    ///     whose `OnStatsDelivered`/`OnComplete` fires its Obj-C completion
    ///     handler EXACTLY ONCE per `GetStats()` call, then nils the
    ///     handler out (`completion_handler_ = nil`). There is no
    ///     persistent-subscription variant anywhere in this file — every
    ///     stats read, including `qualityLimitationReason`, is a one-shot
    ///     pull, confirmed from the adapter code itself rather than
    ///     inferred from the header alone.
    ///   - `sdk/objc/base/RTCVideoEncoder.h` — the protocol a CUSTOM
    ///     encoder implementation conforms TO (`setCallback:`,
    ///     `startEncodeWithSettings:...`, `encode:...`, `setBitrate:...`,
    ///     `scalingSettings`) — the app-facing direction is backwards from
    ///     what would be needed (this app doesn't implement a custom
    ///     encoder; it uses the SDK's built-in hardware H264/H265 path),
    ///     and even the QP-scaling hook here (`scalingSettings`) is a
    ///     THRESHOLD the app can SET, not an event the app RECEIVES.
    /// CONCLUSION UNCHANGED from `0aa6865`'s own: no event-driven
    /// replacement for the CPU-backpressure poll half exists in this SDK
    /// surface. This is not "not yet found" — it is "checked the surfaces
    /// where such a hook would have to live, and it is not there." The 3s
    /// poll (`evaluateBackpressure`, fed from `pollVideoStatsOnce`) stays
    /// exactly as-is; a tighter poll interval was considered and
    /// deliberately NOT applied — that would be re-labeling polling as
    /// "event-driven," not actually closing the gap.
    private func resolveAndApplyRouteTier() {
        guard let pc = peerConnection?.peerConnection else { return }
        pc.statistics { [weak self] report in
            guard let self else { return }
            let succeededPair = report.statistics.values.first { s in
                s.type == "candidate-pair" &&
                    ((s.values["state"] as? String) == "succeeded" ||
                        (s.values["nominated"] as? NSNumber)?.boolValue == true)
            }
            guard let pair = succeededPair else { return }
            var localType = ""
            if let localId = pair.values["localCandidateId"] as? String,
               let localStat = report.statistics[localId] {
                localType = (localStat.values["candidateType"] as? String) ?? ""
                if !localType.isEmpty { self.onActiveCandidatePairType?(localType) }
            }
            var remoteType = ""
            if let remoteId = pair.values["remoteCandidateId"] as? String,
               let remoteStat = report.statistics[remoteId] {
                remoteType = (remoteStat.values["candidateType"] as? String) ?? ""
                // W-VPNCALLGATE — `address` is the current W3C webrtc-stats
                // field name for a candidate's IP; `ip` is the deprecated
                // alias some older/ObjC-bridged stats dictionaries still use.
                // Same "no local xcframework header to confirm the exact
                // field this vendored build exposes" gap as the rest of this
                // method — try both rather than assert one, so a real
                // mismatch degrades to "gate never engages" (safe: call
                // media just stays tunneled, same as before this feature)
                // instead of crashing or silently reading garbage.
                let remoteHost = (remoteStat.values["address"] as? String)
                    ?? (remoteStat.values["ip"] as? String)
                if remoteHost != self._lastReportedRemoteHost {
                    self._lastReportedRemoteHost = remoteHost
                    self.onActiveCandidatePairRemoteHost?(remoteHost)
                }
            }
            let tier = RouteTier.classify(localType: localType, remoteType: remoteType)
            guard tier != .unknown else { return }
            // W-ROUTETIERDWELL — only a COMMITTED change (dwell-confirmed,
            // or the call's first-ever resolution) re-applies the sender
            // clamp / fires the ceiling-changed callback; a poll that
            // merely extends or resets an in-flight dwell returns `false`
            // and changes nothing observable yet.
            guard self._routeTierDwell.observe(tier) else { return }
            let committed = self._routeTierDwell.committed
            print("[WebRtcCallController] W-ROUTECLAMP: route tier -> \(committed) (local=\(localType) remote=\(remoteType))")
            // Numeric tail for the redactor, same reason as the ICE/DTLS
            // state lines above (relay=1/direct=0, never the word itself).
            self.log?("route tier=\(committed == .relay ? 1 : 0)")
            self.applyComposedVideoSenderClamp()
            if let ceiling = committed.senderMaxBitrateBps {
                self.onLocalVideoCapBpsChanged?(ceiling)
            }
            self.onRouteTierChanged?(tier)
        }
    }

    /// Compose ALL FOUR clamp layers into one effective sender ceiling and
    /// apply it: route tier (W-ROUTECLAMP) x CPU-backpressure step factor
    /// (W-BACKPRESSURE), floored at `VideoConstants.minVideoBitrateBps`,
    /// then intersected with the peer's reported VBWCAP (W-BWCAP) via
    /// `VideoBandwidthCap.clamp`, then intersected with the locally-measured
    /// GoogCC BWE ceiling (W-BWECOMPOSE, best-practices audit item 1) via
    /// `_bweSenderCeiling.ceilingBps` — re-floored afterward since
    /// intersecting four independent signals can in principle land below
    /// the same floor `localMax` was already clamped to above. Mirrors
    /// Android's documented `cap = min(local, remote-requested, relay)`
    /// composition (`AdaptiveQualityRuntime.localCapBps` doc), now with a
    /// real local-BWE term. No-op before the route tier has resolved at
    /// least once.
    private func applyComposedVideoSenderClamp() {
        guard let routeCeiling = _routeTierDwell.committed.senderMaxBitrateBps else { return }
        let backpressureFactor = pow(backpressureStepFactor, Double(_backpressureSteps))
        let localMax = max(VideoConstants.minVideoBitrateBps,
                           Int(Double(routeCeiling) * backpressureFactor))
        let peerClamped = VideoBandwidthCap.clamp(localMax)
        let finalMax = max(VideoConstants.minVideoBitrateBps,
                           min(peerClamped, _bweSenderCeiling.ceilingBps))
        applyVideoSenderMaxBitrate(finalMax)
    }

    /// Clamp the outgoing video RTP sender's per-encoding bitrate ceiling.
    /// Standard WebRTC W3C-mirroring API (`RTCRtpSender.parameters` — get,
    /// mutate `encodings[0].maxBitrateBps`, set back) — core WebRTC ObjC
    /// SDK surface unrelated to the AES256/PLI FrameCryptor patch, present
    /// in every WebRTC iOS build. No-op when there is no video sender yet
    /// (audio-only call, or video not yet negotiated) or no encoding
    /// entry (pre-negotiation transceiver).
    private func applyVideoSenderMaxBitrate(_ maxBps: Int) {
        guard let sender = peerConnection?.videoSender else { return }
        let params = sender.parameters
        let encodings = params.encodings
        guard !encodings.isEmpty else { return }
        encodings[0].maxBitrateBps = NSNumber(value: maxBps)
        sender.parameters = params
        print("[WebRtcCallController] W-ROUTECLAMP/W-BWCAP/W-BACKPRESSURE: video sender maxBitrateBps=\(maxBps)")
        log?("video maxbps=\(maxBps)")
    }

    /// W-BACKPRESSURE (2026-08-25) — `qualityLimitationReason == "cpu"`
    /// sustained for `backpressureSustainPolls` consecutive 3s polls
    /// steps the bitrate ceiling DOWN one notch (x0.7, same AIMD decrease
    /// factor as this app's legacy-pipeline `AbrController
    /// .abrDecreaseFactor`); `backpressureRecoverPolls` consecutive
    /// healthy polls step it back UP one notch. Re-applies the composed
    /// clamp on every step. No-op before the route tier has resolved
    /// (nothing to step down FROM yet).
    private func evaluateBackpressure(qualityLimitationReason: String) {
        guard _routeTierDwell.committed != .unknown else { return }
        if qualityLimitationReason == "cpu" {
            _healthyPolls = 0
            _cpuLimitedPolls += 1
            guard _cpuLimitedPolls >= backpressureSustainPolls,
                  _backpressureSteps < backpressureMaxSteps else { return }
            _cpuLimitedPolls = 0
            _backpressureSteps += 1
            print("[WebRtcCallController] W-BACKPRESSURE: CPU-limited -> step DOWN to level \(_backpressureSteps)")
            log?("backpressure step=\(_backpressureSteps) dir=0")
            applyComposedVideoSenderClamp()
            onCpuBackpressureStepsChanged?(_backpressureSteps)
        } else {
            _cpuLimitedPolls = 0
            guard _backpressureSteps > 0 else { return }
            _healthyPolls += 1
            guard _healthyPolls >= backpressureRecoverPolls else { return }
            _healthyPolls = 0
            _backpressureSteps -= 1
            print("[WebRtcCallController] W-BACKPRESSURE: recovered -> step UP to level \(_backpressureSteps)")
            log?("backpressure step=\(_backpressureSteps) dir=1")
            applyComposedVideoSenderClamp()
            onCpuBackpressureStepsChanged?(_backpressureSteps)
        }
    }

    private func pollVideoStatsOnce() {
        guard let pc = peerConnection?.peerConnection, let sink = videoTelemetry else { return }
        pc.statistics { report in
            var outFramesEnc = -1, outBytes = -1, outW = -1, outH = -1
            var outKeyFramesEnc = -1
            var outEncoderImpl = "", outQualityLimit = ""
            var inFramesDec = -1, inFramesRec = -1, inBytes = -1, inW = -1, inH = -1
            // VIDEO-DIAG (2026-07-12) — receiver freeze/render/drop counters from
            // the same inbound-rtp stats object (WebRTC-Stats §RTCInboundRtpStreamStats):
            // real evidence of playback stutter distinct from decode/receive counts.
            var inFreezeCount = -1, inFramesRendered = -1, inFramesDropped = -1
            var inTotalFreezesDur = -1.0
            var inCodecId = "", outCodecId = ""
            // W-VIDTELFPS (2026-07-24) — see the read sites below. `-1` sentinel
            // keeps the "never fabricate a value we did not measure" contract:
            // a stats report without framesPerSecond ships -1, which the reader
            // renders as "X" rather than as a fake 0 fps.
            var outFps = -1, inFps = -1
            for (_, s) in report.statistics {
                guard let kind = s.values["kind"] as? String, kind == "video" else { continue }
                if s.type == "outbound-rtp" {
                    outFramesEnc = (s.values["framesEncoded"] as? NSNumber)?.intValue ?? outFramesEnc
                    outBytes = (s.values["bytesSent"] as? NSNumber)?.intValue ?? outBytes
                    outW = (s.values["frameWidth"] as? NSNumber)?.intValue ?? outW
                    // BUG3 DIAG (2026-07-11) — frameHeight was previously only
                    // captured on the INBOUND side (asymmetric); this is the
                    // sender-side counterpart, plus the fields that tell us
                    // whether the H265 hardware encoder is actually running
                    // (encoderImplementation), throttling (qualityLimitationReason),
                    // and whether real IDRs are going out (keyFramesEncoded) —
                    // none of which this codebase read anywhere before.
                    outH = (s.values["frameHeight"] as? NSNumber)?.intValue ?? outH
                    outKeyFramesEnc = (s.values["keyFramesEncoded"] as? NSNumber)?.intValue ?? outKeyFramesEnc
                    outEncoderImpl = (s.values["encoderImplementation"] as? String) ?? outEncoderImpl
                    outQualityLimit = (s.values["qualityLimitationReason"] as? String) ?? outQualityLimit
                    outCodecId = (s.values["codecId"] as? String) ?? outCodecId
                    // W-VIDTELFPS (2026-07-24, call db4e5b20) — framesPerSecond was
                    // never read, so iOS shipped NO fps at all and the tuning card
                    // rendered "X" for both tx and rx fps while Android showed 30/30.
                    // WebRTC-Stats exposes it on BOTH rtp directions; the poll simply
                    // ignored it. Real client gap (distinct from the reader-side
                    // attribution/alias gaps fixed in tune-report.py W-VIDTELATTR).
                    outFps = (s.values["framesPerSecond"] as? NSNumber)?.intValue ?? outFps
                } else if s.type == "inbound-rtp" {
                    inFramesDec = (s.values["framesDecoded"] as? NSNumber)?.intValue ?? inFramesDec
                    inFramesRec = (s.values["framesReceived"] as? NSNumber)?.intValue ?? inFramesRec
                    inBytes = (s.values["bytesReceived"] as? NSNumber)?.intValue ?? inBytes
                    inW = (s.values["frameWidth"] as? NSNumber)?.intValue ?? inW
                    inH = (s.values["frameHeight"] as? NSNumber)?.intValue ?? inH
                    inFreezeCount = (s.values["freezeCount"] as? NSNumber)?.intValue ?? inFreezeCount
                    inTotalFreezesDur = (s.values["totalFreezesDuration"] as? NSNumber)?.doubleValue ?? inTotalFreezesDur
                    inFramesRendered = (s.values["framesRendered"] as? NSNumber)?.intValue ?? inFramesRendered
                    inFramesDropped = (s.values["framesDropped"] as? NSNumber)?.intValue ?? inFramesDropped
                    inCodecId = (s.values["codecId"] as? String) ?? inCodecId
                    // W-VIDTELFPS — receiver-side counterpart, same rationale.
                    inFps = (s.values["framesPerSecond"] as? NSNumber)?.intValue ?? inFps
                }
            }
            // Audit item 1 (2026-08-26, best-practices audit) —
            // OBSERVABILITY FIRST per the audit's own suggested approach
            // ("read GoogCC's own exposed stats into the existing 3s
            // pollVideoStatsOnce loop as observability first, then adapt
            // the WS-relay path's AbrController rule engine for the native
            // SRTP path too"). This reads the SAME `candidate-pair
            // .availableOutgoingBitrate` field (bits/sec) that already
            // ships in the standard, non-Google-prefixed webrtc-stats
            // surface — libwebrtc's GoogCC congestion controller is the
            // ONLY writer of this field; it is unmodified upstream BWE
            // output, not a Q-Audion invention. Distinct lookup from the
            // `outbound-rtp`/`inbound-rtp` loop above: a `candidate-pair`
            // stats row carries no `kind` field, so the `kind == "video"`
            // guard above would silently skip it — mirrors the identical
            // succeeded-pair search `resolveAndApplyRouteTier` already
            // does for route-tier classification, kept separate here
            // rather than threaded through that method so this stays a
            // pure read with zero effect on route-tier/backpressure
            // behavior.
            //
            // PHASE 2 — W-BWECOMPOSE (2026-08-27, best-practices audit item
            // 1). This used to be read-only ("no app-level congestion
            // response is wired to it yet"). It now is: right below,
            // `_bweSenderCeiling.observe` folds this same sample into the
            // pure `BweSenderCeiling` decision helper (see its own kdoc for
            // the AIMD-mirroring shape and the composition into
            // `applyComposedVideoSenderClamp`), on a `true` return
            // (ceiling actually changed) re-applying the composed sender
            // clamp. The real-libwebrtc GoogCC computation this value comes
            // from is still untouched — this only ever narrows what the
            // RTP sender's `maxBitrateBps` is set to, one more min() term
            // alongside route-tier/backpressure/VBWCAP.
            var bweAvailableOutgoingBps = -1.0
            if let activePair = report.statistics.values.first(where: { s in
                    s.type == "candidate-pair" &&
                        ((s.values["state"] as? String) == "succeeded" ||
                            (s.values["nominated"] as? NSNumber)?.boolValue == true)
                }) {
                bweAvailableOutgoingBps = (activePair.values["availableOutgoingBitrate"] as? NSNumber)?.doubleValue
                    ?? bweAvailableOutgoingBps
            }
            if self._bweSenderCeiling.observe(rawAvailableOutgoingBps: bweAvailableOutgoingBps) {
                self.applyComposedVideoSenderClamp()
            }
            // Resolve codec mimeType + the ACTIVE sdpFmtpLine from the
            // referenced codec stats object — the fmtp Chromium/libwebrtc
            // actually negotiated (profile-id/tier-flag/level-id for H265),
            // independent of and complementary to raw-SDP-text inspection at
            // offer-creation time (see createOffer below).
            func mime(_ id: String) -> String {
                guard !id.isEmpty, let c = report.statistics[id] else { return "?" }
                return (c.values["mimeType"] as? String) ?? "?"
            }
            func fmtp(_ id: String) -> String {
                guard !id.isEmpty, let c = report.statistics[id] else { return "?" }
                return (c.values["sdpFmtpLine"] as? String) ?? "?"
            }
            // W-VIDTELATTR (2026-07-24, call db4e5b20) — carry the call_id. Android's
            // video.stats has always had one; iOS's had NONE anywhere in the record,
            // so the server-side tuning card could not find these events by call at
            // all (its primary lookup greps the jsonl for the call id) and fell back
            // to a session_id pass that then discarded them. Net effect: 23 real iOS
            // video.stats records per call were invisible and the card printed
            // "! video rx/tx: ios blind" — reading as "iOS never touched the camera"
            // when iOS had in fact encoded 948 frames. Matches how `video.stall`
            // already ships its call_id (inside attrs), so it is greppable exactly
            // like every other per-call video event. Emitted only when non-empty:
            // never fabricate an id we do not have.
            var statsAttrs: [String: Any] = [
                "out_frames_enc": outFramesEnc,
                "out_key_frames_enc": outKeyFramesEnc,
                "out_bytes": outBytes,
                "out_frame_w": outW,
                "out_frame_h": outH,
                "out_encoder_impl": outEncoderImpl.isEmpty ? "?" : outEncoderImpl,
                "out_quality_limit": outQualityLimit.isEmpty ? "?" : outQualityLimit,
                "out_codec": mime(outCodecId),
                "out_fmtp": fmtp(outCodecId),
                "in_frames_rec": inFramesRec,
                "in_frames_dec": inFramesDec,
                "in_bytes": inBytes,
                "in_frame_w": inW,
                "in_frame_h": inH,
                "in_freeze_count": inFreezeCount,
                "in_total_freezes_dur": inTotalFreezesDur,
                "in_frames_rendered": inFramesRendered,
                "in_frames_dropped": inFramesDropped,
                "in_codec": mime(inCodecId),
                "in_fmtp": fmtp(inCodecId),
                // W-VIDTELFPS — real measured fps on both directions (was never read).
                "out_fps": outFps,
                "in_fps": inFps,
                // Audit item 1 — GoogCC's own live send-bandwidth estimate,
                // read-only (see the extraction site above for why this is
                // a separate lookup from the rtp rows above it). -1 = no
                // succeeded pair yet / field absent, never a fabricated 0.
                "bwe_available_outgoing_bps": bweAvailableOutgoingBps,
            ]
            let cid = self.pqcCallId
            if !cid.isEmpty { statsAttrs["call_id"] = cid }
            sink("video.stats", statsAttrs)
            // WIRE_SPEC §8.7 (INT-4a) — receiver decode-stall detection. Runs
            // on the stats callback thread; the controller is @unchecked
            // Sendable and these fields are touched ONLY here + on close (the
            // 3s single-timer serializes them).
            self.evaluateVideoStall(framesDecoded: inFramesDec, bytesReceived: inBytes)
            // W-BACKPRESSURE (2026-08-25) — CPU-limited encoder step-down,
            // fed by the SAME outbound-rtp `qualityLimitationReason` this
            // poll already reads for `out_quality_limit` above.
            self.evaluateBackpressure(qualityLimitationReason: outQualityLimit)
            // W-ROUTECLAMP (2026-08-25) — belt-and-braces poll for the
            // WHOLE call (not just post-connect): catches a silent
            // Direct<->Relay route demotion under continual ICE gathering
            // that `didChangeIceConnectionState` alone would miss. See
            // `resolveAndApplyRouteTier`'s doc for why this is a second,
            // separate `pc.statistics` round-trip rather than reusing
            // `report` directly (avoids a cross-closure typed-parameter
            // guess this box cannot grep-verify).
            self.resolveAndApplyRouteTier()
        }
    }

    /// WIRE_SPEC §8.7 (INT-4a) — decide whether the inbound video decode has
    /// stalled and, if so, fire `onVideoStallDetected` so AppState can nudge
    /// the sender via `video_keyframe_request`. Pure state machine over the
    /// monotonic `framesDecoded` / `bytesReceived` counters:
    ///   - no inbound video yet (framesDecoded < 0): reset, do nothing.
    ///   - framesDecoded advanced since last poll: healthy, reset.
    ///   - framesDecoded flat BUT bytesReceived advanced (frames arriving,
    ///     none decoding → missing keyframe): count a stalled poll; at the
    ///     threshold, fire once and re-arm (so a persistent stall re-nudges
    ///     every threshold window, the API-layer 1/s limiter absorbing bursts).
    ///   - framesDecoded flat AND bytesReceived flat (no media at all): NOT a
    ///     decode stall (nothing to recover) → reset, don't nudge.
    private func evaluateVideoStall(framesDecoded: Int, bytesReceived: Int) {
        // No inbound video RTP present (no inbound-rtp video stat) → nothing
        // to recover. The -1 sentinel means the stat was absent this poll.
        guard framesDecoded >= 0 else {
            _lastFramesDecoded = -1
            _lastBytesReceived = -1
            _videoStallPolls = 0
            return
        }
        let framesAdvanced = _lastFramesDecoded >= 0 && framesDecoded > _lastFramesDecoded
        let bytesAdvanced = _lastBytesReceived >= 0 && bytesReceived > _lastBytesReceived
        defer {
            _lastFramesDecoded = framesDecoded
            _lastBytesReceived = bytesReceived
        }
        // First observation (no prior sample) → establish the baseline only.
        guard _lastFramesDecoded >= 0 else {
            _videoStallPolls = 0
            return
        }
        if framesAdvanced {
            _videoStallPolls = 0
            return
        }
        // Frames flat. Only a STALL if bytes are still arriving (frames land
        // but don't decode → decoder waiting on a keyframe). No bytes = idle.
        guard bytesAdvanced else {
            _videoStallPolls = 0
            return
        }
        _videoStallPolls += 1
        if _videoStallPolls >= videoStallPollThreshold {
            _videoStallPolls = 0  // re-arm for the next window
            print("[WebRtcCallController] INT-4a — inbound video decode STALLED (framesDecoded flat, bytes still arriving) → requesting keyframe")
            onVideoStallDetected?()
        }
    }

    public func peerConnection(_ pc: QAudionPeerConnection,
                               didChangeSignalingState s: RTCSignalingState) {
        // W419 — log signaling state transitions for end-to-end visibility
        // into the SDP exchange flow.
        let stateName: String
        switch s {
        case .stable:               stateName = "stable"
        case .haveLocalOffer:       stateName = "haveLocalOffer"
        case .haveLocalPrAnswer:    stateName = "haveLocalPrAnswer"
        case .haveRemoteOffer:      stateName = "haveRemoteOffer"
        case .haveRemotePrAnswer:   stateName = "haveRemotePrAnswer"
        case .closed:               stateName = "closed"
        @unknown default:           stateName = "unknown(\(s.rawValue))"
        }
        print("[WebRTC] signaling state → \(stateName)")
    }

    public func peerConnection(_ pc: QAudionPeerConnection,
                               didReceiveRemoteAudioTrack track: RTCAudioTrack) {
        // W466 — confirm the remote audio track arrived. If this never
        // logs, the peer never published audio (or SDP m-line missing).
        //
        // IOS-C4b (2026-08-26) — when both peers negotiated
        // CallCapabilities.audioSrtpV1, `pc.usingNativeAudioSrtp` is already
        // `true` (set inside `QAudionPeerConnection`'s own `didAdd
        // rtpReceiver`, BEFORE this delegate callback runs) and the track is
        // ALREADY the real call audio — this is the ONE case where W574d's
        // disable must NOT run, or the native audio-srtp path would play
        // silence despite negotiating correctly.
        guard !pc.usingNativeAudioSrtp else {
            print("[WebRTC] remote AUDIO track received — audio-srtp negotiated, playback stays ENABLED (native path)")
            onRemoteAudioTrack?(track)
            return
        }
        // W574d — DISABLE playback of the remote SRTP audio. Voice rides
        // the sealed relay path only; the Android peer keeps its SRTP mic
        // track enabled, and before this gate its voice played out of the
        // loudspeaker DURING RING (the responder's answer is created at
        // call_incoming time, so ICE+DTLS complete pre-answer — there is
        // no CallKit/session gate on WebRTC playout). Disabling the track
        // also stops the post-answer double-audio (SRTP + relay).
        track.isEnabled = false
        print("[WebRTC] remote AUDIO track received — playback disabled (sealed relay carries voice)")
        onRemoteAudioTrack?(track)
    }

    /// IOS-C4b (2026-08-26) — attach the native AUDIO FrameCryptor + the
    /// PCM-tap-parity RX renderer to the inbound SRTP audio receiver. Runs
    /// on the WebRTC signalling thread. Mirrors
    /// `didReceiveRemoteVideoReceiver` immediately above and Android's
    /// `PeerConnectionHolder.onTrack` AUDIO_SRTP_V1 branch
    /// (`pendingReceiverForAudioCryptor` + `flushPendingAudioCryptors`).
    public func peerConnection(_ pc: QAudionPeerConnection,
                               didReceiveNativeAudioSrtpReceiver receiver: RTCRtpReceiver) {
        let participant = recipientId ?? "peer"
        let attached = pc.attachAudioReceiverCryptor(receiver, participantId: participant) { [weak self] pcm in
            // PCM-TAP PARITY — see NativeAudioPcmTap's own doc. Feeds the
            // SAME Guardian/VoiceAnalysis/ContactVoiceVerifier/
            // VoiceLearningSession consumers the sealed-DataChannel decode
            // path already feeds; `processIncomingAudio` never runs on an
            // audio-srtp call (the peer sends real RTP, not sealed frames),
            // so without this wiring those consumers would silently see
            // zero frames for the call's whole life.
            self?.onNativeAudioSrtpRxPcm?(pcm)
        }
        print("[WebRtcCallController] IOS-C4b: native audio receiver cryptor attached=\(attached) participant=\(participant)")
        // W-SRTPRXDIAG (2026-08-30) — remote-visible twin of the print
        // above. `rxc` is redactor-verified; "rxcryptor" is silently
        // dropped by ship-ios-logs.py, which is exactly how the silent
        // iOS<->iOS call on 1049 ended up with NO remote evidence of
        // whether the receiver cryptor ever attached.
        log?("audiosrtp rxc=\(attached ? 1 : 0)")
        // Publish the session key now if it's already held (idempotent —
        // same "opportunistic install" pattern as the video receiver
        // handler right above); the pqcSessionKey didSet / acceptPeerCapabilities
        // paths (re)publish on arrival/rotation.
        installAudioSrtpIfPossible()
    }

    public func peerConnection(_ pc: QAudionPeerConnection,
                               didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        // W466 — confirm the remote video track arrived.
        print("[WebRTC] remote VIDEO track received — enabled=\(track.isEnabled)")
        // R-4 (sovereign-only): a sovereign user only accepts video under
        // sovereign-grade keys; phone-level K_video does not qualify, so
        // when the policy is on we REJECT incoming video outright rather
        // than rendering it. Disable the track (stops decode/render) and
        // do NOT forward it to the UI callback. Mirrors Android rejecting
        // incoming video under sovereign-only.
        if shouldRejectIncomingVideo() {
            track.isEnabled = false
            print("[WebRTC] remote VIDEO track REJECTED — sovereign-only policy active (R-4)")
            return
        }
        // Remote diagnostics: the inbound video track arrived on the iOS side.
        videoTelemetry?("video.remote_track", [
            "track_id": track.trackId,
            "enabled": track.isEnabled,
            "use_sframe": peerNegotiated()?.useSFrame ?? false,
        ])
        onRemoteVideoTrack?(track)
    }

    /// Attach the native RTCFrameCryptor to the inbound video receiver (decrypts
    /// peer video). Runs on the WebRTC signalling thread (correct place to build
    /// RTCFrameCryptor). Mirrors Android enableVideoFrameCryptorOnReceiver.
    public func peerConnection(_ pc: QAudionPeerConnection,
                               didReceiveRemoteVideoReceiver receiver: RTCRtpReceiver) {
        // R-4: never attach a receiver cryptor when rejecting incoming video
        // (the track is already disabled in didReceiveRemoteVideoTrack).
        if shouldRejectIncomingVideo() { return }
        // Create the cryptor holder now even if the PQC key hasn't arrived — the
        // KeyProvider discards frames until setKey runs, so attaching the
        // receiver early avoids the receiver-before-key deadlock.
        let cryptor = pc.ensureNativeVideoCryptor(participantId: recipientId ?? "peer")
        // W-KFFAST (2026-08-25) — wire the cryptor's decrypt-fail state
        // callback to the controller's own closure. Idempotent (re-assigns
        // the same closure) across every `didReceiveRemoteVideoReceiver`
        // call, including relatch/rebind — the closure lives on the
        // OUTER `NativeVideoFrameCryptor` holder, not the transient
        // `RTCFrameCryptor` instance `attachReceiver`/`rebindReceiver`
        // recreate underneath it, so it survives a mid-call rebind
        // without needing to be re-set there.
        cryptor.onDecryptFailure = { [weak self] in
            print("[WebRtcCallController] W-KFFAST: receiver cryptor decrypt-fail — requesting peer keyframe")
            self?.onDecryptFailureDetected?()
        }
        // Publish K_video if we already hold a session key (idempotent); the
        // pqcSessionKey didSet path (re)publishes it on arrival/rotation.
        _ = ensureVideoSealerInternal()
        let attached = pc.attachVideoReceiverCryptor(receiver)
        print("[WebRtcCallController] native video receiver cryptor attached=\(attached)")
        print("video rx att=\(attached ? 1 : 0) uvk=\((peerNegotiated()?.useVideoKey ?? false) ? 1 : 0)")
        // WIRE_SPEC §8.7 — the attach may have just completed the
        // "receiver cryptor attached AND keyed" pair (receiver arriving
        // AFTER key+caps). One-shot inside.
        notifyInboundVideoReadyIfNeeded()
    }
}
#endif
