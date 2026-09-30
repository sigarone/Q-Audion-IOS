import AVFoundation
import Foundation
#if canImport(WebRTC)
import WebRTC

public enum GroupPeerError: Error, Equatable, Sendable {
    case notStarted
    case factoryRefused
    case sdpFailed(String)
    case transceiverFailed
    /// The frame cryptor of a sender / receiver could not be attached: the
    /// stream would travel or render in the clear, so the negotiation is refused.
    case cryptorFailed
}

/// Group calls v2 (spec §4.4) — the plumbing both PeerConnections share: the
/// strict M150 configuration of the 1:1 native-SRTP path (GCM only, no TCP host
/// candidates, max-bundle, rtcp-mux require, continual gathering), the
/// delegate -> `GroupPcState` / candidate callbacks, the
/// async SDP helpers and the `transport` stats read of the §4.5 self-check.
///
/// One RTCPeerConnectionFactory for 1:1 and groups: the caller passes
/// `QAudionPeerConnectionFactory.shared`'s factory.
public class GroupPeerBase: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {

    public var onCandidate: ((GroupIceCandidate?) -> Void)?
    public var onState: ((GroupPcState) -> Void)?

    let factory: RTCPeerConnectionFactory
    let iceServers: [RTCIceServer]
    let stateLock = NSLock()
    var peerConnection: RTCPeerConnection?
    private var closed = false

    init(factory: RTCPeerConnectionFactory, iceServers: [RTCIceServer]) {
        self.factory = factory
        self.iceServers = iceServers
        super.init()
    }

    // MARK: Construction

    /// Builds the PeerConnection. `QaudionRuntimeTuning.requireDtlsPqc()` is NOT
    /// called here: it is tighten-only for the whole process and would also turn
    /// every later 1:1 call into a PQC-required one (the 1:1 path keeps it behind
    /// the `calls.dtls_pqc_required` remote gate). The group level is enforced by
    /// qjanus itself (DTLS 1.3 + X25519MLKEM768 only, fail-closed), the DTLS pin
    /// binds the node to its published certificate and `GroupTransportPolicy`
    /// checks version / cipher / SRTP profile after connect.
    func makePeerConnection() throws -> RTCPeerConnection {
        // A wrapper closed before it started (the session was torn down while the
        // start was in flight) must never build a PeerConnection nobody closes.
        guard !isClosed else { throw GroupPeerError.notStarted }
        let configuration = QAudionPeerConnectionFactory.defaultConfiguration(
            iceServers: iceServers, nativeSrtpEnabledLocally: true)
        configuration.iceTransportPolicy = .all
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw GroupPeerError.factoryRefused
        }
        stateLock.lock()
        if closed {
            stateLock.unlock()
            pc.close()
            throw GroupPeerError.notStarted
        }
        peerConnection = pc
        stateLock.unlock()
        return pc
    }

    var currentPeerConnection: RTCPeerConnection? {
        stateLock.lock(); defer { stateLock.unlock() }
        return peerConnection
    }

    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    /// Keeps only mid / rid / repaired-rid / transport-wide-cc negotiable on
    /// `transceiver` (spec §4.4). The SDP munging of `GroupSdpRules` is the
    /// backstop; asking the transceiver first means a well-behaved SDP needs no
    /// munging at all.
    func restrictHeaderExtensions(_ transceiver: RTCRtpTransceiver) {
        let extensions = transceiver.headerExtensionsToNegotiate
        var changed = false
        for entry in extensions where !GroupSdpRules.isAllowedExtension(uri: entry.uri) {
            entry.direction = .stopped
            changed = true
        }
        guard changed else { return }
        _ = try? transceiver.setHeaderExtensionsToNegotiate(extensions)
    }

    // MARK: Async SDP helpers

    func createOffer(_ constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        guard let pc = currentPeerConnection else { throw GroupPeerError.notStarted }
        return try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { description, error in
                if let description = description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: error ?? GroupPeerError.sdpFailed("offer"))
                }
            }
        }
    }

    func createAnswer(_ constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        guard let pc = currentPeerConnection else { throw GroupPeerError.notStarted }
        return try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: constraints) { description, error in
                if let description = description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: error ?? GroupPeerError.sdpFailed("answer"))
                }
            }
        }
    }

    func setLocal(_ description: RTCSessionDescription) async throws {
        guard let pc = currentPeerConnection else { throw GroupPeerError.notStarted }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(description) { error in
                if let error = error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func setRemote(_ description: RTCSessionDescription) async throws {
        guard let pc = currentPeerConnection else { throw GroupPeerError.notStarted }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(description) { error in
                if let error = error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: GroupPeerLink (shared part)

    public func addRemoteCandidate(_ candidate: GroupIceCandidate?) async {
        guard let pc = currentPeerConnection, let candidate = candidate else { return }
        let ice = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        try? await pc.add(ice)
    }

    /// The `transport` stats row: DTLS version, DTLS cipher, SRTP cipher and the
    /// selected local candidate type. nil until the row exists.
    public func transportObservation() async -> GroupTransportPolicy.Observed? {
        guard let report = await statsReport() else { return nil }
        for (_, stat) in report.statistics where stat.type == "transport" {
            let tls = stat.values["tlsVersion"] as? String
            let cipher = stat.values["dtlsCipher"] as? String
            let srtp = stat.values["srtpCipher"] as? String
            var candidateType: String?
            if let pairId = stat.values["selectedCandidatePairId"] as? String,
               let pair = report.statistics[pairId],
               let localId = pair.values["localCandidateId"] as? String,
               let local = report.statistics[localId] {
                candidateType = local.values["candidateType"] as? String
            }
            return GroupTransportPolicy.Observed(tlsVersion: tls, dtlsCipher: cipher, srtpCipher: srtp, candidateType: candidateType)
        }
        return nil
    }

    func statsReport() async -> RTCStatisticsReport? {
        guard let pc = currentPeerConnection else { return nil }
        return await withCheckedContinuation { continuation in
            pc.statistics { report in continuation.resume(returning: report) }
        }
    }

    /// Closes the PeerConnection; idempotent. Callers detach the frame
    /// cryptors BEFORE this (same ordering as the 1:1 path).
    func closePeerConnection() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        let pc = peerConnection
        peerConnection = nil
        stateLock.unlock()
        onState = nil
        onCandidate = nil
        pc?.close()
    }

    // MARK: RTCPeerConnectionDelegate

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        guard !isClosed else { return }
        let mapped: GroupPcState
        switch newState {
        case .new: mapped = .new
        case .connecting: mapped = .connecting
        case .connected: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: mapped = .connecting
        }
        onState?(mapped)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete, !isClosed { onCandidate?(nil) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !isClosed else { return }
        onCandidate?(GroupIceCandidate(sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, candidate: candidate.sdp))
    }
}

// MARK: - Publisher

/// The publisher PeerConnection (spec §4.2): audio (Opus 60 ms / 32 kbps CBR,
/// the 1:1 profile) and video (VP8 simulcast l/m/h) transceivers, send-only,
/// with the frame cryptors attached BEFORE the offer exists.
public final class GroupPublisherPeer: GroupPeerBase, GroupPublisherLink, @unchecked Sendable {

    /// Spec §4.4: rid, downscale, fps, bitrate of the three encodings.
    static let simulcast: [(rid: String, scale: Double, fps: Int, maxBps: Int)] = [
        ("l", 4, 15, 150_000),
        ("m", 2, 20, 450_000),
        ("h", 1, 25, 1_200_000),
    ]

    public typealias CameraResult = GroupCameraResult

    private let hub: GroupFrameCryptorHub
    private let selfPseudonym: String
    private var audioTrack: RTCAudioTrack?
    private var videoTrack: RTCVideoTrack?
    private var videoSource: RTCVideoSource?
    private var videoSender: RTCRtpSender?
    private var capturer: RTCCameraVideoCapturer?
    private var tuning: GroupNativeTuning?
    private var micEnabled = true
    /// How many of the three simulcast encodings the CAPTURE can feed: libwebrtc drops
    /// the top layer for a source below ~720p, so a smaller source publishes l,m (or l).
    private var sourceLayerCap = 3

    /// 720p and up feeds l+m+h (1280x720), 360p and up l+m, anything smaller only l.
    static func layerCap(forHeight height: Int32) -> Int {
        if height >= 720 { return 3 }
        if height >= 360 { return 2 }
        return 1
    }

    /// Our own camera track (nil while the camera is off), for the self tile.
    public var onLocalVideoTrack: ((RTCVideoTrack?) -> Void)?

    public init(factory: RTCPeerConnectionFactory, iceServers: [RTCIceServer],
                cryptors: GroupFrameCryptorHub, selfPseudonym: String) {
        self.hub = cryptors
        self.selfPseudonym = selfPseudonym
        super.init(factory: factory, iceServers: iceServers)
    }

    public func start() async throws {
        let pc = try makePeerConnection()
        // Sender ids are the (fixed) track ids: entries left by a previous
        // publisher PeerConnection of this call must not make `attachSender`
        // believe a sender of THIS one already has its cryptor.
        hub.detachSenders()
        tuning = GroupNativeTuning()

        // Audio.
        let audioSource = factory.audioSource(with: nil)
        let audio = factory.audioTrack(with: audioSource, trackId: "audio0")
        audio.isEnabled = micEnabled
        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .sendOnly
        audioInit.streamIds = ["qa"]
        guard let audioTransceiver = pc.addTransceiver(with: audio, init: audioInit) else { throw GroupPeerError.transceiverFailed }
        restrictHeaderExtensions(audioTransceiver)
        applyAudioSenderProfile(audioTransceiver.sender)
        // Fail closed: a sender without its cryptor would publish in the clear.
        guard hub.attachSender(audioTransceiver.sender, participantId: selfPseudonym) else { throw GroupPeerError.cryptorFailed }
        audioTrack = audio

        // Video: always present (a camera toggle is a `configure`, never a
        // renegotiation), disabled until the camera runs.
        let source = factory.videoSource(forScreenCast: false)
        let video = factory.videoTrack(with: source, trackId: "video0")
        video.isEnabled = false
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .sendOnly
        videoInit.streamIds = ["qa"]
        videoInit.sendEncodings = Self.simulcast.map { layer in
            let encoding = RTCRtpEncodingParameters()
            encoding.rid = layer.rid
            encoding.isActive = true
            encoding.scaleResolutionDownBy = NSNumber(value: layer.scale)
            encoding.maxFramerate = NSNumber(value: layer.fps)
            encoding.maxBitrateBps = NSNumber(value: layer.maxBps)
            encoding.numTemporalLayers = NSNumber(value: 3)
            return encoding
        }
        guard let videoTransceiver = pc.addTransceiver(with: video, init: videoInit) else { throw GroupPeerError.transceiverFailed }
        restrictHeaderExtensions(videoTransceiver)
        guard hub.attachSender(videoTransceiver.sender, participantId: selfPseudonym) else { throw GroupPeerError.cryptorFailed }
        videoSource = source
        videoTrack = video
        videoSender = videoTransceiver.sender
    }

    public func createOffer(iceRestart: Bool) async throws -> String {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: iceRestart ? ["IceRestart": "true"] : nil, optionalConstraints: nil)
        let offer = try await createOffer(constraints)
        let munged = GroupSdpRules.mungeLocal(offer.sdp, role: .publisherOffer)
        try await setLocal(RTCSessionDescription(type: .offer, sdp: munged))
        return munged
    }

    public func applyAnswer(_ sdp: String) async throws {
        try await setRemote(RTCSessionDescription(type: .answer, sdp: GroupSdpRules.mungeRemote(sdp)))
    }

    public func close() {
        stopCapturer()
        tuning?.stop()
        tuning = nil
        // Only OUR sender cryptors: the receivers belong to the subscriber.
        hub.detachSenders()
        closePeerConnection()
        videoTrack = nil
        audioTrack = nil
        videoSource = nil
        videoSender = nil
        onLocalVideoTrack = nil
    }

    // MARK: Controls

    public func setMicrophoneEnabled(_ enabled: Bool) {
        micEnabled = enabled
        audioTrack?.isEnabled = enabled
    }

    /// Camera on / off. Started only after the permission is granted.
    public func setCameraEnabled(_ enabled: Bool) async -> CameraResult {
        guard let video = videoTrack, let source = videoSource else { return .notReady }
        if !enabled {
            stopCapturer()
            video.isEnabled = false
            onLocalVideoTrack?(nil)
            return .stopped
        }
        #if os(iOS)
        let granted = await Self.cameraAccess()
        guard granted else { return .permissionDenied }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let camera = devices.first(where: { $0.position == .front }) ?? devices.first else { return .noCamera }
        let format = Self.closestFormat(for: camera)
        guard let selected = format else { return .noCamera }
        sourceLayerCap = Self.layerCap(forHeight: CMVideoFormatDescriptionGetDimensions(selected.formatDescription).height)
        let fps = selected.videoSupportedFrameRateRanges.compactMap { Int($0.maxFrameRate) }.filter { $0 <= 30 }.max() ?? 30
        let newCapturer = RTCCameraVideoCapturer(delegate: source)
        let started: Bool = await withCheckedContinuation { continuation in
            newCapturer.startCapture(with: camera, format: selected, fps: fps) { error in
                continuation.resume(returning: error == nil)
            }
        }
        guard started else { return .noCamera }
        capturer = newCapturer
        video.isEnabled = true
        setActiveLayers(sourceLayerCap)
        onLocalVideoTrack?(video)
        return .started
        #else
        return .noCamera
        #endif
    }

    /// Sync on purpose: inside an `async` function `stopCapture()` would bind to the
    /// completion-handler overload the SDK imports as `async` and need an `await`.
    private func stopCapturer() {
        capturer?.stopCapture()
        capturer = nil
    }

    /// Keeps `count` of the three simulcast encodings active (1 = l only,
    /// 2 = l+m, 3 = all): the thermal / congestion policy of `GroupPublishPolicy`.
    public func setActiveLayers(_ count: Int) {
        guard let sender = videoSender else { return }
        let allowed = min(count, sourceLayerCap)
        let parameters = sender.parameters
        for (index, encoding) in parameters.encodings.enumerated() { encoding.isActive = index < allowed }
        sender.parameters = parameters
    }

    // MARK: Internals

    /// The 1:1 native-audio sender profile: 32 kbps min = max, DSCP high.
    private func applyAudioSenderProfile(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        guard !parameters.encodings.isEmpty else { return }
        let bps = NSNumber(value: AudioSdpPolicy.maxAverageBitrateBps)
        for encoding in parameters.encodings {
            encoding.minBitrateBps = bps
            encoding.maxBitrateBps = bps
        }
        parameters.encodings[0].networkPriority = .high
        sender.parameters = parameters
    }

    #if os(iOS)
    private static func cameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in continuation.resume(returning: granted) }
            }
        default: return false
        }
    }

    private static func closestFormat(for camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
        RTCCameraVideoCapturer.supportedFormats(for: camera).min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(da.width - 1280) + abs(da.height - 720) < abs(db.width - 1280) + abs(db.height - 720)
        }
    }
    #endif
}

// MARK: - Subscriber

/// The multistream subscriber PeerConnection (spec §4.3): Janus offers, we
/// answer. Every receiver gets its frame cryptor (participantId = the
/// publisher's pseudonym) BEFORE the answer exists, so no frame is ever
/// rendered without one.
public final class GroupSubscriberPeer: GroupPeerBase, GroupSubscriberLink, @unchecked Sendable {

    public enum TrackKind: Sendable { case audio, video }

    public struct RemoteTrack {
        /// Publisher pseudonym.
        public let feedId: String
        /// Subscriber-side mid.
        public let mid: String
        public let kind: TrackKind
        public let isScreenShare: Bool
        /// nil = the stream went away.
        public let track: RTCMediaStreamTrack?
    }

    public var onRemoteTrack: ((RemoteTrack) -> Void)?

    private let hub: GroupFrameCryptorHub
    private var streamsByMid: [String: VideoRoomStream] = [:]
    private var reported: [String: (signature: String, feedId: String, kind: TrackKind, screen: Bool)] = [:]
    private var restrictedMids: Set<String> = []

    public init(factory: RTCPeerConnectionFactory, iceServers: [RTCIceServer], cryptors: GroupFrameCryptorHub) {
        self.hub = cryptors
        super.init(factory: factory, iceServers: iceServers)
    }

    public func start() async throws {
        _ = try makePeerConnection()
        // Receiver ids can repeat across PeerConnections: entries of a previous
        // subscriber must not make `attachReceiver` believe a receiver of THIS one
        // already has its cryptor.
        hub.detachReceivers()
    }

    public func acceptOffer(_ sdp: String, streams: [VideoRoomStream]) async throws -> String {
        guard let pc = currentPeerConnection else { throw GroupPeerError.notStarted }
        try await setRemote(RTCSessionDescription(type: .offer, sdp: GroupSdpRules.mungeRemote(sdp)))
        stateLock.lock()
        streamsByMid = Dictionary(streams.filter { $0.feedId != nil }.map { ($0.mid, $0) }, uniquingKeysWith: { _, new in new })
        stateLock.unlock()
        try prepareTransceivers(of: pc)
        let answer = try await createAnswer(RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let munged = GroupSdpRules.mungeLocal(answer.sdp, role: .subscriberAnswer)
        try await setLocal(RTCSessionDescription(type: .answer, sdp: munged))
        return munged
    }

    /// After every remote offer: restrict extensions of new transceivers, bind
    /// cryptors to the right publisher, report tracks that appeared, moved or
    /// went away. Fail closed (spec §4.3 / §5.3): every audio / video receiver
    /// gets a cryptor before the answer exists, and a receiver that is not a
    /// known, enabled publisher stream gets one bound to an id nobody holds a
    /// key for, so whatever arrives on it is discarded, never played in the clear.
    private func prepareTransceivers(of pc: RTCPeerConnection) throws {
        stateLock.lock()
        let byMid = streamsByMid
        stateLock.unlock()
        var seen = Set<String>()
        for transceiver in pc.transceivers {
            let mid = transceiver.mid
            guard !mid.isEmpty else { continue }
            seen.insert(mid)
            if !restrictedMids.contains(mid) {
                restrictedMids.insert(mid)
                restrictHeaderExtensions(transceiver)
            }
            guard transceiver.mediaType == .audio || transceiver.mediaType == .video else { continue }
            guard let stream = byMid[mid], let feed = stream.feedId, !stream.disabled else {
                hub.attachReceiver(transceiver.receiver, participantId: GroupFrameCryptorHub.unboundParticipantId)
                if let old = reported.removeValue(forKey: mid) {
                    onRemoteTrack?(RemoteTrack(feedId: old.feedId, mid: mid, kind: old.kind, isScreenShare: old.screen, track: nil))
                }
                continue
            }
            guard hub.attachReceiver(transceiver.receiver, participantId: feed) else { throw GroupPeerError.cryptorFailed }
            let kind: TrackKind = transceiver.mediaType == .video ? .video : .audio
            let screen = stream.isScreenShare
            let signature = "\(feed)|\(screen)"
            if reported[mid]?.signature == signature { continue }
            if let old = reported[mid] {
                onRemoteTrack?(RemoteTrack(feedId: old.feedId, mid: mid, kind: old.kind, isScreenShare: old.screen, track: nil))
            }
            reported[mid] = (signature: signature, feedId: feed, kind: kind, screen: screen)
            if let track = transceiver.receiver.track {
                onRemoteTrack?(RemoteTrack(feedId: feed, mid: mid, kind: kind, isScreenShare: screen, track: track))
            }
        }
        for (mid, old) in reported where !seen.contains(mid) {
            reported[mid] = nil
            onRemoteTrack?(RemoteTrack(feedId: old.feedId, mid: mid, kind: old.kind, isScreenShare: old.screen, track: nil))
        }
    }

    /// Per-mid inbound video loss counters, decoded audio levels (measured after
    /// decryption) and the available incoming bitrate.
    public func inboundStats() async -> GroupSubscriberStats? {
        guard let pc = currentPeerConnection, let report = await statsReport() else { return nil }
        var midByTrack: [String: String] = [:]
        for transceiver in pc.transceivers {
            if let trackId = transceiver.receiver.track?.trackId, !transceiver.mid.isEmpty { midByTrack[trackId] = transceiver.mid }
        }
        var videos: [GroupInboundVideoStat] = []
        var levels: [String: Double] = [:]
        var available: Double?
        for (_, stat) in report.statistics {
            if stat.type == "inbound-rtp" {
                let mid = (stat.values["mid"] as? String) ?? (stat.values["trackIdentifier"] as? String).flatMap { midByTrack[$0] }
                guard let mid = mid else { continue }
                let kind = stat.values["kind"] as? String
                if kind == "video" {
                    videos.append(GroupInboundVideoStat(
                        mid: mid,
                        packetsLost: (stat.values["packetsLost"] as? NSNumber)?.intValue ?? 0,
                        packetsReceived: (stat.values["packetsReceived"] as? NSNumber)?.intValue ?? 0))
                } else if kind == "audio" {
                    levels[mid] = (stat.values["audioLevel"] as? NSNumber)?.doubleValue ?? 0
                }
            } else if stat.type == "candidate-pair",
                      (stat.values["nominated"] as? NSNumber)?.boolValue == true,
                      let bps = (stat.values["availableIncomingBitrate"] as? NSNumber)?.doubleValue {
                available = bps
            }
        }
        return GroupSubscriberStats(videos: videos, availableIncomingBps: available, audioLevels: levels)
    }

    public func close() {
        for (mid, old) in reported {
            onRemoteTrack?(RemoteTrack(feedId: old.feedId, mid: mid, kind: old.kind, isScreenShare: old.screen, track: nil))
        }
        reported.removeAll()
        onRemoteTrack = nil
        // Only the receiver cryptors: our own senders belong to the publisher,
        // which keeps running when just the subscriber is dropped.
        hub.detachReceivers()
        closePeerConnection()
    }
}

// MARK: - Native tuning

/// Process-wide native Opus tuning of the 1:1 native path, applied for the
/// life of a group call: FEC floor 10 %, adaptive encoder / decoder
/// complexity that follows the thermal and power state (same policies and
/// hysteresis drivers as `QAudionPeerConnection`).
final class GroupNativeTuning {
    private let lock = NSLock()
    private var encoderDriver: ComplexityHysteresisDriver?
    private var decoderDriver: ComplexityHysteresisDriver?
    private var thermalObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?

    init() {
        let hint = DeviceCapabilityHint(
            isOldDevice: QaudionDeviceClass.isA11OrEarlier(),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
        let tier = ThermalTier(from: ProcessInfo.processInfo.thermalState)
        let clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        let encoder = ComplexityHysteresisDriver(
            initial: AdaptiveOpusComplexityPolicy.target(thermalTier: tier, device: hint),
            ladder: AdaptiveOpusComplexityPolicy.ladder(for: hint), nowMs: clock)
        let decoder = ComplexityHysteresisDriver(
            initial: AdaptiveOpusDecoderComplexityPolicy.target(thermalTier: tier, device: hint),
            ladder: AdaptiveOpusDecoderComplexityPolicy.ladder(for: hint), nowMs: clock)
        encoderDriver = encoder
        decoderDriver = decoder
        QaudionRuntimeTuning.setMinPacketLossPercent(PlpPolicy.minPct)
        QaudionRuntimeTuning.setEncoderComplexity(encoder.currentComplexity)
        QaudionRuntimeTuning.setDecoderComplexity(decoder.currentComplexity)
        let reapply: () -> Void = { [weak self] in self?.reapply() }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in reapply() }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in reapply() }
    }

    private func reapply() {
        let hint = DeviceCapabilityHint(
            isOldDevice: QaudionDeviceClass.isA11OrEarlier(),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
        let tier = ThermalTier(from: ProcessInfo.processInfo.thermalState)
        lock.lock()
        let newEncoder = encoderDriver?.update(target: AdaptiveOpusComplexityPolicy.target(thermalTier: tier, device: hint))
        let newDecoder = decoderDriver?.update(target: AdaptiveOpusDecoderComplexityPolicy.target(thermalTier: tier, device: hint))
        lock.unlock()
        if let newEncoder = newEncoder { QaudionRuntimeTuning.setEncoderComplexity(newEncoder) }
        if let newDecoder = newDecoder { QaudionRuntimeTuning.setDecoderComplexity(newDecoder) }
    }

    func stop() {
        if let observer = thermalObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = powerObserver { NotificationCenter.default.removeObserver(observer) }
        thermalObserver = nil
        powerObserver = nil
    }
}
#endif
