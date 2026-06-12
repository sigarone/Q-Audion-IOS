import Foundation
#if canImport(WebRTC)
import WebRTC
import AVFoundation

/// High-level wrapper around `RTCPeerConnection` for Q-Audion 1:1 calls.
/// Mirrors Android's `feature/feature-call/.../webrtc/QAudionPeerConnection.kt`.
///
/// **Lifecycle (caller perspective):**
///   1. `let pc = QAudionPeerConnection(factory:..., iceServers:..., delegate:...)`
///   2. caller side: `pc.createOffer()` → returns SDP → ship via `CallingApi.sendCallOffer`
///   3. callee side: receive offer SDP, `pc.setRemoteOffer(sdp:)`, then `pc.createAnswer()` → ship answer
///   4. caller side: receive answer SDP, `pc.setRemoteAnswer(sdp:)`
///   5. both sides exchange ICE candidates via `pc.addRemoteIce(candidate:sdpMid:sdpMLineIndex:)`
///       (the local ICE candidates flow out via `Delegate.onLocalIce(...)`).
///   6. on hangup: `pc.close()`.
///
/// **Cross-platform contract with Android `QAudionPeerConnection`:**
/// - SDP semantics = unified-plan (default on iOS WebRTC ≥ M89)
/// - Single audio track, optional single video track
/// - Stable track ids: `audio0` / `video0` (used by Android too)
/// - Trickle ICE — no pre-gather wait
public final class QAudionPeerConnection: NSObject {

    /// Receives outbound ICE candidates and connection state changes.
    public protocol Delegate: AnyObject {
        /// A locally-discovered ICE candidate that must be shipped to the peer
        /// via the signaling channel (`CallingApi.sendIceCandidate`).
        func peerConnection(_ pc: QAudionPeerConnection,
                             didDiscoverLocalIceCandidate candidate: String,
                             sdpMid: String?,
                             sdpMLineIndex: Int32)

        /// ICE connection state transitions (new → checking → connected → ...).
        func peerConnection(_ pc: QAudionPeerConnection,
                             didChangeIceConnectionState state: RTCIceConnectionState)

        /// Signaling state transitions.
        func peerConnection(_ pc: QAudionPeerConnection,
                             didChangeSignalingState state: RTCSignalingState)

        /// Remote track received (e.g. peer's microphone audio).
        func peerConnection(_ pc: QAudionPeerConnection,
                             didReceiveRemoteAudioTrack track: RTCAudioTrack)
        /// Remote video track (only fired when video is negotiated).
        func peerConnection(_ pc: QAudionPeerConnection,
                             didReceiveRemoteVideoTrack track: RTCVideoTrack)
    }

    public weak var delegate: Delegate?

    /// Underlying RTCPeerConnection. Avoid touching directly — use the
    /// high-level methods on this class instead.
    public private(set) var peerConnection: RTCPeerConnection?

    private let factory: RTCPeerConnectionFactory
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private let mediaConstraints = RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
    )
    private let stableStreamId = "qaudion-stream-0"
    private let audioTrackId = "audio0"
    private let videoTrackId = "video0"

    public init(factory: RTCPeerConnectionFactory,
                iceServers: [RTCIceServer],
                iceTransportPolicy: RTCIceTransportPolicy = .all,
                delegate: Delegate?) {
        self.factory = factory
        self.delegate = delegate
        super.init()

        let config = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: iceServers)
        // W411: honor the user's TransportMode preference. When the
        // app sets `.relay`, host/srflx candidates are filtered out
        // and all media flows through TURN — needed for restricted
        // carrier-NAT environments.
        config.iceTransportPolicy = iceTransportPolicy
        guard let pc = factory.peerConnection(with: config,
                                                constraints: mediaConstraints,
                                                delegate: self) else {
            return
        }
        self.peerConnection = pc
    }

    deinit {
        close()
    }

    // MARK: - Audio track

    /// Add the local microphone track. Required before createOffer / createAnswer
    /// for an audio call so the SDP negotiates an `m=audio` section.
    ///
    /// W574d — the track is added DISABLED. Q-Audion audio NEVER rides
    /// plain DTLS-SRTP: iOS ships sealed Opus+AEAD frames over the WS
    /// relay, Android over its FrameRelayTransport (DC/WS). The enabled
    /// SRTP mic track caused two field bugs on Android→iOS calls
    /// (report 2026-06-12): (1) the peer's SRTP voice played out of the
    /// loudspeaker DURING RING (the responder builds its answer at
    /// call_incoming time, so ICE+DTLS complete pre-answer and nothing
    /// gated playback), and (2) WebRTC's voice-processing audio unit
    /// owned the mic, starving the AVAudioEngine relay tap (tx_enc=0
    /// on every cross call). m=audio still negotiates — the track just
    /// carries silence, mirroring Android's earbud-relay behaviour
    /// (`audioTrack.setEnabled(false)`).
    @discardableResult
    public func addLocalAudioTrack() -> Bool {
        guard let pc = peerConnection, localAudioTrack == nil else { return false }
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: audioSource, trackId: audioTrackId)
        track.isEnabled = false  // W574d — sealed-relay-only audio; see doc above
        pc.add(track, streamIds: [stableStreamId])
        localAudioTrack = track
        print("[WebRTC] local AUDIO track added to peer connection (disabled — sealed relay carries voice)")
        return true
    }

    /// W386 — placeholder for the W382 PQC sealer install hook.
    ///
    /// The stasel/WebRTC 131.0.0 binary build doesn't expose the
    /// `frameEncryptor` / `frameDecryptor` properties on
    /// `RTCRtpSender` / `RTCRtpReceiver` (insertable-streams API
    /// stripped from the binary). The PqcRtpFrameSealer engine
    /// (W376) and the engine-side adapters (W386) remain in place
    /// for non-SRTP transports (BcryptoWsRelay etc.); the SRTP path
    /// will pick this up automatically when a WebRTC iOS build with
    /// the insertable-streams protocols becomes available.
    ///
    /// Until then this method is a no-op so existing call sites
    /// (W383 `applyPqcSealerIfPossible`) keep compiling without
    /// breaking the SRTP layer.
    ///
    /// ⚠️ SECURITY (C-1) — THIS METHOD DOES NOT PROVIDE PQC MEDIA
    /// PROTECTION. It is intentionally a no-op for the SRTP path: the
    /// WebRTC binary linked here ships WITHOUT the insertable-streams
    /// `frameEncryptor`/`frameDecryptor` slots, so there is nowhere to
    /// attach the sealer. It only retains the adapter pair so the
    /// non-SRTP BcryptoWsRelay transport can reach the engine. Callers
    /// MUST NOT log or display "PQC sealer installed" — media on the
    /// SRTP path is protected by DTLS-SRTP only until a WebRTC build
    /// exposing the insertable-streams protocols is adopted.
    public func installPqcSealer(_ sealer: PqcRtpFrameSealer) {
        guard peerConnection != nil else { return }
        // Hold a strong reference to the adapter pair so the engine
        // is reachable for the non-SRTP transports while we wait for
        // a WebRTC binary that exposes the insertable-streams API.
        // M-13: never share one PqcRtpFrameSealer between the
        // encryptor (seal/counter-advancing) and the decryptor
        // (open/counter-reflecting). Use an independent sibling that
        // shares the master key but keeps its own counter so the two
        // directions can never collide on (key, nonce).
        let recvSealer = sealer.makeSibling()
        installedPqcEncryptor = PqcFrameEncryptor(sealer: sealer)
        installedPqcDecryptor = PqcFrameDecryptor(sealer: recvSealer)
    }

    /// Held so the seal/open closures stay alive as long as the
    /// peer connection. Read by the BcryptoWsRelay path when it
    /// switches to PQC-augmented frames in a future commit.
    public private(set) var installedPqcEncryptor: PqcFrameEncryptor?
    public private(set) var installedPqcDecryptor: PqcFrameDecryptor?

    // MARK: - Capability handshake (commit 540b79c0 parity)

    /// Capability negotiation result for THIS call, computed by
    /// ``CallCapabilities/negotiate(local:peer:)`` at the moment the
    /// peer's `call_offer` (responder side) or `call_answer` (caller
    /// side) is parsed. `nil` until the peer has been heard from —
    /// the call controller defers picking the video pipeline (legacy
    /// vs SFrame) until this returns non-nil.
    ///
    /// Mirrors Kotlin
    /// `QAudionPeerConnection.peerCallCapabilities` (`@Volatile` on
    /// Android). On iOS we guard with `NSLock` for parity with the
    /// other counter/answer locks in this engine.
    private let peerCapsLock = NSLock()
    private var peerCallCapabilities: CallCapabilities.Negotiated?

    /// Read the cached negotiation result. Returns `nil` until
    /// ``acceptPeerCapabilities(_:)`` has been called.
    public func peerNegotiated() -> CallCapabilities.Negotiated? {
        peerCapsLock.lock(); defer { peerCapsLock.unlock() }
        return peerCallCapabilities
    }

    /// Run the local list against the peer's advertised tags and
    /// store the result for ``peerNegotiated()`` to return. Idempotent
    /// — calling twice with the same peer list is a no-op.
    ///
    /// `peer` is `nil` for legacy clients that didn't include the
    /// `capabilities` field on their `call_offer`/`call_answer`; the
    /// negotiate function downgrades that to useSFrame=false.
    public func acceptPeerCapabilities(_ peer: [String]?) {
        let n = CallCapabilities.negotiate(peer: peer)
        peerCapsLock.lock(); peerCallCapabilities = n; peerCapsLock.unlock()
    }

    /// Mute / unmute the local microphone.
    ///
    /// W574d — the SRTP mic track is PERMANENTLY disabled (sealed relay
    /// carries the voice, see `addLocalAudioTrack`). Only the muted
    /// direction is propagated so no caller can accidentally re-enable
    /// plain-SRTP voice transmission via an unmute.
    public func setMicrophoneMuted(_ muted: Bool) {
        if muted { localAudioTrack?.isEnabled = false }
    }

    // MARK: - Video track (optional)

    /// Add a local video track from the supplied capturer. Caller is
    /// responsible for starting the capturer; this method just plumbs the
    /// track into the peer connection.
    @discardableResult
    public func addLocalVideoTrack(capturer: RTCVideoCapturer? = nil) -> RTCVideoSource? {
        guard let pc = peerConnection, localVideoTrack == nil else { return nil }
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: videoTrackId)
        track.isEnabled = true
        pc.add(track, streamIds: [stableStreamId])
        localVideoTrack = track
        if let capturer = capturer {
            // Hook the capturer's frames to the source.
            capturer.delegate = source
        }
        // W466 — confirm the local camera track was plumbed into the
        // peer connection.
        print("[WebRTC] local VIDEO track added to peer connection")
        return source
    }

    public func setVideoMuted(_ muted: Bool) {
        localVideoTrack?.isEnabled = !muted
    }

    /// W536 — true once `addLocalVideoTrack` has installed a track.
    /// Used by QAudionWebRtcCallController.upgradeToVideo to short-
    /// circuit a redundant addTransceiver when the renegotiation has
    /// already been driven from the other side.
    public func hasLocalVideoTrack() -> Bool {
        return localVideoTrack != nil
    }

    // MARK: - Offer / Answer

    public func createOffer(audioOnly: Bool = true,
                              completion: @escaping (Result<String, Error>) -> Void) {
        guard let pc = peerConnection else {
            completion(.failure(WebRTCError.notInitialized))
            return
        }
        let mandatory: [String: String] = [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": audioOnly ? "false" : "true"
        ]
        let constraints = RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, err in
            if let err = err {
                completion(.failure(err)); return
            }
            guard let sdp = sdp else {
                completion(.failure(WebRTCError.sdpFailed("offer returned nil"))); return
            }
            self?.peerConnection?.setLocalDescription(sdp, completionHandler: { setErr in
                if let setErr = setErr {
                    completion(.failure(setErr))
                } else {
                    completion(.success(sdp.sdp))
                }
            })
        }
    }

    public func createAnswer(hasVideo: Bool = false,
                              completion: @escaping (Result<String, Error>) -> Void) {
        guard let pc = peerConnection else {
            completion(.failure(WebRTCError.notInitialized))
            return
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true",
                                     "OfferToReceiveVideo": hasVideo ? "true" : "false"],
            optionalConstraints: nil)
        pc.answer(for: constraints) { [weak self] sdp, err in
            if let err = err {
                completion(.failure(err)); return
            }
            guard let sdp = sdp else {
                completion(.failure(WebRTCError.sdpFailed("answer returned nil"))); return
            }
            self?.peerConnection?.setLocalDescription(sdp, completionHandler: { setErr in
                if let setErr = setErr {
                    completion(.failure(setErr))
                } else {
                    completion(.success(sdp.sdp))
                }
            })
        }
    }

    public func setRemoteOffer(sdp: String, completion: @escaping (Error?) -> Void) {
        applyRemoteSdp(type: .offer, sdp: sdp, completion: completion)
    }

    public func setRemoteAnswer(sdp: String, completion: @escaping (Error?) -> Void) {
        applyRemoteSdp(type: .answer, sdp: sdp, completion: completion)
    }

    private func applyRemoteSdp(type: RTCSdpType, sdp: String, completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection else { completion(WebRTCError.notInitialized); return }
        let desc = RTCSessionDescription(type: type, sdp: sdp)
        pc.setRemoteDescription(desc, completionHandler: completion)
    }

    // MARK: - ICE

    public func addRemoteIce(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        guard let pc = peerConnection else { return }
        let cand = RTCIceCandidate(sdp: candidate,
                                     sdpMLineIndex: sdpMLineIndex,
                                     sdpMid: sdpMid)
        pc.add(cand) { _ in /* errors logged at signaling layer */ }
    }

    // MARK: - Close

    public func close() {
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        localVideoTrack = nil
    }

    // MARK: - Errors

    public enum WebRTCError: Error, Equatable {
        case notInitialized
        case sdpFailed(String)
    }
}

extension QAudionPeerConnection: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        delegate?.peerConnection(self, didChangeSignalingState: stateChanged)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let audioTrack = stream.audioTracks.first {
            delegate?.peerConnection(self, didReceiveRemoteAudioTrack: audioTrack)
        }
        if let videoTrack = stream.videoTracks.first {
            delegate?.peerConnection(self, didReceiveRemoteVideoTrack: videoTrack)
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        delegate?.peerConnection(self, didChangeIceConnectionState: newState)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        delegate?.peerConnection(self,
                                  didDiscoverLocalIceCandidate: candidate.sdp,
                                  sdpMid: candidate.sdpMid,
                                  sdpMLineIndex: candidate.sdpMLineIndex)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // Unified-plan track callback.
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let audio = rtpReceiver.track as? RTCAudioTrack {
            delegate?.peerConnection(self, didReceiveRemoteAudioTrack: audio)
        }
        if let video = rtpReceiver.track as? RTCVideoTrack {
            delegate?.peerConnection(self, didReceiveRemoteVideoTrack: video)
        }
    }
}
#endif
