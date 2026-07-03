import Foundation
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
    public var onRemoteAudioTrack: ((RTCAudioTrack) -> Void)?
    public var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?

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

    /// W-DCAUDIO — inbound sealed-audio frames received over the WebRTC
    /// DataChannel ("qaudion-audio"). Set by the app layer (CallService) to route
    /// the raw WireRelayFrameCodec bytes into `handleIncomingEncryptedFrame`,
    /// exactly as the WS "audio_frame" handler does. Forwarded to the live
    /// `QAudionPeerConnection.onAudioDataChannelFrame` when the PC is created.
    public var onAudioDataChannelFrame: ((Data) -> Void)?

    /// W-DCAUDIO — send a sealed audio frame over the DataChannel if it is open.
    /// Returns `true` if queued on the DC; `false` if the DC is not open, in which
    /// case the caller (CallService) falls back to the WS relay.
    @discardableResult
    public func sendAudioFrameData(_ data: Data) -> Bool {
        return peerConnection?.sendAudioFrameData(data) ?? false
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
    public var pqcSessionKey: Data? {
        didSet {
            applyPqcSealerIfPossible()
            // W539 — when the PQC key arrives (or rotates), retry the
            // video pipeline pick. ensureVideoSealer needs BOTH the
            // peer's negotiated caps AND a 32-byte key to install the
            // LiveKit cryptor; whichever arrives last triggers the
            // install via this didSet or acceptPeerCapabilities below.
            _ = ensureVideoSealerInternal()
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

    private let callingApi: CallingApi
    private let relayProvider: RelayCredentialsProvider?
    private var peerConnection: QAudionPeerConnection?
    private var wssTurnBridge: WssTurnBridge?
    private var masqueTurnBridge: MasqueTurnBridge?
    private var recipientId: String?
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
        state = .outgoingOffering
        self.recipientId = recipientId

        let iceServers = await fetchIceServers()
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
        peerConnection = pc
        pc.addLocalAudioTrack()
        // W-DCAUDIO — wire inbound DataChannel audio to the app, then create the
        // outbound sealed-audio DataChannel (CALLER side, BEFORE createOffer so
        // the SDP carries the m=application audio section). Voice rides this DC
        // (P2P) with the WS relay as fallback; there is no m=audio SRTP track.
        pc.onAudioDataChannelFrame = { [weak self] data in self?.onAudioDataChannelFrame?(data) }
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
                capabilities: advertisedCapabilitiesFilter(CallCapabilities.local),
                callerDisplay: callerDisplay,
                hasVideo: callHasVideo
            )
        } else {
            try await callingApi.sendCallOffer(
                recipientId: recipientId,
                sdp: sdp,
                capabilities: advertisedCapabilitiesFilter(CallCapabilities.local),
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
    }

    // MARK: - Incoming

    public func acceptIncomingCall(callerId: String, offerSdp: String, audioOnly: Bool = true) async throws {
        guard state == .idle || state == .disconnected else {
            throw ControllerError.wrongState(String(describing: state))
        }
        hasAppliedRemoteAnswer = false   // W418 — fresh call, reset idempotency flag
        state = .incomingAnswering
        self.recipientId = callerId

        let iceServers = await fetchIceServers()
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
        peerConnection = pc
        pc.addLocalAudioTrack()
        // W-DCAUDIO — CALLEE side: wire inbound DataChannel audio to the app. The
        // caller created the sealed-audio DataChannel; we receive it via the PC's
        // `didOpen` delegate. No m=audio SRTP track is added.
        pc.onAudioDataChannelFrame = { [weak self] data in self?.onAudioDataChannelFrame?(data) }
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
            capabilities: advertisedCapabilitiesFilter(CallCapabilities.local),
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
        self.recipientId = callerId
        let iceServers = await fetchIceServers()
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
        peerConnection = pc
        pc.addLocalAudioTrack()
        pc.onAudioDataChannelFrame = { [weak self] data in self?.onAudioDataChannelFrame?(data) }
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
        let source: RTCVideoSource? = pc.addLocalVideoTrack()
        guard let videoSource = source else {
            videoUpgradeInProgress = false
            throw ControllerError.videoAddFailed
        }
        // startCameraCapture branches on useExternalVideoSource:
        // - true  → creates WebRTCPixelBufferCapturer, AppState will
        //           re-wire VideoCallPipeline.onCapturedPixelBuffer.
        // - false → opens the front camera via RTCCameraVideoCapturer.
        startCameraCapture(for: videoSource)

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

    // MARK: - WIRE_SPEC §8.7 — sender-side IDR forcing + TX-hold

    /// §8.7 TX-hold state. `true` while the LOCAL video track is held
    /// disabled waiting for the peer's `call_media_ready` (or the 2s
    /// timeout). NSLock-protected because the controller is
    /// `@unchecked Sendable` (upgrade methods resume on arbitrary
    /// executors; the release can come from the WS handler hop).
    private let txHoldLock = NSLock()
    private var _videoTxHoldArmed = false
    private var _videoTxHoldTimeoutTask: Task<Void, Never>?

    /// WIRE_SPEC §8.7 (INT-4a) — force an IDR on the next WebRTC-rail
    /// `encode()`: sets the process-wide force-next flag consumed by the
    /// `KeyframeForcingVideoEncoder` wrapper that
    /// `HevcPreferredVideoEncoderFactory` installs around every encoder.
    /// Harmless no-op when no video encoder is live (flag is consumed by
    /// the next encoder that starts). Callable from any thread.
    public func forceWebRtcKeyframe() {
        VideoKeyframeController.shared.requestKeyFrame()
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
        return answerSdp
    }

    // MARK: - ICE

    public func handleRemoteIce(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        peerConnection?.addRemoteIce(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
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
        guard peerConnection != nil else {
            state = .disconnected
            return
        }
        stopCameraCapture()
        stopVideoStatsTelemetry()
        wssTurnBridge?.stop()
        wssTurnBridge = nil
        masqueTurnBridge?.stop()
        masqueTurnBridge = nil
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
        // WIRE_SPEC §8.7 — drop any armed TX-hold (endCall funnels through
        // here via sendHangupAndClose): cancel the 2s watchdog and clear
        // the one-shot latch so the next call/upgrade starts clean. The
        // track itself is gone with the closed PC — nothing to unmute.
        clearVideoTxHold()
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
                c.setKey(k)
                peerConnection?.attachVideoSenderCryptor()  // idempotent
            }
            return videoSealer
        }
        if let existing = videoSealer { return existing }
        guard let negotiated = peerNegotiated() else { return nil }

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
            // disable video fail-closed rather than emit a cipher the peer
            // can't decrypt.
            if CallCapabilities.v4SFrameAes256Enabled && !negotiated.useSFrameAes256 {
                print("[WebRtcCallController] AES-256 FAIL-CLOSED — peer does not advertise sframe-aes256-v1 (agreed=\(negotiated.agreedTags)); video DISABLED")
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
            cryptor?.setKey(kVideo)
            peerConnection?.attachVideoSenderCryptor()
            videoSealer = .native
            videoKeyIsPhoneLevel = negotiated.useVideoKey
            let aes256Active = CallCapabilities.v4SFrameAes256Enabled && negotiated.useSFrameAes256
            let keyKind = negotiated.useVideoKey ? "K_video (phone-level)" : "session-key (legacy)"
            print("[WebRtcCallController] video pipeline → NATIVE RTCFrameCryptor key=\(keyKind) aes256=\(aes256Active) (peerCaps=\(negotiated.agreedTags))")
            return videoSealer
        }

        // Peer is legacy / didn't advertise sframe-v1 → no E2EE on video,
        // DTLS-SRTP only. Latch this so we don't keep re-checking.
        videoSealer = .legacy
        print("[WebRtcCallController] video pipeline → legacy (peerCaps=\(negotiated.agreedTags), useSFrame=false)")
        return videoSealer
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

        var servers = QAudionPeerConnectionFactory.iceServers(from: bundle.servers)

        // MASQUE CONNECT-UDP bridge — preferred firewall bypass (UDP over
        // HTTP/3 / QUIC datagrams; no TCP-over-TCP head-of-line blocking like
        // WSS-TURN). Inert in the default build (MasqueFeature disabled + no
        // QUIC backend) — see MasqueDatagramTransport.swift for the activation
        // steps. Tried first so it wins over WSS-TURN when both are available.
        if let masqueIce = await startMasqueBridgeIfAvailable(bundle: bundle) {
            servers.insert(masqueIce, at: 0)
        }

        // WSS-TURN bridge — last-resort bypass for corporate firewalls
        // that block UDP 3478, TCP 3478, and TURNS 5349. The server
        // exposes a WebSocket TURN proxy at /api/v1/turn-ws; we relay
        // raw TURN frames between a loopback UDP socket and that WSS
        // endpoint, presenting libwebrtc with a standard
        // turn:127.0.0.1:<port>?transport=udp entry.
        // Mirrors Android WssTurnBridge.kt and Desktop WssTurnBridge.ts.
        if let wssUrlStr = bundle.wssTurnUrl,
           let wssUrl = URL(string: wssUrlStr),
           // Skip if bundle has no TURN entry with credentials — libwebrtc
           // needs real credentials inside the TURN ALLOCATE request.
           let firstTurn = bundle.servers.first(where: { s in
               s.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
           }),
           firstTurn.username != nil,
           firstTurn.credential != nil {
            let bridge = WssTurnBridge(
                wssUrl: wssUrl,
                username: firstTurn.username,
                credential: firstTurn.credential,
                accessToken: accessToken
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

    /// MASQUE CONNECT-UDP bridge (gated). Returns an ICE server entry that
    /// routes TURN over an HTTP/3 tunnel when MASQUE is enabled and a QUIC/H3
    /// backend is compiled in; otherwise `nil`. Inert in the default build:
    /// `MasqueFeature.isEnabled` is false and `MasqueTransportFactory.make()`
    /// returns nil, so every guard below short-circuits to nil with no effect
    /// on call setup. Mirrors Android `CronetMasqueDriver`.
    private func startMasqueBridgeIfAvailable(
        bundle: RelayCredentialsProvider.RelayBundle
    ) async -> RTCIceServer? {
        guard MasqueFeature.isEnabled else { return nil }
        guard let masqueUrlStr = bundle.masqueUrl,
              let masqueUrl = URL(string: masqueUrlStr),
              let host = masqueUrl.host else { return nil }
        guard let transport = MasqueTransportFactory.make() else { return nil }
        // Tunnel target = the first TURN relay with credentials. libwebrtc
        // needs real TURN creds inside its ALLOCATE; STUN-only entries are skipped.
        guard let firstTurn = bundle.servers.first(where: { server in
            server.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
        }) else { return nil }
        guard let turnUrl = firstTurn.urls.first(where: {
            $0.hasPrefix("turn:") || $0.hasPrefix("turns:")
        }) else { return nil }
        guard let target = MasqueConnectUdpRequest.parseTurnTarget(turnUrl) else { return nil }
        guard let username = firstTurn.username,
              let credential = firstTurn.credential else { return nil }

        var authority: String = host
        if let port = masqueUrl.port { authority = host + ":" + "\(port)" }

        let request = MasqueConnectUdpRequest(
            proxyAuthority: authority,
            targetHost: target.host,
            targetPort: target.port,
            bearerToken: accessToken)
        let bridge = MasqueTurnBridge(transport: transport, request: request)
        guard let result = try? await bridge.start() else { return nil }
        masqueTurnBridge?.stop()
        masqueTurnBridge = bridge
        return RTCIceServer(urlStrings: [result.iceUrl], username: username, credential: credential)
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

    public func peerConnection(_ pc: QAudionPeerConnection,
                                 didChangeIceConnectionState s: RTCIceConnectionState) {
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
        switch s {
        case .connected, .completed:
            state = .connected
            // Start outbound/inbound video RTP telemetry once media can flow.
            startVideoStatsTelemetry()
        case .failed:
            state = .failed("ICE failed")
        case .disconnected, .closed:
            state = .disconnected
            stopVideoStatsTelemetry()
        default:
            break
        }
        onIceConnectionState?(s)
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

    private func pollVideoStatsOnce() {
        guard let pc = peerConnection?.peerConnection, let sink = videoTelemetry else { return }
        pc.statistics { report in
            var outFramesEnc = -1, outBytes = -1, outW = -1
            var inFramesDec = -1, inFramesRec = -1, inBytes = -1, inW = -1, inH = -1
            var inCodecId = "", outCodecId = ""
            for (_, s) in report.statistics {
                guard let kind = s.values["kind"] as? String, kind == "video" else { continue }
                if s.type == "outbound-rtp" {
                    outFramesEnc = (s.values["framesEncoded"] as? NSNumber)?.intValue ?? outFramesEnc
                    outBytes = (s.values["bytesSent"] as? NSNumber)?.intValue ?? outBytes
                    outW = (s.values["frameWidth"] as? NSNumber)?.intValue ?? outW
                    outCodecId = (s.values["codecId"] as? String) ?? outCodecId
                } else if s.type == "inbound-rtp" {
                    inFramesDec = (s.values["framesDecoded"] as? NSNumber)?.intValue ?? inFramesDec
                    inFramesRec = (s.values["framesReceived"] as? NSNumber)?.intValue ?? inFramesRec
                    inBytes = (s.values["bytesReceived"] as? NSNumber)?.intValue ?? inBytes
                    inW = (s.values["frameWidth"] as? NSNumber)?.intValue ?? inW
                    inH = (s.values["frameHeight"] as? NSNumber)?.intValue ?? inH
                    inCodecId = (s.values["codecId"] as? String) ?? inCodecId
                }
            }
            // Resolve codec mimeType from the referenced codec stats object.
            func mime(_ id: String) -> String {
                guard !id.isEmpty, let c = report.statistics[id] else { return "?" }
                return (c.values["mimeType"] as? String) ?? "?"
            }
            sink("video.stats", [
                "out_frames_enc": outFramesEnc,
                "out_bytes": outBytes,
                "out_frame_w": outW,
                "out_codec": mime(outCodecId),
                "in_frames_rec": inFramesRec,
                "in_frames_dec": inFramesDec,
                "in_bytes": inBytes,
                "in_frame_w": inW,
                "in_frame_h": inH,
                "in_codec": mime(inCodecId),
            ])
            // WIRE_SPEC §8.7 (INT-4a) — receiver decode-stall detection. Runs
            // on the stats callback thread; the controller is @unchecked
            // Sendable and these fields are touched ONLY here + on close (the
            // 3s single-timer serializes them).
            self.evaluateVideoStall(framesDecoded: inFramesDec, bytesReceived: inBytes)
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
        _ = pc.ensureNativeVideoCryptor(participantId: recipientId ?? "peer")
        // Publish K_video if we already hold a session key (idempotent); the
        // pqcSessionKey didSet path (re)publishes it on arrival/rotation.
        _ = ensureVideoSealerInternal()
        let attached = pc.attachVideoReceiverCryptor(receiver)
        print("[WebRtcCallController] native video receiver cryptor attached=\(attached)")
        // WIRE_SPEC §8.7 — the attach may have just completed the
        // "receiver cryptor attached AND keyed" pair (receiver arriving
        // AFTER key+caps). One-shot inside.
        notifyInboundVideoReadyIfNeeded()
    }
}
#endif
