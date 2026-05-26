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
        /// cross-platform calls render. AES-128-GCM, HKDF-SHA256
        /// (empty salt, 128-byte zero info), keyIndex=0.
        case livekit(LiveKitVideoFrameCryptor)
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
                capabilities: CallCapabilities.local,
                callerDisplay: callerDisplay,
                hasVideo: callHasVideo
            )
        } else {
            try await callingApi.sendCallOffer(
                recipientId: recipientId,
                sdp: sdp,
                capabilities: CallCapabilities.local,
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
            capabilities: CallCapabilities.local,
            hasVideo: !audioOnly
        )
        state = .connecting
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
        } catch {
            videoUpgradeInProgress = false
            throw error
        }
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
        peerConnection?.close()
        peerConnection = nil
        recipientId = nil
        hasAppliedRemoteAnswer = false   // W418 — reset for next call
        videoSealer = nil                // commit 3db2cd81 parity — reset
                                         // pipeline pick so the next call
                                         // re-runs ensureVideoSealer().
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

    /// W539 — internal autopilot: install the LiveKit video cryptor as
    /// soon as BOTH the peer's negotiated caps and a 32-byte PQC key
    /// are available. Called from `acceptPeerCapabilities` and from
    /// the `pqcSessionKey` didSet so whichever arrives last triggers
    /// the install. Idempotent — once `videoSealer` is set, this is a
    /// no-op for the rest of the call. The keyProvider closure used by
    /// the LiveKit cryptor reads `self.pqcSessionKey` lazily on every
    /// frame, so audio-driven rekey rotations continue to be picked
    /// up transparently.
    @discardableResult
    private func ensureVideoSealerInternal() -> VideoCallSealer? {
        return ensureVideoSealer { [weak self] in
            self?.pqcSessionKey ?? Data()
        }
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
        if let existing = videoSealer { return existing }
        guard let negotiated = peerNegotiated() else { return nil }

        // W539 — when the peer advertised `sframe-v1` we install LiveKit
        // and only LiveKit (cross-platform-compatible wire format). Until
        // the PQC key is available we DEFER (return nil) so that a later
        // arrival of the key via the `pqcSessionKey` didSet still picks
        // up the install. We must NOT latch `.legacy` while we are still
        // waiting for the key — otherwise the cryptor would never come
        // online and every video frame would silently mis-decode on the
        // peer's side (the exact bug W539 is fixing).
        if negotiated.useSFrame {
            let keyLen = pqcSessionKeyProvider().count
            guard keyLen == 32 else {
                // Defer — PQC handshake hasn't yielded a key yet. The
                // `pqcSessionKey` didSet will call us again once it does.
                return nil
            }
            // The `sframe-v1` capability tag is a misnomer kept for
            // backwards compatibility with peers (Desktop / Android emit
            // it from `LOCAL_CAPABILITIES` / `local`). The actual wire
            // format used on all platforms is the libwebrtc-native
            // FrameCryptor envelope (ported in `LiveKitVideoFrameCryptor`).
            let cryptor = LiveKitVideoFrameCryptor(keyProvider: pqcSessionKeyProvider)
            videoSealer = .livekit(cryptor)
            print("[WebRtcCallController] video pipeline → LiveKit FrameCryptor (peerCaps=\(negotiated.agreedTags))")
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
            let sealer = try PqcRtpFrameSealer(pqcSessionKey: key)
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
        return QAudionPeerConnectionFactory.iceServers(from: bundle.servers)
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
        case .failed:
            state = .failed("ICE failed")
        case .disconnected, .closed:
            state = .disconnected
        default:
            break
        }
        onIceConnectionState?(s)
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
        print("[WebRTC] remote AUDIO track received — enabled=\(track.isEnabled)")
        onRemoteAudioTrack?(track)
    }

    public func peerConnection(_ pc: QAudionPeerConnection,
                                 didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        // W466 — confirm the remote video track arrived.
        print("[WebRTC] remote VIDEO track received — enabled=\(track.isEnabled)")
        onRemoteVideoTrack?(track)
    }
}
#endif
