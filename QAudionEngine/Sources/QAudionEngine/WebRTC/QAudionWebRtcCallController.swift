import Foundation
#if canImport(WebRTC)
import WebRTC

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

    private let callingApi: CallingApi
    private let relayProvider: RelayCredentialsProvider?
    private var peerConnection: QAudionPeerConnection?
    private var recipientId: String?

    public init(callingApi: CallingApi, relayProvider: RelayCredentialsProvider? = nil) {
        self.callingApi = callingApi
        self.relayProvider = relayProvider
    }

    // MARK: - Outgoing

    /// Build the peer connection, generate an SDP offer, and ship via
    /// `CallingApi.sendCallOffer`. Returns once the offer has been sent;
    /// the call is connected later when the peer's answer arrives via
    /// `handleRemoteAnswer(sdp:)`.
    public func startOutgoingCall(recipientId: String, audioOnly: Bool = true) async throws {
        guard state == .idle || state == .disconnected else {
            throw ControllerError.wrongState(String(describing: state))
        }
        state = .outgoingOffering
        self.recipientId = recipientId

        let iceServers = await fetchIceServers()
        let pc = QAudionPeerConnection(
            factory: QAudionPeerConnectionFactory.shared.factory,
            iceServers: iceServers,
            delegate: self)
        peerConnection = pc
        pc.addLocalAudioTrack()
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
        try await callingApi.sendCallOffer(recipientId: recipientId, sdp: sdp)
        state = .connecting
    }

    /// Apply the remote answer SDP that arrived on `call_answer`.
    public func handleRemoteAnswer(sdp: String) async throws {
        guard let pc = peerConnection else {
            throw ControllerError.noPeerConnection
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteAnswer(sdp: sdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    // MARK: - Incoming

    public func acceptIncomingCall(callerId: String, offerSdp: String, audioOnly: Bool = true) async throws {
        guard state == .idle || state == .disconnected else {
            throw ControllerError.wrongState(String(describing: state))
        }
        state = .incomingAnswering
        self.recipientId = callerId

        let iceServers = await fetchIceServers()
        let pc = QAudionPeerConnection(
            factory: QAudionPeerConnectionFactory.shared.factory,
            iceServers: iceServers,
            delegate: self)
        peerConnection = pc
        pc.addLocalAudioTrack()
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
        // 2. Build local answer.
        let answerSdp: String = try await withCheckedThrowingContinuation { cont in
            pc.createAnswer { result in
                switch result {
                case .success(let sdp): cont.resume(returning: sdp)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
        // 3. Ship answer back.
        try await callingApi.sendCallAnswer(recipientId: callerId, sdp: answerSdp)
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
        peerConnection?.close()
        peerConnection = nil
        recipientId = nil
        state = .disconnected
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
                                 didChangeSignalingState s: RTCSignalingState) {}

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
