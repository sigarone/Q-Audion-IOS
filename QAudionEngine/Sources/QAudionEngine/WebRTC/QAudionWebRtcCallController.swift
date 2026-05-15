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
        didSet { applyPqcSealerIfPossible() }
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

    /// SFrame video sealer factory — DI seam mirroring Android's
    /// `CallController.sframeVideoSealerProvider`. The closure receives
    /// a key provider (returns the current 32-byte PQC session key on
    /// every call, picking up rekey rotations transparently) and
    /// returns a fully-built `SFrameVideoSealer`.
    ///
    /// Set this from the app/DI layer at startup, BEFORE any call.
    /// Leaving it `nil` keeps the controller on the legacy video
    /// pipeline forever — useful for tests + builds where the SFrame
    /// flip should stay disabled.
    ///
    /// Recommended wiring:
    /// ```swift
    ///   ctrl.sframeVideoSealerFactory = { keyProvider in
    ///       SFrameVideoSealer.forRotatingKey(keyProvider)
    ///   }
    /// ```
    public var sframeVideoSealerFactory: ((@escaping () -> Data) -> SFrameVideoSealer)?

    /// Discriminator for the active video pipeline on this call.
    /// Resolved at video setup time by ``ensureVideoSealer()`` based
    /// on the peer's negotiated capabilities — once set it stays
    /// fixed for the call's lifetime (matches Android's "construct
    /// pipeline once" rule, NVIDIA Llama-3.3-70b reviewed).
    public enum VideoCallSealer {
        /// Legacy iOS video path — frames flow through the existing
        /// audio-shape RTP frame encryptor (or plain WebRTC SRTP on
        /// builds where the insertable-streams API is unavailable).
        case legacy
        /// SFrame v1 path — outbound video frames go through
        /// ``SFrameVideoSealer/seal(plaintext:layer:keyFrame:padded:)``
        /// before the transport ships them; inbound frames come
        /// through ``SFrameVideoSealer/open(_:)``.
        case sframe(SFrameVideoSealer)
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
    public func startOutgoingCall(
        recipientId: String,
        audioOnly: Bool = true,
        callerDisplay: String? = nil
    ) async throws {
        guard state == .idle || state == .disconnected else {
            throw ControllerError.wrongState(String(describing: state))
        }
        hasAppliedRemoteAnswer = false   // W418 — fresh call, reset idempotency flag
        state = .outgoingOffering
        self.recipientId = recipientId

        let iceServers = await fetchIceServers()
        let factory = QAudionPeerConnectionFactory.shared.createFactory(sealerProvider: { [weak self] in
            if case .sframe(let sealer) = self?.videoSealer {
                return sealer
            }
            return nil
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
        let callHasVideo: Bool = !audioOnly
        try await callingApi.sendCallOffer(
            recipientId: recipientId,
            sdp: sdp,
            capabilities: CallCapabilities.local,
            callerDisplay: callerDisplay,
            hasVideo: callHasVideo
        )
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
            if case .sframe(let sealer) = self?.videoSealer {
                return sealer
            }
            return nil
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
    }

    /// Read the current peer-negotiated capability set. Returns `nil`
    /// when the peer has not yet been heard from (call_offer/answer
    /// not yet processed) — callers should treat that as "not ready
    /// to pick the video pipeline" and defer.
    public func peerNegotiated() -> CallCapabilities.Negotiated? {
        peerConnection?.peerNegotiated()
    }

    /// Idempotently pick the video pipeline based on the peer's
    /// negotiated capabilities. Mirrors Android
    /// `CallController.ensureVideoSealer()` (commit 3db2cd81):
    ///
    /// - If ``videoSealer`` is already set → no-op (one pick per call).
    /// - If `peerNegotiated()` is `nil` (peer not heard from yet) →
    ///   leaves `videoSealer` unset; caller should defer.
    /// - If `useSFrame=true` AND ``sframeVideoSealerFactory`` is wired
    ///   AND a 32-byte PQC session key is available → builds an
    ///   SFrame sealer via the factory and stores `.sframe(sealer)`.
    /// - Otherwise → stores `.legacy`, preserving today's behaviour
    ///   for legacy peers + tests where the factory isn't wired.
    ///
    /// - Parameter pqcSessionKeyProvider: closure returning the
    ///   current 32-byte PQC session key. Typically backed by
    ///   `{ self.pqcSessionKey ?? Data() }` from the app layer.
    ///   The closure is captured by the resulting sealer and called
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

        let resolved: VideoCallSealer
        if negotiated.useSFrame,
           let factory = sframeVideoSealerFactory,
           pqcSessionKeyProvider().count == 32 {
            let sealer = factory(pqcSessionKeyProvider)
            resolved = .sframe(sealer)
            print("[WebRtcCallController] video pipeline → SFrame v1 (peerCaps=\(negotiated.agreedTags))")
        } else {
            resolved = .legacy
            print("[WebRtcCallController] video pipeline → legacy (peerCaps=\(negotiated.agreedTags), useSFrame=\(negotiated.useSFrame), factoryWired=\(sframeVideoSealerFactory != nil))")
        }
        videoSealer = resolved
        return resolved
    }

    // MARK: - Camera capture

    /// Start the front-facing camera, targeting 1280×720@30fps, and wire
    /// its frames into the supplied RTCVideoSource. Gracefully picks the
    /// closest available format when 720p is not listed. iOS-only — the
    /// guard compiles away on macOS / Swift package unit-test targets.
    /// No-op when `useExternalVideoSource == true` (AppState's
    /// VideoCallPipeline owns the camera on that path).
    private func startCameraCapture(for source: RTCVideoSource) {
        guard !useExternalVideoSource else { return }
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
            }
        }
        #endif
    }

    private func stopCameraCapture() {
        #if os(iOS)
        localVideoCapturer?.stopCapture()
        localVideoCapturer = nil
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
            print("[WebRtcCallController] PQC sealer installed (key.count=\(key.count))")
        } catch {
            print("[WebRtcCallController] PQC sealer install failed: \(error)")
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
    }

    // MARK: - QAudionPeerConnection.Delegate

    public func peerConnection(_ pc: QAudionPeerConnection,
                                 didDiscoverLocalIceCandidate candidate: String,
                                 sdpMid: String?,
                                 sdpMLineIndex: Int32) {
        guard let rid = recipientId else { return }
        Task {
            try? await callingApi.sendIceCandidate(recipientId: rid, candidate: candidate)
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
        onRemoteAudioTrack?(track)
    }

    public func peerConnection(_ pc: QAudionPeerConnection,
                                 didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        onRemoteVideoTrack?(track)
    }
}
#endif
