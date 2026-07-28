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

        /// Aggregate ICE+DTLS connection state transitions (the "combined"
        /// `RTCPeerConnectionState`, distinct from the ICE-only state above).
        /// Same asymmetric-observer gap already found + fixed this session on
        /// Android (missing onConnectionChange): DTLS can fail independently
        /// of ICE, and only this callback observes that. Default no-op below
        /// so existing conformers need not implement it.
        func peerConnection(_ pc: QAudionPeerConnection,
                            didChangeConnectionState state: RTCPeerConnectionState)

        /// Signaling state transitions.
        func peerConnection(_ pc: QAudionPeerConnection,
                            didChangeSignalingState state: RTCSignalingState)

        /// Remote track received (e.g. peer's microphone audio).
        func peerConnection(_ pc: QAudionPeerConnection,
                            didReceiveRemoteAudioTrack track: RTCAudioTrack)
        /// Remote video track (only fired when video is negotiated).
        func peerConnection(_ pc: QAudionPeerConnection,
                            didReceiveRemoteVideoTrack track: RTCVideoTrack)
        /// Remote video RTP receiver — the attach point for the native
        /// `RTCFrameCryptor` (decrypts inbound video). Fires on the WebRTC
        /// signalling thread alongside `didReceiveRemoteVideoTrack`. Default
        /// no-op so non-video conformers need not implement it.
        func peerConnection(_ pc: QAudionPeerConnection,
                            didReceiveRemoteVideoReceiver receiver: RTCRtpReceiver)
    }

    public weak var delegate: Delegate?

    /// Underlying RTCPeerConnection. Avoid touching directly — use the
    /// high-level methods on this class instead.
    public private(set) var peerConnection: RTCPeerConnection?

    private let factory: RTCPeerConnectionFactory
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?

    /// GAP-3 fix (2026-07-07 cross-platform matrix audit) — the COMMITTED
    /// local description snapshotted at the START of `createOffer`, before
    /// `setLocalDescription` overwrites it with the new (pending) re-offer.
    /// Feeds `preserveDtlsRoleInUpgradeAnswer` when the peer's answer comes
    /// back via `setRemoteAnswer` — the initiator-side counterpart of the
    /// snapshot `createAnswer` takes locally for the responder side. nil on
    /// the very first negotiation of the call (no established role yet),
    /// which makes the pin a no-op. Mirrors Android
    /// `PeerConnectionHolder.preRenegotiationLocalSdp`.
    private var establishedLocalSdpBeforeUpgrade: String?
    /// The local video RTP sender — captured when `addLocalVideoTrack` runs, so
    /// the native FrameCryptor can be attached to it (Android attaches to
    /// `videoTransceiver.sender`). nil until a video track is added.
    public private(set) var videoSender: RTCRtpSender?
    /// Native libwebrtc FrameCryptor for the 1:1 video sender+receiver. Created
    /// lazily (without the key) via `ensureNativeVideoCryptor`; the key is
    /// published later via `setKey`, and the sender/receiver cryptors are
    /// attached when their tracks exist. Replaces the codec-layer seal.
    public private(set) var nativeVideoCryptor: NativeVideoFrameCryptor?
    /// CALLEE-UPGRADE-PURPLE FIX (2026-07-01) — the mid of the FIRST real inbound
    /// video transceiver, recorded when its receiver surfaces in
    /// `didAdd rtpReceiver`. Once set, a later `didAdd` for a video receiver on a
    /// DIFFERENT mid whose transceiver is recv-only with NO sender track is the
    /// phantom duplicate m-line libwebrtc M144 mints on a callee-side video
    /// upgrade — it is IGNORED so the renderer sink stays on the established
    /// track (mirrors Android `cryptorBoundMid` +
    /// `shouldIgnorePhantomVideoTransceiver`, qaudion-android-new 39ea0e5f).
    /// nil until the first video receiver arrives; cleared in `close()`.
    /// Read-public (WIRE_SPEC §8.7): the call controller ships it as the
    /// `mid` field of `call_media_ready` when the receiver cryptor is ready.
    public private(set) var establishedVideoReceiverMid: String?
    /// MID-UNAVAILABLE-AT-FIRE-TIME FIX (2026-07-05, device-repro'd across 3
    /// separate video upgrades on v1.0.737): `tx.mid` is reliably EMPTY at the
    /// exact moment `didAdd rtpReceiver` fires in this environment — the SDP
    /// `mid` is assigned once offer/answer negotiation fully completes, which
    /// hasn't necessarily happened yet when this delegate runs. Relying on it
    /// as the bind/relatch/phantom identity key meant `resolveSinkBinding`
    /// ALWAYS saw an empty `incomingMid` and took the (deliberately
    /// conservative) fail-open no-op path — never bindInitial, never relatch,
    /// every single time, confirmed via device log (neither "video mid est=1"
    /// nor "video relatch=1" printed even once across 3 reproductions).
    /// `rtpReceiver.receiverId` IS reliably available immediately (it's how
    /// `tx` gets resolved via `.first { $0.receiver.receiverId == ... }` at
    /// all), so THIS is the identity key `resolveSinkBinding` actually
    /// switches on. `establishedVideoReceiverMid` above still holds the best-
    /// effort real SDP mid (for the WIRE_SPEC §8.7 `call_media_ready` field);
    /// this field is the separate, reliable one the bind/relatch decision
    /// itself is keyed on.
    private var establishedVideoReceiverKey: String?
    /// The transceiver `establishedVideoReceiverKey` is currently bound to.
    /// Tracked alongside the key so a later `didAdd rtpReceiver` for a
    /// DIFFERENT receiver can tell a legitimate re-latch (WIRE_SPEC §8.6, e.g.
    /// an offerer-side renegotiation replacing the transceiver) from the M144
    /// phantom duplicate the guard above already handles. nil until the first
    /// video receiver arrives; cleared in `close()`.
    private var establishedVideoReceiverTransceiver: RTCRtpTransceiver?
    private let mediaConstraints = RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
    )
    private let stableStreamId = "qaudion-stream-0"
    private let audioTrackId = "audio0"
    private let videoTrackId = "video0"

    // ── W-DCAUDIO: sealed-audio DataChannel ──────────────────────────────────
    /// Cross-platform sealed-audio DataChannel label. MUST match Android's
    /// `PeerConnectionHolder.DATA_CHANNEL_LABEL` and Desktop's `SEALED_DC_LABEL`
    /// ("qaudion-audio") so the channel is recognised on both ends.
    private let audioDataChannelLabel = "qaudion-audio"
    /// The sealed-audio DataChannel. Carries the SAME `WireRelayFrameCodec`
    /// envelope bytes as the WS relay, so it is byte-compatible with Android's
    /// DefaultFrameRelayTransport DC and Desktop's SealedAudioPipeline. It is the
    /// P2P primary path for voice; the WS relay is the fallback (the app sends on
    /// the DC when open, else WS). Replaces the SRTP m=audio track entirely —
    /// there is no plain DTLS-SRTP audio anywhere.
    private var audioDataChannel: RTCDataChannel?
    /// W-DCBACKPRESSURE (2026-07-21) — mirrors Android's
    /// `DC_BUFFERED_AMOUNT_DROP_THRESHOLD` (Wave 2C-15 hotfix, 2026-04-29,
    /// `PeerConnectionHolder.kt`): when the outbound SCTP queue backs up
    /// past this many bytes, prefer dropping the new frame over letting the
    /// queue grow unbounded. iOS shipped with NO backpressure guard at all
    /// on this exact wire mechanism (the "qaudion-audio" sealed DataChannel,
    /// byte-identical to Android's) until this fix — under a stressed
    /// uplink the queue could grow without limit instead of shedding load,
    /// unlike Android's sibling implementation.
    private static let audioDcBufferedAmountDropThreshold: UInt64 = 1500
    private var lastAudioDcBackpressureLogAtMs: Int64 = 0
    /// Invoked on the WebRTC signalling thread for each inbound sealed audio
    /// frame received over the DataChannel. The `Data` is the raw
    /// `WireRelayFrameCodec` envelope — identical to what the WS "audio_frame"
    /// handler passes to `handleIncomingEncryptedFrame` after base64 decode — so
    /// the app routes it straight there.
    public var onAudioDataChannelFrame: ((Data) -> Void)?

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

    /// W-DCAUDIO — NO WebRTC SRTP audio track is created. Q-Audion voice rides
    /// ONLY the sealed "qaudion-audio" DataChannel (see `createAudioDataChannel`),
    /// byte-identical to Android/Desktop's sealed DC. A WebRTC m=audio track —
    /// even a disabled/silent one — creates a redundant classical DTLS-SRTP media
    /// section (non-PQC, relay-MITM-able, outside the SAS) and wastes an RTP flow,
    /// so it must not exist at all (not merely be disabled). The PC negotiates
    /// m=application (the DataChannel) + m=video; there is NO m=audio.
    ///
    /// Kept as a no-op (returns false) so existing call sites in
    /// `QAudionWebRtcCallController` keep compiling; the caller now invokes
    /// `createAudioDataChannel()` instead to populate the audio media section.
    /// (History: pre-2026-06-24 this added a disabled silent SRTP track for "SDP
    /// symmetry" — removed at source per the uniform "sealed-DataChannel audio
    /// only" policy across iOS/Android/Desktop.)
    @discardableResult
    public func addLocalAudioTrack() -> Bool {
        return false
    }

    /// W-DCAUDIO — create the outbound sealed-audio DataChannel. CALLER side only
    /// (the callee receives it via the `didOpen` delegate). Must run BEFORE
    /// `createOffer` so the SDP carries the m=application section — which, now that
    /// there is no m=audio track, is the call's audio media section.
    /// `isOrdered = false` + `maxRetransmits = 0` = unreliable/unordered, matching
    /// Android's DefaultFrameRelayTransport DC (VoIP tolerates loss far better than
    /// head-of-line blocking).
    @discardableResult
    public func createAudioDataChannel() -> Bool {
        guard let pc = peerConnection, audioDataChannel == nil else { return false }
        let cfg = RTCDataChannelConfiguration()
        cfg.isOrdered = false
        cfg.maxRetransmits = 0
        guard let dc = pc.dataChannel(forLabel: audioDataChannelLabel, configuration: cfg) else {
            print("[WebRTC] createAudioDataChannel: dataChannel(forLabel:) returned nil")
            return false
        }
        dc.delegate = self
        audioDataChannel = dc
        print("[WebRTC] sealed-audio DataChannel created (label=\(audioDataChannelLabel))")
        return true
    }

    /// W-DCAUDIO — send one sealed audio frame over the DataChannel if it is open.
    /// Returns `true` if queued on the DC (or silently dropped for backpressure,
    /// see below — the DC itself is still healthy); `false` if the DC is not
    /// open (the caller must then fall back to the WS relay). `data` is the raw
    /// `WireRelayFrameCodec` envelope (the exact bytes the WS path base64-wraps).
    ///
    /// W-DCBACKPRESSURE — mirrors Android's Wave 2C-15 hotfix: when
    /// `dc.bufferedAmount` exceeds `audioDcBufferedAmountDropThreshold`, drop
    /// this frame instead of enqueuing it, same as Android's
    /// `PeerConnectionHolder.sendOnDataChannel`. Returns `true` (not `false`)
    /// for a backpressure drop — this is a transient, self-recovering
    /// condition on an otherwise-healthy DC, NOT a reason to force the caller
    /// into a full WS-relay fallback (which `false` triggers); the receiver's
    /// PLC/FEC/comfort-noise masks the occasional dropped frame, same as on
    /// Android. Letting the queue grow unbounded instead produces a
    /// permanent, non-recovering "voice arriving late" — or, worse, the
    /// underlying SCTP association can itself become unhealthy under a
    /// large enough backlog.
    @discardableResult
    public func sendAudioFrameData(_ data: Data) -> Bool {
        guard let dc = audioDataChannel, dc.readyState == .open else { return false }
        let backlog = dc.bufferedAmount
        if AudioDcBackpressureGate.shouldDrop(bufferedAmount: backlog, threshold: Self.audioDcBufferedAmountDropThreshold) {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if nowMs - lastAudioDcBackpressureLogAtMs > 1_000 {
                print("[WebRTC] DC backpressure: dropping outbound audio frame (bufferedAmount=\(backlog) > \(Self.audioDcBufferedAmountDropThreshold))")
                lastAudioDcBackpressureLogAtMs = nowMs
            }
            return true
        }
        return dc.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    /// W-DCAUDIO — true when the sealed-audio DataChannel is open (P2P voice is
    /// live). When false the caller routes audio over the WS relay fallback.
    public func isAudioDataChannelOpen() -> Bool {
        guard let dc = audioDataChannel else { return false }
        return dc.readyState == .open
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
        // W-DUPETRANSCEIVER (2026-07-28) — createOffer() pre-allocates a
        // sendrecv video transceiver on every call's INITIAL offer (BUG2 fix,
        // see its own kdoc there) specifically so a LATER mid-call
        // `upgradeToVideo()` reuses that already-negotiated mid instead of
        // adding a brand-new m-line to the live BUNDLE. `pc.add(track:
        // streamIds:)` (`RTCPeerConnection.addTrack`) is supposed to find and
        // reuse a transceiver whose sender has no track per the WebRTC
        // addTrack algorithm — live-reproduced 2026-07-28 (call
        // 562fc6de..., iOS-caller + iOS-initiated upgrade) it did NOT: iOS's
        // own logs showed the pre-allocated mid=0 orphaned and a fresh mid=3
        // negotiated instead, while Android (still bound to ITS OWN mid=0,
        // matching iOS's original transceiver) never saw the peer's real
        // video at all — SDP negotiates, ICE/DTLS connect, zero video ever
        // arrives, exactly the recurring "purple on upgrade" signature.
        // Rather than trust the implicit matching, explicitly find the
        // existing video transceiver (if the pre-allocation already put one
        // there) and bind the track directly to ITS sender — unambiguous,
        // guaranteed to keep the same mid.
        if let existing = pc.transceivers.first(where: { $0.mediaType == .video }) {
            // Direction isn't clamped here: the pre-allocated transceiver was
            // created with RTCRtpTransceiverInit().direction = .sendRecv (see
            // createOffer's BUG2-fix pre-allocation) and `direction` on an
            // already-live RTCRtpTransceiver is get-only on this WebRTC SDK
            // build — nothing between pre-allocation and this reuse would
            // have flipped it away from sendRecv on a still-trackless
            // transceiver anyway.
            existing.sender.track = track
            localVideoTrack = track
            videoSender = existing.sender
            if let capturer = capturer {
                capturer.delegate = source
            }
            print("[WebRTC] local VIDEO track bound to EXISTING transceiver mid=\(existing.mid) (W-DUPETRANSCEIVER)")
            return source
        }
        pc.add(track, streamIds: [stableStreamId])
        localVideoTrack = track
        // Capture the RTP sender for the native FrameCryptor attach (Android
        // attaches to videoTransceiver.sender). The track is added
        // synchronously so the sender exists immediately.
        videoSender = pc.senders.first { $0.track?.kind == kRTCMediaStreamTrackKindVideo }
        if let capturer = capturer {
            // Hook the capturer's frames to the source.
            capturer.delegate = source
        }
        // W466 — confirm the local camera track was plumbed into the
        // peer connection.
        print("[WebRTC] local VIDEO track added to peer connection (sender=\(videoSender != nil))")
        return source
    }

    // MARK: - Native video FrameCryptor (insertable streams)

    /// Create the per-call native FrameCryptor holder (idempotent). Does NOT
    /// require the K_video key yet — the key is published later via `setKey` on
    /// the returned holder. Creating it early (at call setup) avoids the
    /// receiver-attach-before-key deadlock.
    @discardableResult
    public func ensureNativeVideoCryptor(participantId: String) -> NativeVideoFrameCryptor {
        if let c = nativeVideoCryptor { return c }
        let c = NativeVideoFrameCryptor(factory: factory, participantId: participantId)
        nativeVideoCryptor = c
        return c
    }

    /// Attach + enable the native cryptor on the local video sender. Idempotent;
    /// safe to call repeatedly (e.g. after setLocalDescription). No-op until the
    /// holder exists (`ensureNativeVideoCryptor`) and the sender is present.
    @discardableResult
    public func attachVideoSenderCryptor() -> Bool {
        guard let s = videoSender, let c = nativeVideoCryptor else { return false }
        return c.attachSender(s)
    }

    /// Attach + enable the native cryptor on an inbound video receiver. Call
    /// from the `didReceiveRemoteVideoReceiver` delegate (signalling thread).
    @discardableResult
    public func attachVideoReceiverCryptor(_ receiver: RTCRtpReceiver) -> Bool {
        guard let c = nativeVideoCryptor else { return false }
        return c.attachReceiver(receiver)
    }

    /// OFFERER-UPGRADE DECODE FIX (2026-07-05) — dispose + re-create the
    /// receiver cryptor against the video transceiver's CURRENT receiver,
    /// AFTER a renegotiation answer has been applied.
    ///
    /// Why: the iOS-caller + iOS-video-upgrade combo is the ONLY flow where
    /// the video transceiver is created by a LOCAL `addTrack` on a
    /// second-round offer (every other combo receives its video m-line from
    /// a REMOTE offer — Android pre-creates its video transceiver at PC
    /// construction so any Android-originated SDP already carries m=video).
    /// In that flow `didAdd rtpReceiver` fires while the receiver is not yet
    /// bound to its final RTP channel (device-confirmed: the transceiver
    /// lookup in didAdd yields an EMPTY mid in exactly this combo, while the
    /// same mid read later for call_media_ready resolves fine — a pure
    /// attach-timing artifact). The RTCFrameCryptor created at that moment
    /// initializes successfully but its native frame transformer stays bound
    /// to the pre-negotiation state: encrypted inbound H265 then BYPASSES the
    /// decryptor and hits the decoder as ciphertext — bytesReceived grows,
    /// framesDecoded stays 0, permanently (the black-screen bug, repro'd ~10
    /// times with matching key fingerprints and "successful" cryptor attach).
    ///
    /// Called from applyUpgradeAnswer after setRemoteAnswer succeeds — the
    /// point where the transceiver is guaranteed associated (mid assigned,
    /// channel live). On flows that already work (e.g. iOS-callee + iOS
    /// upgrade takes this same code path) the dispose+recreate costs one
    /// keyframe round-trip (<1s, the §8.7 kfreq machinery covers it) and
    /// re-attaches to the same, already-correct receiver — harmless.
    @discardableResult
    public func rebindVideoReceiverCryptorPostNegotiation() -> Bool {
        guard let pc = peerConnection, let cryptor = nativeVideoCryptor else {
            print("ev=vpostneg skip=1")
            return false
        }
        let vids = pc.transceivers.filter { $0.mediaType == .video }
        // Prefer the associated (mid-assigned) transceiver; a phantom/orphan
        // has no mid post-negotiation.
        guard let tx = vids.first(where: { !$0.mid.isEmpty }) ?? vids.first else {
            print("ev=vpostneg tx=0")
            return false
        }
        let receiver = tx.receiver
        let ok = cryptor.rebindReceiver(receiver)
        establishedVideoReceiverKey = receiver.receiverId
        let rawMid = tx.mid
        if !rawMid.isEmpty { establishedVideoReceiverMid = rawMid }
        establishedVideoReceiverTransceiver = tx
        print("[WebRTC] post-negotiation video receiver cryptor rebound mid=\(rawMid) ok=\(ok)")
        print("ev=vpostneg ok=\(ok ? 1 : 0) mid=\(rawMid)")
        return ok
    }

    /// BUG2 fix (2026-07-11) — sender-side mirror of
    /// `rebindVideoReceiverCryptorPostNegotiation`, for the SENDER half of
    /// the exact same 2026-07-05-diagnosed bug class: on the iOS-caller +
    /// iOS-video-upgrade combo, `upgradeToVideo()`'s `attachVideoSenderCryptor()`
    /// call (immediately after `addLocalVideoTrack`) attaches the native
    /// cryptor to the sender BEFORE the offer/answer round-trip completes
    /// — the same pre-negotiation-state binding that made the RECEIVER
    /// fix necessary. Call from `applyUpgradeAnswer` (initiator side)
    /// AFTER `setRemoteAnswer` succeeds, alongside the existing receiver
    /// rebind, so the sender cryptor binds against the sender as it
    /// exists once the transceiver is guaranteed associated (mid
    /// assigned, channel live) — never against the transient pre-answer
    /// object.
    @discardableResult
    public func rebindVideoSenderCryptorPostNegotiation() -> Bool {
        guard let pc = peerConnection, let cryptor = nativeVideoCryptor else {
            print("ev=vspostneg skip=1")
            return false
        }
        guard let sender = pc.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo }) else {
            print("ev=vspostneg sender=0")
            return false
        }
        videoSender = sender
        let ok = cryptor.rebindSender(sender)
        print("[WebRTC] post-negotiation video SENDER cryptor rebound ok=\(ok)")
        print("ev=vspostneg ok=\(ok ? 1 : 0)")
        return ok
    }

    public func setVideoMuted(_ muted: Bool) {
        // F-02 — an un-mute must not re-open a lane we closed for lack of
        // frame-level E2EE. Without this the latch is decorative: the user taps
        // the camera button and the plaintext video we refused to send goes out.
        if !muted && videoFailClosed {
            print("[WebRTC] setVideoMuted(false) refused — video is fail-closed (no frame E2EE)")
            return
        }
        localVideoTrack?.isEnabled = !muted
    }

    /// F-02 (2026-07-26) — refuse to carry video that is not frame-encrypted.
    ///
    /// `sframe-v1` is a PLAINTEXT capability string the server relays. Strip it
    /// from both legs and iOS used to latch `.legacy` and keep sending: video left
    /// the device wrapped in DTLS-SRTP alone, terminated by whoever supplied the
    /// fingerprint the server passed on. Android has refused this since
    /// 2026-05-31; this is that behaviour.
    ///
    /// VIDEO only, never the call — audio is sealed on its own path and keeps
    /// flowing. That is what keeps this inside W-NOBRICK.
    public func failClosedVideo(reason: String) {
        if videoFailClosed { return }
        videoFailClosed = true
        localVideoTrack?.isEnabled = false
        for sender in peerConnection?.senders ?? [] {
            (sender.track as? RTCVideoTrack)?.isEnabled = false
        }
        for receiver in peerConnection?.receivers ?? [] {
            (receiver.track as? RTCVideoTrack)?.isEnabled = false
        }
        print("[WebRTC] VIDEO FAIL-CLOSED — \(reason)")
    }

    /// Lift the latch once the peer's capabilities turn out to include
    /// `sframe-v1` after all — UPWARD only.
    ///
    /// This is not symmetry for its own sake. A caps-less duplicate envelope can
    /// negotiate an EMPTY tag set first and the real capabilities arrive a moment
    /// later; the `.legacy` latch used to survive that and produced permanent black
    /// video, which is exactly the bug `acceptPeerCapabilities` was changed to fix.
    /// The cryptor must already be installed when this is called.
    public func reopenVideoAfterE2eeAgreed() {
        guard videoFailClosed else { return }
        videoFailClosed = false
        localVideoTrack?.isEnabled = true
        for sender in peerConnection?.senders ?? [] {
            (sender.track as? RTCVideoTrack)?.isEnabled = true
        }
        for receiver in peerConnection?.receivers ?? [] {
            (receiver.track as? RTCVideoTrack)?.isEnabled = true
        }
        print("[WebRTC] video fail-close LIFTED — peer capabilities now include sframe-v1")
    }

    /// True while video is disabled for lack of frame-level E2EE.
    public private(set) var videoFailClosed = false

    /// W536 — true once `addLocalVideoTrack` has installed a track.
    /// Used by QAudionWebRtcCallController.upgradeToVideo to short-
    /// circuit a redundant addTransceiver when the renegotiation has
    /// already been driven from the other side.
    public func hasLocalVideoTrack() -> Bool {
        return localVideoTrack != nil
    }

    /// W536 decline-rollback — remove the local video track added by a
    /// mid-call upgrade attempt. Without this, a declined upgrade left the
    /// track attached forever: hasLocalVideoTrack() stayed true, so every
    /// LATER upgrade attempt threw `.alreadyHasVideo` (misdiagnosed by
    /// AppState as "peer raced us") and upgrades were dead for the rest of
    /// the call. Mirrors Android CallController's
    /// `pc.removeLocalVideoTrack()` on the decline path. Safe no-op when
    /// no video track exists.
    public func removeLocalVideoTrack() {
        guard let pc = peerConnection else { return }
        if let sender = videoSender {
            pc.removeTrack(sender)
        }
        videoSender = nil
        localVideoTrack = nil
        print("[WebRTC] local VIDEO track removed (upgrade rollback)")
    }

    /// W536 decline-rollback — JSEP rollback of a pending local offer so
    /// the PC returns to `stable`. After a declined/timed-out upgrade the
    /// PC was parked in `have-local-offer`; the peer's NEXT upgrade offer
    /// then failed `setRemoteOffer` with "Called in wrong state:
    /// have-local-offer" (the same engine-family error Android documents in
    /// its explicit-rollback fix), which auto-sent accepted=false — one
    /// decline killed upgrades in BOTH directions. No-op unless
    /// signalingState == haveLocalOffer.
    public func rollbackLocalOffer(completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection, pc.signalingState == .haveLocalOffer else {
            completion(nil)
            return
        }
        let rollback = RTCSessionDescription(type: .rollback, sdp: "")
        pc.setLocalDescription(rollback) { err in
            if let err = err {
                print("[WebRTC] rollbackLocalOffer failed: \(err.localizedDescription)")
            } else {
                print("[WebRTC] local offer rolled back — signaling state stable")
            }
            completion(err)
        }
    }

    // MARK: - Offer / Answer

    public func createOffer(audioOnly: Bool = true,
                            completion: @escaping (Result<String, Error>) -> Void) {
        guard let pc = peerConnection else {
            completion(.failure(WebRTCError.notInitialized))
            return
        }
        // GAP-3 fix (2026-07-07): snapshot the COMMITTED local description
        // BEFORE setLocalDescription below overwrites it with the new
        // (pending) re-offer — see establishedLocalSdpBeforeUpgrade doc.
        establishedLocalSdpBeforeUpgrade = pc.localDescription?.sdp

        // BUG2 fix (2026-07-11) — pre-allocate a trackless sendrecv video
        // transceiver on the AUDIO-ONLY outgoing offer, mirroring Desktop's
        // PeerConnectionManager.ts start() (`pc.addTransceiver('video',
        // {direction:'sendrecv'})`, gated `role === 'initiator'`). Landing
        // video as a REAL m-section in the INITIAL offer — even with no
        // local camera track yet — means a later video upgrade just flips
        // that already-negotiated mid to active instead of adding a brand
        // new m-line to an already-connected DTLS/BUNDLE transport.
        //
        // Root cause (device-confirmed 2026-07-11, side-by-side comparison
        // of the SAME iOS<->Desktop pair calling each other in each
        // direction): when Desktop calls iOS, Desktop pre-allocates video
        // this same way → the upgrade reuses mid=0 → H265 decodes flawlessly
        // (framesReceived≈framesDecoded climbing cleanly, zero decrypt
        // failures, cutscan never even needed). When iOS calls Desktop, iOS
        // had NO video m-section in the initial offer (OfferToReceiveVideo
        // forced false for audioOnly) → the upgrade must ADD a NEW m-line
        // (mid=2) to the live BUNDLE → ~14%+ of ALL subsequent H265 frames
        // fail FrameCryptor.open() with garbage trailer bytes for the
        // ENTIRE call (VIDEODIAG never recovers). Exactly Desktop's OWN
        // documented RFC 3264 finding (see PeerConnectionManager.ts:985-1001,
        // "INITIATOR ONLY... Skipping the pre-allocation for responders
        // costs nothing") — this is the initiator (caller) side, so it is
        // safe to always do (this function is only ever called to PLACE a
        // call, never to answer one — see createAnswer for the responder
        // path, which is deliberately left untouched here, same as
        // Desktop's own responder skip).
        //
        // ONLY skip if a video transceiver already exists (idempotent — a
        // caller-side retry/re-offer must not add a second one).
        if audioOnly && !pc.transceivers.contains(where: { $0.mediaType == .video }) {
            let videoInit = RTCRtpTransceiverInit()
            videoInit.direction = .sendRecv
            _ = pc.addTransceiver(of: .video, init: videoInit)
            print("[WebRTC] pre-allocated sendrecv video transceiver on audio-only offer (BUG2 fix)")
        }

        let mandatory: [String: String] = [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": "true"
        ]
        let constraints = RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, err in
            if let err = err {
                completion(.failure(err)); return
            }
            guard let sdp = sdp else {
                completion(.failure(WebRTCError.sdpFailed("offer returned nil"))); return
            }
            logH265FmtpLines(sdp.sdp, tag: "LOCAL_OFFER")
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
        // GAP-3 fix (2026-07-07 cross-platform matrix audit): snapshot the
        // COMMITTED local description BEFORE this createAnswer call overwrites
        // it, so preserveDtlsRoleInUpgradeAnswer can pin the answer we're about
        // to build to the a=setup role already established on this BUNDLE
        // (RFC 8842 §5.5 — must not change across renegotiation). iOS had ZERO
        // DTLS-role protection on this createAnswer path (the mid-call upgrade
        // RESPONDER side, e.g. acceptUpgradeOffer) until now — matching the
        // open "iOS<->Desktop video invisible" bug. Mirrors Desktop's
        // acceptUpgradeOffer pin and Android's applyRemoteOfferAndCreateAnswer
        // responder-side pin (added 2026-07-06). nil on the very first
        // negotiation of the call (no established role yet) — the pin is then
        // a no-op.
        let establishedLocalSdp = pc.localDescription?.sdp
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
            let pinnedSdpText = pinOwnAnswerToEstablishedDtlsRole(answerSdp: sdp.sdp, establishedLocalSdp: establishedLocalSdp)
            let pinnedSdp = pinnedSdpText == sdp.sdp ? sdp : RTCSessionDescription(type: sdp.type, sdp: pinnedSdpText)
            logH265FmtpLines(pinnedSdp.sdp, tag: "LOCAL_ANSWER")
            self?.peerConnection?.setLocalDescription(pinnedSdp, completionHandler: { setErr in
                if let setErr = setErr {
                    completion(.failure(setErr))
                } else {
                    completion(.success(pinnedSdp.sdp))
                }
            })
        }
    }

    public func setRemoteOffer(sdp: String, completion: @escaping (Error?) -> Void) {
        applyRemoteSdp(type: .offer, sdp: sdp, completion: completion)
    }

    public func setRemoteAnswer(sdp: String, completion: @escaping (Error?) -> Void) {
        // GAP-3 fix (2026-07-07): pin the peer's answer a=setup to the
        // complement of the role WE already committed before this
        // renegotiation (establishedLocalSdpBeforeUpgrade, snapshotted at
        // the start of createOffer) — RFC 8842 §5.5, must not change across
        // renegotiation. No-op on the very first negotiation of the call.
        let pinnedSdp = preserveDtlsRoleInUpgradeAnswer(answerSdp: sdp, establishedLocalSdp: establishedLocalSdpBeforeUpgrade)
        applyRemoteSdp(type: .answer, sdp: pinnedSdp, completion: completion)
    }

    private func applyRemoteSdp(type: RTCSdpType, sdp: String, completion: @escaping (Error?) -> Void) {
        guard let pc = peerConnection else { completion(WebRTCError.notInitialized); return }
        logH265FmtpLines(sdp, tag: type == .offer ? "REMOTE_OFFER" : "REMOTE_ANSWER")
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
        // Dispose the FrameCryptor BEFORE closing the PC — it holds a native
        // ref into the sender/receiver (Android dispose order
        // PeerConnectionHolder.kt:993-997).
        nativeVideoCryptor?.dispose()
        nativeVideoCryptor = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        localVideoTrack = nil
        videoSender = nil
        establishedVideoReceiverMid = nil
        establishedVideoReceiverKey = nil
        establishedVideoReceiverTransceiver = nil
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
    /// Aggregate ICE+DTLS state (distinct from the ICE-only callback above).
    /// DTLS can fail independently of ICE reporting "connected" — without this
    /// observer that failure was silently unobserved on iOS (same asymmetric
    /// gap already found + fixed on Android this session, onConnectionChange).
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        delegate?.peerConnection(self, didChangeConnectionState: newState)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        delegate?.peerConnection(self,
                                 didDiscoverLocalIceCandidate: candidate.sdp,
                                 sdpMid: candidate.sdpMid,
                                 sdpMLineIndex: candidate.sdpMLineIndex)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // W-DCAUDIO — CALLEE side: the caller created the sealed-audio DataChannel;
        // capture it and start receiving sealed frames. The label must match the
        // cross-platform constant "qaudion-audio".
        guard dataChannel.label == audioDataChannelLabel else {
            let lbl = dataChannel.label
            print("[WebRTC] didOpen: ignoring DataChannel with unknown label=\(lbl)")
            return
        }
        dataChannel.delegate = self
        audioDataChannel = dataChannel
        let st = dataChannel.readyState.rawValue
        print("[WebRTC] sealed-audio DataChannel received (state=\(st))")
    }

    // Unified-plan track callback.
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let audio = rtpReceiver.track as? RTCAudioTrack {
            // W574d HARDENING (audit wf_b1d38abe): disable the inbound SRTP
            // audio track HERE — at the earliest point the receiver track
            // exists, on the WebRTC signalling thread, BEFORE it is handed to
            // any delegate. Voice rides ONLY the sealed WS relay; plain
            // DTLS-SRTP audio must NEVER play out. The controller delegate
            // (didReceiveRemoteAudioTrack) also sets isEnabled=false, but that
            // is one stack frame later — a SRTP packet could decode and reach
            // the output unit in that gap. Disabling structurally at receiver
            // discovery closes that race window. The delegate disable stays as
            // defense-in-depth.
            audio.isEnabled = false
            delegate?.peerConnection(self, didReceiveRemoteAudioTrack: audio)
        }
        if let video = rtpReceiver.track as? RTCVideoTrack {
            // CALLEE-UPGRADE-PURPLE FIX (2026-07-01) — mirror of Android 39ea0e5f
            // (`shouldIgnorePhantomVideoTransceiver`): on a callee-initiated video
            // upgrade the peer's libwebrtc (M144) can mint a DUPLICATE phantom
            // video m-line at a NEW mid (~2s after the upgrade reneg) — recv-only,
            // receiver track present, NO sender track. Forwarding it would let the
            // app's latest-wins remote-track plumbing move the renderer sink to
            // the phantom's EMPTY track while real RTP keeps decoding on the
            // established mid → remote video frozen. (The receiver cryptor is
            // already phantom-safe: NativeVideoFrameCryptor.attachReceiver is
            // bind-once — only the render sink was stealable.)
            //
            // Resolve the owning transceiver by receiverId — the ObjC wrapper
            // objects are NOT identity-stable, so `===` matching would be wrong.
            let tx = peerConnection.transceivers.first { $0.receiver.receiverId == rtpReceiver.receiverId }
            // `mid` is annotated nonnull but is empty/nil pre-association; Swift
            // bridges a nil NSString to "" — treat empty as "no mid" either way.
            let rawMid = tx?.mid ?? ""
            let isRecvOnly = tx?.direction == .recvOnly
            let hasSenderTrack = tx?.sender.track != nil

            // RELATCH FIX (2026-07-05, device-repro'd + fingerprint-confirmed:
            // encrypt/decrypt keys matched, cryptor attach reported success, yet
            // inbound video was permanently undecrypted). The OLD binary
            // phantom-guard here only had two outcomes: ignore, or silently fall
            // through as if this were the already-established track. On a
            // legitimate mid change (an offerer-shaped renegotiation replaces the
            // transceiver — the shape combo iOS-caller + iOS-upgrade-initiator
            // takes, per WIRE_SPEC §8.6) the fall-through path never updated
            // establishedVideoReceiverMid (gated on `== nil`) NOR re-bound the
            // receiver cryptor (NativeVideoFrameCryptor.attachReceiver is
            // write-once — it stayed silently bound to the now-dead receiver and
            // just returned true). Frames kept flowing on the NEW receiver,
            // undecrypted, forever — permanent black with a healthy key and a
            // healthy peer. UpgradeFlowDecisions.resolveSinkBinding is the
            // KAT-tested pure decision this call site was always supposed to use
            // (see its doc + UpgradeFlowKatTests.swift) but was never wired in.
            //
            // establishedTransceiverStopped is conservatively passed as false —
            // resolveSinkBinding's own fallback already relatches any different-
            // receiver track that is NOT the recv-only/no-sender phantom shape
            // (which is exactly what a real bidirectional video m-line is), so
            // the fix does not depend on knowing the exact stopped-state API.
            //
            // MID-UNAVAILABLE-AT-FIRE-TIME FIX (2026-07-05): use receiverId, not
            // mid, as the identity resolveSinkBinding switches on — see the
            // establishedVideoReceiverKey field doc for why. rawMid stays in the
            // logging below (best-effort) but no longer gates the decision.
            let receiverKey = rtpReceiver.receiverId
            let binding = UpgradeFlowDecisions.resolveSinkBinding(
                establishedMid: establishedVideoReceiverKey,
                incomingMid: receiverKey,
                transceiverIsRecvOnly: isRecvOnly,
                establishedTransceiverStopped: false
            )
            // REDACTION-GATE FIX (2026-07-05): ship-ios-logs.py's structured
            // gate requires free-word-count <= structural(key=value)-token
            // count per line (scripts/ship-ios-logs.py:_passes_structured_gate).
            // "video phantom ign=1" / "video mid est=1" / "video relatch
            // cryptor=1" each carry 2 bare free words ("video"+"phantom",
            // "video"+"mid", "video"+"relatch") against only 1 structural
            // token — they FAIL the gate and get silently replaced/dropped,
            // which is exactly why none of them were ever visible in Loki
            // across every device repro today, even though (confirmed by
            // deduction: "ev=vrxatt" below DOES ship, and it is only
            // reachable past this switch, so bindInitial/relatch above it
            // must have run) the decision logic itself was firing correctly
            // the whole time. All-kv, zero-bare-free-word lines below so
            // free==0 and the gate auto-passes regardless of vocab quirks.
            switch binding {
            case .keepPhantomIgnored(let key):
                print("[WebRTC] PHANTOM video transceiver IGNORED mid=\(rawMid) recvOnly=\(isRecvOnly) hasSender=\(hasSenderTrack) (established receiver=\(key ?? "nil") still live) — keeping renderer on established track")
                print("ev=vphantom")
                return
            case .bindInitial(let key):
                establishedVideoReceiverKey = key
                if !rawMid.isEmpty { establishedVideoReceiverMid = rawMid }
                establishedVideoReceiverTransceiver = tx
                print("[WebRTC] inbound VIDEO receiver established mid=\(rawMid) receiver=\(key)")
                print("ev=vbind")
            case .relatch(let key):
                let prevKey = establishedVideoReceiverKey ?? "nil"
                establishedVideoReceiverKey = key
                if !rawMid.isEmpty { establishedVideoReceiverMid = rawMid }
                establishedVideoReceiverTransceiver = tx
                print("[WebRTC] inbound VIDEO RE-LATCHED receiver \(prevKey) -> \(key) mid=\(rawMid) recvOnly=\(isRecvOnly) hasSender=\(hasSenderTrack)")
                print("ev=vrelatch")
                // Rebind the receiver cryptor to the NEW live receiver now, before
                // forwarding to the delegate below — the write-once attachReceiver
                // would otherwise no-op and leave it bound to the dead receiver.
                if let cryptor = nativeVideoCryptor {
                    let rebound = cryptor.rebindReceiver(rtpReceiver)
                    print("ev=vrelatch cryptor=\(rebound ? 1 : 0)")
                }
            }
            delegate?.peerConnection(self, didReceiveRemoteVideoTrack: video)
            // Attach point for the native FrameCryptor (decrypts inbound video).
            // This runs on the WebRTC signalling thread — the correct place to
            // create RTCFrameCryptor (mirrors Android enableVideoFrameCryptorOnReceiver).
            // No-op for the relatch case above (already rebound synchronously).
            delegate?.peerConnection(self, didReceiveRemoteVideoReceiver: rtpReceiver)
        }
    }
}

// Default no-op so Delegate conformers that don't handle video need not
// implement the receiver-cryptor hook.
public extension QAudionPeerConnection.Delegate {
    func peerConnection(_ pc: QAudionPeerConnection,
                        didReceiveRemoteVideoReceiver receiver: RTCRtpReceiver) {}

    func peerConnection(_ pc: QAudionPeerConnection,
                        didChangeConnectionState state: RTCPeerConnectionState) {}
}

// MARK: - RTCDataChannelDelegate (W-DCAUDIO sealed-audio channel)
extension QAudionPeerConnection: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel === audioDataChannel else { return }
        let st = dataChannel.readyState.rawValue
        print("[WebRTC] sealed-audio DataChannel state → \(st)")
    }
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel === audioDataChannel else { return }
        let cb = onAudioDataChannelFrame
        cb?(buffer.data)
    }
}
#endif

/// CALLEE-UPGRADE-PURPLE FIX (2026-07-01) — pure decision for whether a
/// just-added inbound video receiver belongs to a PHANTOM transceiver that must
/// be IGNORED (do not forward didReceiveRemoteVideoTrack /
/// didReceiveRemoteVideoReceiver; keep the renderer on the established mid).
/// Mirrors Android `shouldIgnorePhantomVideoTransceiver`
/// (qaudion-android-new commit 39ea0e5f, PeerConnectionHolder.kt).
///
/// Phantom shape (device-verified on Android A36↔S26, same libwebrtc M144 on
/// iOS): once a real inbound video mid is ESTABLISHED, a transceiver at a
/// DIFFERENT mid that is recv-only with NO sender track is the empty duplicate
/// m-line libwebrtc mints on a callee-side video upgrade. Real RTP keeps
/// flowing on the established mid; following the phantom steals the render
/// sink → remote video frozen.
///
/// Safety semantics (the guard must be unable to break legitimate video):
///  - first-ever video (`establishedMid == nil`) → NEVER ignored (it is the
///    one that establishes the mid)
///  - same-mid re-fire → forwarded normally
///  - sender track present, or direction not recv-only → forwarded normally
///    (a real bidirectional m-line, not the empty phantom)
///  - unresolvable transceiver / empty mid (`liveMid == nil`) → forwarded
///    normally (fail open to old behavior — never drop a track we can't
///    classify)
///
/// Kept OUTSIDE `#if canImport(WebRTC)` and free of RTC types so it is
/// unit-testable on the macOS CI runner (`swift test`) without the WebRTC
/// binary — same extraction pattern as the Android pure function.
enum VideoTransceiverPhantomGuard {
    static func shouldIgnorePhantomVideoTransceiver(
        establishedMid: String?,
        liveMid: String?,
        isRecvOnly: Bool,
        hasSenderTrack: Bool
    ) -> Bool {
        guard let establishedMid = establishedMid, !establishedMid.isEmpty else { return false }
        guard let liveMid = liveMid, !liveMid.isEmpty else { return false }
        if liveMid == establishedMid { return false }
        return isRecvOnly && !hasSenderTrack
    }
}

/// RFC 8842 §5.5 — preserve the DTLS role across an audio→video upgrade
/// renegotiation by pinning the answer SDP's `a=setup` lines to the
/// COMPLEMENT of the role already committed in the established BUNDLE
/// association. On an existing BUNDLE transport the DTLS roles MUST NOT
/// change; an answer that disagrees gets rejected outright, or — if the
/// peer works around it — leaves that side's own local transport
/// internally split from what it actually sent (dtlsState flips to
/// "failed" shortly after signaling reaches stable).
///
/// GAP-3 fix (2026-07-07 cross-platform matrix audit): mirrors
/// `preserveDtlsRoleInUpgradeAnswer` already shipped on Desktop
/// (`PeerConnectionManager.ts`) and Android (`PeerConnectionHolder.kt`,
/// responder-side pin added 2026-07-06) — iOS had ZERO DTLS-role
/// protection on either the initiator-apply-answer
/// (`applyUpgradeAnswer`) or responder-create-answer (`createAnswer`)
/// upgrade paths until now, matching the open "iOS<->Desktop video
/// invisible" bug.
///
/// `establishedLocalSdp` is the PC's committed local description at
/// apply/create time (nil ⇒ no established role yet, e.g. the very first
/// negotiation of the call ⇒ this is a no-op). Kept OUTSIDE the WebRTC
/// class and free of RTC types — pure string transform, unit-testable on
/// the macOS CI runner without the WebRTC binary, same as
/// `VideoTransceiverPhantomGuard` above.
func preserveDtlsRoleInUpgradeAnswer(answerSdp: String, establishedLocalSdp: String?) -> String {
    guard let establishedLocalSdp = establishedLocalSdp,
          let roleRegex = try? NSRegularExpression(
            pattern: "^a=setup:(active|passive)\\b",
            options: [.anchorsMatchLines])
    else {
        return answerSdp
    }
    let establishedNS = establishedLocalSdp as NSString
    guard let match = roleRegex.firstMatch(
        in: establishedLocalSdp,
        range: NSRange(location: 0, length: establishedNS.length))
    else {
        return answerSdp
    }
    let establishedRole = establishedNS.substring(with: match.range(at: 1))
    let answererRole = establishedRole == "active" ? "passive" : "active"
    guard let replaceRegex = try? NSRegularExpression(
        pattern: "^a=setup:(active|passive|actpass)\\b",
        options: [.anchorsMatchLines])
    else {
        return answerSdp
    }
    let answerNS = answerSdp as NSString
    return replaceRegex.stringByReplacingMatches(
        in: answerSdp,
        options: [],
        range: NSRange(location: 0, length: answerNS.length),
        withTemplate: "a=setup:\(answererRole)")
}

/// RFC 8842 §5.5 — pin OUR OWN new answer to the SAME DTLS role we already
/// committed on this BUNDLE, when WE are the one CREATING the answer (the
/// upgrade-request RESPONDER path, `createAnswer`). This is the opposite
/// direction from `preserveDtlsRoleInUpgradeAnswer` above: that function
/// patches the PEER's incoming answer to our complement (correct only when
/// WE are the initiator applying THEIR answer, `setRemoteAnswer`). Here
/// `establishedLocalSdp` already IS our own prior committed role — copying
/// it verbatim keeps the DTLS association fixed. Bug found 2026-07-07 (live
/// Desktop<->Android test, same defect ported here before it could ship):
/// applying the COMPLEMENT to our own answer flips OUR OWN role against
/// what our local DTLS engine actually does — manifests as dtlsState stuck
/// at "connecting" forever (a genuine role clash, silent — the SDP text
/// alone looks self-consistent locally, it just never completes the
/// handshake), not an outright reject like a peer-role clash would be.
/// Absent a committed role (first negotiation) ⇒ leave as-is.
func pinOwnAnswerToEstablishedDtlsRole(answerSdp: String, establishedLocalSdp: String?) -> String {
    guard let establishedLocalSdp = establishedLocalSdp,
          let roleRegex = try? NSRegularExpression(
            pattern: "^a=setup:(active|passive)\\b",
            options: [.anchorsMatchLines])
    else {
        return answerSdp
    }
    let establishedNS = establishedLocalSdp as NSString
    guard let match = roleRegex.firstMatch(
        in: establishedLocalSdp,
        range: NSRange(location: 0, length: establishedNS.length))
    else {
        return answerSdp
    }
    let ownRole = establishedNS.substring(with: match.range(at: 1))
    guard let replaceRegex = try? NSRegularExpression(
        pattern: "^a=setup:(active|passive|actpass)\\b",
        options: [.anchorsMatchLines])
    else {
        return answerSdp
    }
    let answerNS = answerSdp as NSString
    return replaceRegex.stringByReplacingMatches(
        in: answerSdp,
        options: [],
        range: NSRange(location: 0, length: answerNS.length),
        withTemplate: "a=setup:\(ownRole)")
}

/// BUG3 DIAG (2026-07-11) — log the actual H265 `a=fmtp` line(s) an SDP
/// blob carries, at every point one becomes available on this side (our own
/// offer/answer just created, or the peer's offer/answer we're about to
/// apply). Companion to Desktop's `[pcm][bug3-diag]`/`[pcm][bug3-fix]` logs:
/// Desktop discovered the iOS-caller video-upgrade offer negotiates H265
/// with `profile-id`/`tier-flag` MISSING entirely (e.g. `level-id=93;
/// tx-mode=SRST` vs. the normal `level-id=123;profile-id=1;tier-flag=0;
/// tx-mode=SRST`) — this makes that fact visible from iOS's OWN side of the
/// wire (today `createOffer`/`applyRemoteSdp` discard the SDP string with
/// zero inspection), rather than only inferred after the fact from the
/// peer's console. Read-only — never mutates the SDP (Desktop's receive-side
/// `normalizeH265FmtpDefaults` already compensates for the gap; this is
/// diagnostic only, matching the "print, don't kill" project policy).
func logH265FmtpLines(_ sdp: String, tag: String) {
    guard let rtpmapRegex = try? NSRegularExpression(
        pattern: "^a=rtpmap:(\\d+)\\s+H265/90000",
        options: [.anchorsMatchLines, .caseInsensitive])
    else { return }
    let sdpNS = sdp as NSString
    let rtpmapMatches = rtpmapRegex.matches(in: sdp, range: NSRange(location: 0, length: sdpNS.length))
    guard !rtpmapMatches.isEmpty else { return }
    let h265Pts = Set(rtpmapMatches.map { sdpNS.substring(with: $0.range(at: 1)) })
    guard let fmtpRegex = try? NSRegularExpression(
        pattern: "^a=fmtp:(\\d+)\\s+([^\\r\\n]+)",
        options: [.anchorsMatchLines])
    else { return }
    let fmtpMatches = fmtpRegex.matches(in: sdp, range: NSRange(location: 0, length: sdpNS.length))
    for m in fmtpMatches {
        let pt = sdpNS.substring(with: m.range(at: 1))
        guard h265Pts.contains(pt) else { continue }
        let params = sdpNS.substring(with: m.range(at: 2))
        print("[WebRTC][bug3-diag] \(tag): H265 pt=\(pt) fmtp=\(params)")
    }
}

/// W-DCBACKPRESSURE (2026-07-21) — pure decision for whether an outbound
/// sealed-audio DataChannel frame should be dropped instead of enqueued.
/// Mirrors Android's `PeerConnectionHolder` Wave 2C-15 hotfix
/// (2026-04-29): when the outbound SCTP queue backs up past
/// `threshold` bytes, prefer frame loss over unbounded buffered delay — the
/// receiver's PLC/FEC/comfort-noise masks the occasional drop; letting the
/// queue grow instead produces a permanent, non-recovering playout lag (or
/// worse, an unhealthy SCTP association). iOS shipped with NO such guard at
/// all on this wire mechanism until this fix (root-caused via call
/// `f884668c`, 2026-07-21: iOS's own telemetry went dark ~11s into a 1:1
/// call, well before Android's ICE state noticed anything wrong, consistent
/// with the DC itself becoming unhealthy under sustained backpressure with
/// nothing shedding load on iOS's send side).
///
/// Namespaced (no WebRTC/RTCDataChannel type needed) so it has its own
/// regression test (`AudioDcBackpressureGateTests`), same shape as
/// `VideoTransceiverPhantomGuard` above.
enum AudioDcBackpressureGate {
    static func shouldDrop(bufferedAmount: UInt64, threshold: UInt64) -> Bool {
        bufferedAmount > threshold
    }
}
