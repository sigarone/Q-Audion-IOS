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
        /// IOS-C4b (2026-08-26) — remote AUDIO RTP receiver, fired ONLY when
        /// both peers negotiated `CallCapabilities.audioSrtpV1` (the earlier
        /// `didReceiveRemoteAudioTrack` call still fires too, alongside this
        /// one — this is the attach point for the native `RTCFrameCryptor` +
        /// PCM-tap-parity renderer, mirroring `didReceiveRemoteVideoReceiver`
        /// for video). Default no-op below so non-audio-srtp conformers need
        /// not implement it.
        func peerConnection(_ pc: QAudionPeerConnection,
                            didReceiveNativeAudioSrtpReceiver receiver: RTCRtpReceiver)
        /// Remote video track (only fired when video is negotiated).
        func peerConnection(_ pc: QAudionPeerConnection,
                            didReceiveRemoteVideoTrack track: RTCVideoTrack)
        /// Remote video RTP receiver — the attach point for the native
        /// `RTCFrameCryptor` (decrypts inbound video). Fires on the WebRTC
        /// signalling thread alongside `didReceiveRemoteVideoTrack`. Default
        /// no-op so non-video conformers need not implement it.
        func peerConnection(_ pc: QAudionPeerConnection,
                            didReceiveRemoteVideoReceiver receiver: RTCRtpReceiver)

        /// W-TURNSUSPECT (playbook §IOS-E4, 2026-08-25) — ICE gathering for
        /// this cycle just reached `.complete`; `relayCandidateCount` is how
        /// many local RELAY-type candidates it produced (parsed off each
        /// `didGenerate candidate`'s SDP, " typ relay "). Zero on a call
        /// whose `RelayCredentialsProvider` handed out TURN servers is the
        /// "these credentials look wrong" symptom the existing post-auth-
        /// failure `forceRefresh` never catches by itself — a TURN
        /// allocation can fail silently (expired secret, revoked realm)
        /// without ever tripping a 401/403 on the TURN control channel.
        /// Fires once per gathering cycle (covers an ICE-restart re-gather
        /// too, once that machinery exists). Default no-op below.
        func peerConnection(_ pc: QAudionPeerConnection,
                            didCompleteIceGatheringWithRelayCandidates count: Int)

        /// W-ROUTETIEREVENT (2026-08-26, P2 audit item 4) — libwebrtc's ICE
        /// agent just selected a new candidate pair. Sourced from the
        /// `RTCPeerConnectionDelegate` OPTIONAL method
        /// `didChangeLocalCandidate:remoteCandidate:lastReceivedMs:
        /// changeReason:` — confirmed present on the pinned webrtc-sdk/webrtc
        /// `m144_release` tag this app's vendored `WebRTC.xcframework` is
        /// built from (fetched and grepped the real header before wiring
        /// this; see `QAudionWebRtcCallController
        /// .resolveAndApplyRouteTier`'s own prior "VERIFICATION GAP" note,
        /// now closed with real evidence instead of a guess).
        ///
        /// Deliberately carries only the WebRTC-reported change reason, not
        /// the candidate objects themselves: every conformer that cares
        /// (route-tier classification, W-ROUTECLAMP) already re-derives the
        /// committed pair from a fresh `RTCStatisticsReport` — the SAME
        /// `pc.statistics` call the existing 3s poll uses — so this is
        /// purely a trigger to run that resolution on-demand instead of
        /// waiting up to 3s for the next timer tick. Default no-op below so
        /// conformers that only need the belt-and-braces poll (unchanged,
        /// still running) need not implement it.
        func peerConnection(_ pc: QAudionPeerConnection,
                            didChangeSelectedCandidatePairChangeReason reason: String)
    }

    public weak var delegate: Delegate?

    /// Underlying RTCPeerConnection. Avoid touching directly — use the
    /// high-level methods on this class instead.
    public private(set) var peerConnection: RTCPeerConnection?

    /// W-TURNSUSPECT (IOS-E4) — relay-type local candidates gathered during
    /// THIS ICE gathering cycle. Reset when a fresh cycle starts
    /// (`didChange newState: .gathering`), read once it reaches `.complete`.
    /// Touched only from the `RTCPeerConnectionDelegate` callbacks below,
    /// which WebRTC serialises on its own signalling thread — no additional
    /// lock needed, same assumption the rest of this delegate extension
    /// already relies on.
    private var relayCandidateCount: Int = 0

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

    // ── IOS-C4b (2026-08-26): native SRTP audio (CallCapabilities.audioSrtpV1) ──
    //
    // Mirrors the video FrameCryptor block above, and Android's
    // `PeerConnectionHolder.kt` "AUDIO_SRTP_V1 — native RTP audio FrameCryptor
    // wiring" section, but deliberately simpler: unlike video, audio has no
    // toggle-on/off-mid-call scenario and no fail-closed branch — when the
    // capability isn't negotiated, audio simply stays on the existing
    // sealed-DataChannel/WS-relay path, unchanged.

    /// Pre-created at `init` (both caller AND callee, unlike video which is
    /// asymmetric — mirrors Android's `open()` placement) ONLY when
    /// `CallCapabilities.audioSrtpSendEnabled` is `true`, so the FIRST SDP
    /// this build produces or receives already carries an m=audio SEND_RECV
    /// section with no track attached. `nil` on every build with the kill
    /// switch off — `init` never calls `addTransceiver` for audio in that
    /// case, so the SDP is byte-for-byte what it was before this feature.
    private var audioTransceiver: RTCRtpTransceiver?
    /// The real mic-sourced RTP sender, once ``activateNativeAudioSrtp(key:participantId:rxSink:txSink:)``
    /// has attached a track. `nil` until then (and always `nil` on a call
    /// that never negotiates ``CallCapabilities/audioSrtpV1``).
    public private(set) var nativeAudioSender: RTCRtpSender?
    private var localAudioSrtpTrack: RTCAudioTrack?
    /// Native libwebrtc FrameCryptor for the 1:1 AUDIO sender+receiver.
    /// Sibling of ``nativeVideoCryptor`` — see ``NativeAudioFrameCryptor``.
    public private(set) var nativeAudioCryptor: NativeAudioFrameCryptor?
    /// PCM-TAP PARITY (IOS-C4b) — renderer taps feeding the same
    /// Guardian/VoiceAnalysis/ContactVoiceVerifier/VoiceLearningSession/
    /// OwnerContinuity consumers the sealed-DataChannel decode path already
    /// feeds. See ``NativeAudioPcmTap``'s own doc for why this exists.
    private var audioRxTap: NativeAudioPcmTap?
    /// W-AUDIORXTAPCARRYOVER (2026-08-29) — the track ``audioRxTap`` is
    /// currently attached to. Needed because a renderer is registered ON A
    /// TRACK, so moving the tap after a post-negotiation receiver rebind
    /// requires detaching it from the exact track it was added to; there is
    /// no "which track am I on" query on the renderer itself.
    private var audioRxTapTrack: RTCAudioTrack?
    private var audioTxTap: NativeAudioPcmTap?
    /// Mute state requested BEFORE the real mic track exists (mirrors
    /// Android's `pendingAudioSrtpMuted`) — latched here and applied the
    /// moment `activateNativeAudioSrtp` creates the track.
    private var pendingAudioSrtpMuted: Bool = false
    /// True once the receiver-side branch of `didAdd rtpReceiver` has kept
    /// the inbound SRTP audio track enabled (peer negotiated the tag) —
    /// read by ``setMicrophoneMuted(_:)`` and the fallback machinery.
    public private(set) var usingNativeAudioSrtp: Bool = false
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
    ///
    /// W-DCMUX — the literal now lives in ``SealedAudioDataChannelWire`` (bottom
    /// of this file, outside the `canImport(WebRTC)` block) so a regression test
    /// can pin it without the WebRTC binary. Both ends compare the label with
    /// plain string equality (`PeerConnectionHolder.kt:3865` on Android,
    /// `didOpen` below on iOS), so a rename is an interop break that no test
    /// would otherwise catch until a real cross-platform call went silent.
    private let audioDataChannelLabel = SealedAudioDataChannelWire.label
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

    /// W-DCMUX (2026-08-11) — sealed-audio DataChannel lifecycle, as the raw
    /// `RTCDataChannelState` value (0 connecting, 1 open, 2 closing, 3 closed).
    ///
    /// Invoked on the WebRTC signalling thread at three moments: when the CALLER
    /// creates the channel, when the CALLEE receives it via `didOpen`, and on
    /// every subsequent `dataChannelDidChangeState`. The engine has no call id,
    /// so the app layer owns the log line — this hook is what lets it carry one.
    ///
    /// Existence-only: it changes no wire byte and no transport decision. It
    /// exists because the live Loki pull of call `0289b8d4` returned 14 iOS
    /// lines for a 69-second call and NOT ONE of them was about the DataChannel,
    /// which makes "the channel never opened" and "the channel opened and we
    /// never wrote to it" indistinguishable from logs — the exact question
    /// Phase 0 has to answer before the capability tag may be flipped.
    public var onAudioDataChannelStateChange: ((Int) -> Void)?

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

        // IOS-C4b (2026-08-26) — pre-create the audio transceiver the SAME
        // way as video's BUG2 pre-allocation, for the SAME reason: the
        // peer's capability advertisement isn't known until the call-setup
        // envelope round-trips, but the m-line has to be in the FIRST SDP
        // offer/answer or it's a renegotiation. No track is attached here
        // (direction sendRecv, no track) — `activateNativeAudioSrtp` attaches
        // the real mic track later, only if this call actually negotiates
        // `CallCapabilities.audioSrtpV1`. Unlike the video pre-allocation
        // (caller-only, done inside `createOffer`), this runs for BOTH roles
        // right here at construction — mirrors Android's `open()` placement
        // (`PeerConnectionHolder.kt`: "AUDIO_SRTP_V1 — pre-create the audio
        // transceiver the SAME way as video... on BOTH sides"). Gated on the
        // compile-time kill switch: off (the default), this block never
        // runs and every call's SDP is byte-for-byte what it was before —
        // no m=audio SEND_RECV line, no behavior change.
        if CallCapabilities.audioSrtpSendEnabled {
            // W-ADMNOMANUAL (2026-08-31) — nothing to arm: WebRTC manages its
            // own audio unit. See NativeAudioSessionGate for what was tried
            // and what each attempt measured.
            // W-PREATTACHMIC (2026-08-30) — pre-attach the REAL (muted) mic
            // track here, instead of pre-creating a bare transceiver via
            // `addTransceiver`. Measured failure the bare transceiver caused
            // (TestFlight 1.0.1052, call ca37be9a, `act=1 n=2 sel=1 dir=2`):
            // per JSEP §5.10 a transceiver created by addTransceiver is NOT
            // eligible for association with a REMOTE offer's m-line — it
            // reserves a slot for an offer WE make. So on the callee,
            // setRemoteDescription added a SECOND audio transceiver for the
            // peer's m-line with local direction recvOnly, the answer went
            // out announcing no outbound audio, and no addTrack promotion
            // AFTER that answer can fix it without a renegotiation this SDK
            // cannot drive (`direction` is READONLY here — see W-RECVONLYPIN).
            // A track added via `pc.add` IS eligible for both: the caller's
            // offer carries it sendRecv, and on the callee JSEP recycles this
            // transceiver for the remote m-line and the answer negotiates
            // sendRecv. This mirrors Android's shipping shape exactly
            // (`PeerConnectionHolder`: "open: mic track pre-attached (muted,
            // codec binds on this SDP round)"). The track stays disabled
            // until `activateNativeAudioSrtp` confirms the sender cryptor
            // (W-AUDIOSENDERGATE), so a call that never negotiates
            // audio-srtp-v1 carries a silent, cryptor-less, disabled track —
            // the same inert m-line legacy peers have tolerated since
            // IOS-C4b, now with a=sendrecv like Android's.
            let source = factory.audioSource(with: nil)
            let track = factory.audioTrack(with: source, trackId: audioTrackId)
            track.isEnabled = false
            localAudioSrtpTrack = track
            pc.add(track, streamIds: [stableStreamId])
            nativeAudioSender = pc.senders.first { $0.track?.trackId == audioTrackId }
            audioTransceiver = pc.transceivers.first { $0.mediaType == .audio }
            print("[WebRTC] W-PREATTACHMIC: pre-attached muted mic track (kill switch on) senderResolved=\(nativeAudioSender != nil)")
        }
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
        // W-DCMUX — same instant, but with a call id attached by the app layer.
        // The print above survives for a console session; only the hooked line
        // reaches the call-correlated timeline.
        onAudioDataChannelStateChange?(dc.readyState.rawValue)
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

    /// W-DCMUX (2026-08-11) — the sealed-audio DataChannel's raw
    /// `RTCDataChannelState`, or `-1` when there is no channel object at all.
    ///
    /// Read-only diagnostic. ``isAudioDataChannelOpen()`` collapses "no channel
    /// was ever created" and "a channel exists but is connecting / closing /
    /// closed" into the same `false`, and those are three different bugs with
    /// three different fixes. `sendAudioFrameData` returns `false` for all of
    /// them alike, so without this the Phase 0 log line cannot say which one
    /// happened.
    public func audioDataChannelStateRaw() -> Int {
        guard let dc = audioDataChannel else { return -1 }
        return dc.readyState.rawValue
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
    /// W-LONGAUDIO (2026-08-10) — the result now also carries the peer's RAW
    /// list (`negotiate` copies it from the `peer` argument). No wire change and
    /// no new field on any message: the list was already here and was simply
    /// being discarded after the intersection was taken.
    public func acceptPeerCapabilities(_ peer: [String]?) {
        let n = CallCapabilities.negotiate(peer: peer)
        peerCapsLock.lock(); peerCallCapabilities = n; peerCapsLock.unlock()
    }

    /// Mute / unmute the local microphone.
    ///
    /// W574d — the LEGACY (always-nil, `addLocalAudioTrack`-created) SRTP
    /// mic track is PERMANENTLY disabled. Only the muted direction is
    /// propagated for THAT track so no caller can accidentally re-enable
    /// plain-SRTP voice transmission via an unmute.
    ///
    /// IOS-C4b — the REAL native-audio-srtp track (`activateNativeAudioSrtp`)
    /// is a different mechanism entirely: propagates BOTH directions, same
    /// as Android's `PeerConnectionHolder.setAudioSrtpMuted`. Harmless no-op
    /// when that track does not exist (every call that never negotiates
    /// `CallCapabilities.audioSrtpV1`).
    public func setMicrophoneMuted(_ muted: Bool) {
        if muted { localAudioTrack?.isEnabled = false }
        setNativeAudioSrtpMuted(muted)
    }

    // MARK: - Video track (optional)

    /// Add a local video track from the supplied capturer. Caller is
    /// responsible for starting the capturer; this method just plumbs the
    /// track into the peer connection.
    ///
    /// - Parameter isScreencast: W-SCREENPROFILE (2026-08-25) — pass `true`
    ///   when the track will carry screen-share content (ReplayKit frames)
    ///   rather than camera frames. Selects `factory.videoSource(forScreenCast:)`
    ///   instead of the plain `factory.videoSource()` — verified against
    ///   webrtc-sdk `m144_release`'s `sdk/objc/api/peerconnection/
    ///   RTCPeerConnectionFactory.h` (same pinned branch this app's WebRTC
    ///   binaryTarget builds from, see `Package.swift`), which declares
    ///   `- (RTCVideoSource *)videoSourceForScreenCast:(BOOL)forScreenCast;`
    ///   alongside the plain `videoSource`. Marking the source as screencast
    ///   feeds libwebrtc's own content-type heuristics (`VideoAdapter` /
    ///   send-stream degradation-preference selection) that this
    ///   camera-oriented default was silently missing for every screen
    ///   share — see `setVideoDegradationPreference` below for the
    ///   explicit sender-level override layered on top for the case where
    ///   a video track already exists (this parameter only affects a
    ///   FRESH source; the `localVideoTrack == nil` guard above means an
    ///   in-progress camera call that then starts a screen share reuses
    ///   the already-created, non-screencast source instead).
    @discardableResult
    public func addLocalVideoTrack(capturer: RTCVideoCapturer? = nil, isScreencast: Bool = false) -> RTCVideoSource? {
        guard let pc = peerConnection, localVideoTrack == nil else { return nil }
        let source = factory.videoSource(forScreenCast: isScreencast)
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
        // W-RECVONLYPIN (2026-07-28) — the reuse below is ONLY valid while the
        // existing transceiver can still SEND. Device-confirmed regression from
        // the W-DUPETRANSCEIVER change above (call 5ec6cc1d, iOS-initiated
        // upgrade): iOS's own upgrade offer went out as
        //     m=video dir=recvonly  ssrcs=NONE
        // and Android correctly mirrored it with sendonly, so Android showed
        // purple for 110 s while iOS decoded Android's 1629 frames perfectly —
        // a one-way call that iOS itself had asked for, while its
        // `call_video_state` beacon simultaneously claimed paused=false.
        //
        // Why reuse cannot fix that: on this WebRTC build
        // `RTCRtpTransceiver.direction` is READONLY and there is no
        // `setDirection:` (verified against webrtc-sdk m144_release's
        // RTCRtpTransceiver.h — only `currentDirection:`, `stopInternal`,
        // `setCodecPreferences`). Assigning `sender.track` does NOT promote a
        // recvonly transceiver. `pc.add(track:streamIds:)` is the ONLY API here
        // that does, because libwebrtc's AddTrack applies the JSEP rule
        // "if transceiver.direction is recvonly, set it to sendrecv".
        //
        // So: reuse when the transceiver can send (keeps the mid stable, which
        // is the whole point of W-DUPETRANSCEIVER), otherwise fall back to
        // addTrack and accept a possible new mid — a renegotiated mid is
        // recoverable, a permanently recvonly m-line is not.
        let reusable = pc.transceivers.first {
            $0.mediaType == .video && ($0.direction == .sendRecv || $0.direction == .sendOnly)
        }
        if reusable == nil,
           let blocked = pc.transceivers.first(where: { $0.mediaType == .video }) {
            print("[WebRTC] W-RECVONLYPIN video transceiver mid=\(blocked.mid) is \(blocked.direction.rawValue) — cannot promote (direction is readonly on this SDK); falling back to addTrack so the offer is sendrecv")
        }
        if let existing = reusable {
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
            if isScreencast { setVideoDegradationPreference(.maintainResolution) }
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
        if isScreencast { setVideoDegradationPreference(.maintainResolution) }
        // W466 — confirm the local camera track was plumbed into the
        // peer connection.
        print("[WebRTC] local VIDEO track added to peer connection (sender=\(videoSender != nil))")
        return source
    }

    /// W-SCREENPROFILE (2026-08-25) — explicit override for WebRTC's
    /// bandwidth-adaptation degradation strategy on the local video sender.
    /// `nil` restores the SDK's implementation default (camera video:
    /// smooth motion favored over resolution). `.maintainResolution` keeps
    /// frame legibility during a screen share instead of letting the
    /// encoder shrink resolution first under pressure — the opposite of
    /// what legible shared text needs. Callable independently of
    /// `addLocalVideoTrack`'s `isScreencast` flag so a track created BEFORE
    /// screen share started (an already-live camera call that then shares
    /// its screen, where the source-level flag above can no longer apply —
    /// see that method's kdoc) still gets the override.
    ///
    /// `sender.parameters` get/mutate/set-back — same core WebRTC ObjC SDK
    /// pattern `QAudionWebRtcCallController.applyVideoSenderMaxBitrate`
    /// already uses for `encodings[0].maxBitrateBps`. Verified against
    /// webrtc-sdk `m144_release`'s `RTCRtpParameters.h`: `degradationPreference`
    /// is `NSNumber * _Nullable` boxing the `RTCDegradationPreference`
    /// NS_ENUM raw value (there is no native enum-typed property to assign
    /// directly). No-op when there is no video sender yet.
    @discardableResult
    public func setVideoDegradationPreference(_ preference: RTCDegradationPreference?) -> Bool {
        guard let sender = videoSender else { return false }
        let params = sender.parameters
        params.degradationPreference = preference.map { NSNumber(value: $0.rawValue) }
        sender.parameters = params
        print("[WebRTC] W-SCREENPROFILE: video sender degradationPreference=\(preference.map { String($0.rawValue) } ?? "default")")
        return true
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

    // MARK: - IOS-C4b — native SRTP audio activation

    /// Attach the real mic track and install the audio FrameCryptor +
    /// sender-side PCM tap on the pre-created ``audioTransceiver``, but only
    /// once BOTH a key is available AND the peer negotiated
    /// ``CallCapabilities/audioSrtpV1`` — the caller (``QAudionWebRtcCallController``)
    /// is responsible for calling this only after confirming both, mirroring
    /// Android's `maybeActivateAudioSrtp` gate (`useAudioSrtp` check lives one
    /// layer up there too, in `CallController.installLiveMediaKeys`).
    ///
    /// Idempotent: if the track already exists (e.g. a rekey re-calling this
    /// with a fresh key), this only re-applies the key. No-op (returns
    /// `false`) if ``audioTransceiver`` was never pre-created — i.e.
    /// ``CallCapabilities/audioSrtpSendEnabled`` is off for this build.
    ///
    /// - Parameters:
    ///   - key: 32-byte raw PQC session key (same key the sealed-DataChannel
    ///     path uses — no K_video-style derivation for audio, matching
    ///     Android's `installLiveMediaKeys` -> `setAudioSrtpKey`).
    ///   - participantId: passed straight to `NativeAudioFrameCryptor`.
    ///   - rxSink: PCM-TAP PARITY — called with each little-endian Int16
    ///     mono 48 kHz chunk of the REMOTE peer's decoded audio, the moment
    ///     the receiver track is enabled (wired from `didAdd rtpReceiver`,
    ///     independent of this method — see that branch). Passed through so
    ///     callers that activate TX and RX at the same call site can wire
    ///     both without a second round trip; harmless to pass a no-op here
    ///     if RX wiring already happened.
    ///   - txSink: PCM-TAP PARITY — called with each chunk of the LOCAL
    ///     mic's captured audio (Tier 1 "voce come chiave" equivalent).
    @discardableResult
    public func activateNativeAudioSrtp(
        key: Data,
        participantId: String,
        slot: Int32 = 0,
        txSink: @escaping (Data) -> Void,
        diag: ((String) -> Void)? = nil
    ) -> Bool {
        guard let pc = peerConnection else { return false }
        // W-AUDIOSENDDIAG (2026-08-30) — every decision this function takes,
        // in ONE remote-visible line (the prints below never leave the
        // device, which is how two silent-call incidents in a row could
        // both end at "the controller logged success"). Codes:
        //   n   = audio transceiver count
        //   sel = 1 picked transceiver has a non-empty mid
        //   dir = picked transceiver's direction rawValue
        //   br  = branch: 0 track already present, 1 carried, 2 promoted
        //         via addTrack, 3 created fresh
        //   en  = local track isEnabled at exit
        //   att = cryptor attachSender result
        var diagN = 0, diagSel = 0, diagDir = -1, diagBr = 0
        // W-AUDIOSRTPSENDERCARRYOVER (2026-08-28, port of the equivalent
        // Android/qaudion-android-new fix) — `audioTransceiver` is cached
        // ONCE at `init()`, before any SDP round-trip. libwebrtc M144's JSEP
        // can silently replace the pre-created transceiver object during
        // `setRemoteDescription`/`setLocalDescription` — this repo's own
        // VIDEO path already documents and handles that exact behavior (see
        // `didAdd rtpReceiver`'s `.relatch` branch above), but the AUDIO
        // sender path never re-resolved its cached reference, so a rewire
        // here would silently attach the mic track to a dead transceiver
        // while the live one (the one libwebrtc actually sends RTP for)
        // stayed track-less — indistinguishable from "audio works" in every
        // log this function emits, and exactly the shape of a live call
        // (9b542759, Android<->iOS, 2026-08-28) that negotiated audio-srtp-v1
        // and died to iOS's own W-MEDIADEAD watchdog with reason=media-lost
        // after ~90s of zero decoded inbound audio on the Android side.
        // Fix: never trust the cached reference — always re-resolve the live
        // audio transceiver from the peer connection's current transceiver
        // list (ObjC wrapper objects are not identity-stable across a
        // rewire, per the video path's own `.relatch` comment, so `mid`/
        // object-identity comparison against the cache would be unreliable;
        // a 1:1 call has at most one audio transceiver, so `mediaType`
        // alone is a safe, unambiguous match). Cache is refreshed so any
        // other call site reading `audioTransceiver` sees the live object too.
        // W-AUDIOSENDPICK (2026-08-30, iOS<->iOS call at 10:23, TestFlight
        // 1050) — `.first(where: audio)` is only correct while there is
        // exactly ONE audio transceiver. When JSEP cannot recycle the
        // pre-created one it ADDS a second for the remote m-line ("Adding
        // audio transceiver in response to the remote description"), and
        // `.first` then keeps picking the PRE-CREATED, never-associated
        // object: the mic track lands on a transceiver libwebrtc does not
        // send for, `attachSender` succeeds, the controller logs
        // `audiosrtp tx=1` — and the outbound-rtp stats row never exists.
        // The W-SRTPRXDIAG heartbeat measured exactly that: the callee ran
        // the whole call with `tx=-1` while logging a successful arm, the
        // caller (whose answer consequently announced no inbound audio)
        // never got a receiver (`rxc` absent, `rx=-1`), and W-MEDIADEAD
        // eventually ended the call for want of data.
        //
        // The live transceiver is the ASSOCIATED one — non-empty `mid`.
        // Pre-negotiation nothing has a mid yet and there is only the
        // pre-created object, so the fallback keeps the original behavior.
        let audioTransceivers = pc.transceivers.filter { $0.mediaType == .audio }
        guard let transceiver = audioTransceivers.first(where: { !$0.mid.isEmpty })
            ?? audioTransceivers.first else {
            diag?("audiosrtp act=1 n=0 sel=0 dir=-1 br=0 en=0 att=0")
            return false
        }
        diagN = audioTransceivers.count
        diagSel = transceiver.mid.isEmpty ? 0 : 1
        diagDir = transceiver.direction.rawValue
        if audioTransceivers.count > 1 {
            print("[WebRTC] W-AUDIOSENDPICK: \(audioTransceivers.count) audio transceivers — picked mid=\(transceiver.mid)")
        }
        if audioTransceiver !== transceiver {
            print("[WebRTC] IOS-C4b: audio transceiver was rewired by JSEP — re-resolved to the live object")
            audioTransceiver = transceiver
        }
        guard key.count == 32 else {
            print("[WebRTC] IOS-C4b: activateNativeAudioSrtp refused — key is \(key.count) bytes, expected 32")
            return false
        }
        // Fail-closed: reject an all-zero (earbud-SPE placeholder) key, same
        // guard as the video path (`applyFrameCryptionKey`). Structurally
        // unreachable (CallCapabilities withholds audioSrtpV1 whenever
        // earbudPaired), belt-and-braces in case that invariant is ever
        // violated by a future change.
        guard key.contains(where: { $0 != 0 }) else {
            print("[WebRTC] IOS-C4b: activateNativeAudioSrtp refused — all-zero (earbud-SPE placeholder) key")
            return false
        }

        let cryptor = nativeAudioCryptor ?? {
            let c = NativeAudioFrameCryptor(factory: factory, participantId: participantId)
            nativeAudioCryptor = c
            return c
        }()
        // WIRE_SPEC §8.7 v1.2 (Task 4, completing Task 3's split) — this
        // call site handles BOTH initial activation and later rekeys of
        // native audio-srtp (see `installAudioSrtpIfPossible`'s own doc —
        // "repeat calls (rekey) just re-publish the key"), but install and
        // switch are no longer combined here: `installAudioSrtpIfPossible`
        // (the sole caller) decides WHEN it is safe to switch — immediately
        // for this call's first key (epoch 0, unchanged behavior) or
        // deferred behind a RekeySwitchGate for a live rekey (epoch > 0) —
        // and calls `switchSender` itself once that decision is made. This
        // function's own job stays exactly "install the key + (re)resolve/
        // attach the live sender", unconditionally, on every call: the key
        // is already validated as 32 bytes non-all-zero above, so
        // `installKey` here always succeeds (guard kept for defense in
        // depth, matching `setKey`'s own original guard discipline).
        _ = cryptor.installKey(key, slot: slot)

        // W-AUDIOSENDPICK — carry an already-created mic track onto the live
        // sender instead of minting a second one: the track (with its PCM
        // tap) may sit on a transceiver JSEP has since orphaned. Same
        // carry-over the DataChannel-era onTrack path does on Android.
        if transceiver.sender.track == nil,
           let existingTrack = localAudioSrtpTrack,
           let previousSender = nativeAudioSender,
           previousSender !== transceiver.sender {
            previousSender.track = nil
            transceiver.sender.track = existingTrack
            nativeAudioSender = transceiver.sender
            diagBr = 1
            print("[WebRTC] W-AUDIOSENDPICK: carried existing mic track onto the live sender")
        }
        // W-AUDIOSENDPICK — a transceiver that cannot send is not fixable by
        // assigning `sender.track`: on this WebRTC build
        // `RTCRtpTransceiver.direction` is READONLY (no `setDirection:` —
        // see W-RECVONLYPIN in attachLocalVideo, which hit the identical
        // wall). A JSEP-added transceiver for a remote m-line starts
        // recvonly, so the callee's answer advertises no outbound audio and
        // libwebrtc never sends. `pc.add(track:streamIds:)` is the one API
        // that promotes (JSEP: AddTrack reuses a recvonly transceiver whose
        // sender has no track and sets it to sendrecv) — exactly the video
        // path's fallback, mirrored here. The direction change reaches the
        // wire on the NEXT negotiation this call performs; the pre-answer
        // call sites run before createAnswer, where it lands immediately.
        let canSend = transceiver.direction == .sendRecv || transceiver.direction == .sendOnly
        if transceiver.sender.track == nil, !canSend {
            let source = factory.audioSource(with: nil)
            let track = factory.audioTrack(with: source, trackId: audioTrackId)
            track.isEnabled = false
            localAudioSrtpTrack = track
            pc.add(track, streamIds: [stableStreamId])
            nativeAudioSender = pc.senders.first { $0.track?.trackId == audioTrackId }
            diagBr = 2
            print("[WebRTC] W-AUDIOSENDPICK: transceiver direction=\(transceiver.direction.rawValue) cannot send — promoted via addTrack")
            let txTap = NativeAudioPcmTap(sink: txSink)
            track.add(txTap)
            audioTxTap = txTap
        } else if transceiver.sender.track == nil {
            let source = factory.audioSource(with: nil)
            let track = factory.audioTrack(with: source, trackId: audioTrackId)
            // W-AUDIOSENDERGATE (2026-08-27) — fail-closed: the track used to
            // be enabled here unconditionally, before the cryptor below was
            // confirmed attached. `attachSender`'s return value was then
            // discarded entirely and this function always returned `true`
            // regardless of whether the native RTCFrameCryptor actually
            // constructed — the same unguarded sender-attach race already
            // root-caused and fixed for video (W-SENDERCRYPTORSTUCK) on
            // Android, but here with no bounded wait and no honest failure
            // signal at all. If `RTCFrameCryptor` init failed for any reason
            // (timing/threading), the mic sent plaintext audio for the whole
            // call while every log line claimed success — the peer's own
            // receiver cryptor discards anything that doesn't decrypt,
            // producing exactly "I hear nothing from them" with zero error
            // anywhere. Start disabled; only enable once attach is confirmed.
            track.isEnabled = false
            localAudioSrtpTrack = track
            transceiver.sender.track = track
            nativeAudioSender = transceiver.sender
            diagBr = 3
            print("[WebRTC] IOS-C4b: mic track attached to native audio transceiver (disabled pending cryptor confirm)")
            let txTap = NativeAudioPcmTap(sink: txSink)
            track.add(txTap)
            audioTxTap = txTap
        }
        // W-PREATTACHMIC — the mic track now pre-exists from `init()` (so
        // the FIRST SDP round negotiates sendRecv on both roles); its PCM
        // tap could not be installed there because the tx sink only arrives
        // here. Install it on first activation. The br=2/3 branches above
        // set `audioTxTap` themselves, so this is a no-op for them.
        if audioTxTap == nil, let preTrack = localAudioSrtpTrack {
            let txTap = NativeAudioPcmTap(sink: txSink)
            preTrack.add(txTap)
            audioTxTap = txTap
        }
        // W-AUDIOSENDPICK — attach to the sender that actually carries the
        // track: after an addTrack promotion that can differ from
        // `transceiver.sender` (AddTrack may have created a new transceiver
        // when none was reusable).
        let effectiveSender = nativeAudioSender ?? transceiver.sender
        let attached = cryptor.attachSender(effectiveSender)
        if attached {
            localAudioSrtpTrack?.isEnabled = !pendingAudioSrtpMuted
        }
        diag?("audiosrtp act=1 n=\(diagN) sel=\(diagSel) dir=\(diagDir) br=\(diagBr) en=\(localAudioSrtpTrack?.isEnabled == true ? 1 : 0) att=\(attached ? 1 : 0)")
        if !attached {
            print("[WebRTC] IOS-C4b: activateNativeAudioSrtp — sender cryptor attach FAILED, mic stays muted (caller should retry)")
        }
        return attached
    }

    /// W-AUDIOAEADREKEY (2026-09-02) — B3: create the per-call native AUDIO
    /// FrameCryptor holder (idempotent), audio mirror of
    /// `ensureNativeVideoCryptor`. Lets the controller wire
    /// `onDecryptFailure` onto the OUTER holder before (or independently
    /// of) `attachAudioReceiverCryptor`/`activateNativeAudioSrtp` actually
    /// attaching a sender/receiver — the closure lives on this holder, not
    /// the transient `RTCFrameCryptor` those attach, so it survives a
    /// mid-call rebind (`rebindAudioReceiverCryptorPostNegotiation`)
    /// unchanged, same as video's.
    @discardableResult
    public func ensureNativeAudioCryptor(participantId: String) -> NativeAudioFrameCryptor {
        if let c = nativeAudioCryptor { return c }
        let c = NativeAudioFrameCryptor(factory: factory, participantId: participantId)
        nativeAudioCryptor = c
        return c
    }

    /// Attach + enable the native AUDIO cryptor on an inbound SRTP audio
    /// receiver, and install the RX PCM tap (PCM-TAP PARITY). Call from the
    /// `didAdd rtpReceiver` branch once `peerCallCapabilities?.useAudioSrtp
    /// == true` is confirmed — see that method for the full negotiation
    /// gate. Idempotent (``NativeAudioFrameCryptor/attachReceiver(_:)`` is
    /// write-once).
    @discardableResult
    public func attachAudioReceiverCryptor(_ receiver: RTCRtpReceiver,
                                           participantId: String,
                                           rxSink: @escaping (Data) -> Void) -> Bool {
        let cryptor = nativeAudioCryptor ?? {
            let c = NativeAudioFrameCryptor(factory: factory, participantId: participantId)
            nativeAudioCryptor = c
            return c
        }()
        let attached = cryptor.attachReceiver(receiver)
        if let track = receiver.track as? RTCAudioTrack, audioRxTap == nil {
            let tap = NativeAudioPcmTap(sink: rxSink)
            track.add(tap)
            audioRxTap = tap
            audioRxTapTrack = track
        }
        return attached
    }

    /// Mute/unmute the native-RTP audio track for this call. No-op (beyond
    /// latching ``pendingAudioSrtpMuted``) when the track has not been
    /// created yet — ``activateNativeAudioSrtp(key:participantId:txSink:)``
    /// applies the latched value once it is. Safe to call on every call
    /// regardless of ``CallCapabilities/audioSrtpV1`` negotiation: harmless
    /// when ``localAudioSrtpTrack`` is `nil`, which is every call that stays
    /// on the DataChannel/WS-relay path.
    public func setNativeAudioSrtpMuted(_ muted: Bool) {
        pendingAudioSrtpMuted = muted
        localAudioSrtpTrack?.isEnabled = !muted
    }

    /// W-AUDIORXPOSTNEG (2026-08-28) — audio mirror of
    /// ``rebindVideoReceiverCryptorPostNegotiation()``. Re-resolves the live
    /// audio transceiver (mediaType match, safe for a 1:1 call — see
    /// ``activateNativeAudioSrtp(key:participantId:txSink:)``'s own W-
    /// AUDIOSRTPSENDERCARRYOVER comment for why identity comparison against
    /// a cached reference is not reliable here) and re-binds the receiver
    /// cryptor onto its CURRENT receiver. Call after the SDP round that
    /// negotiated `audioSrtpV1` has actually completed (mirrors the video
    /// call sites — see ``QAudionWebRtcCallController``'s
    /// ``installAudioSrtpIfPossible`` caller). No-op (`false`) if no audio
    /// transceiver or no audio cryptor exists yet.
    @discardableResult
    public func rebindAudioReceiverCryptorPostNegotiation() -> Bool {
        guard let pc = peerConnection, let cryptor = nativeAudioCryptor else { return false }
        guard let transceiver = pc.transceivers.first(where: { $0.mediaType == .audio }) else {
            return false
        }
        audioTransceiver = transceiver
        let ok = cryptor.rebindReceiver(transceiver.receiver)
        // W-AUDIORXTAPCARRYOVER (2026-08-29) — the rebind above moves the
        // CRYPTOR to the live receiver, but the PCM tap is a renderer
        // registered on a TRACK, and it was added to whichever track the
        // first `attachAudioReceiverCryptor` saw. When JSEP replaced the
        // receiver during negotiation (the very case this rebind exists
        // for), the tap stayed on the OLD, now-dead track: audio played
        // fine in both directions — the cryptor was on the right receiver
        // and libwebrtc renders the new track itself — while every
        // consumer fed by the tap (VoiceAnalysisEngine's live waveform,
        // GuardianMode liveness, ContactVoiceVerifier, VoiceLearningSession)
        // saw zero frames for the whole call. Live report 2026-08-29,
        // iOS<->Android: "audio fine both ways, no voice curve, no liveness
        // analysis on iOS". Move the tap onto the current track whenever it
        // changed; no-op when the receiver was already the right one.
        if let newTrack = transceiver.receiver.track as? RTCAudioTrack,
           let tap = audioRxTap,
           newTrack !== audioRxTapTrack {
            audioRxTapTrack?.remove(tap)
            newTrack.add(tap)
            audioRxTapTrack = newTrack
            print("audiosrtp rxtap moved=1")
        }
        print("[WebRTC] IOS-C4b: post-negotiation audio receiver cryptor rebound ok=\(ok)")
        return ok
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

    /// W-OFFERGLARE / W-SILENTPATHDEATH (2026-08-25) — read-only mirror of
    /// the underlying `RTCPeerConnection.signalingState`. `nil` when no PC
    /// exists yet (mirrors every other `pc?.` accessor in this class).
    /// Callers that need to branch on the state (restart-offer glare
    /// detection) use `RestartIceDecisions.LocalSignalingState`, not this
    /// raw WebRTC enum, so the branch logic stays testable without the
    /// WebRTC binary target.
    public var signalingState: RTCSignalingState? {
        peerConnection?.signalingState
    }

    /// W536 decline-rollback — JSEP rollback of a pending local offer so
    /// the PC returns to `stable`. After a declined/timed-out upgrade the
    /// PC was parked in `have-local-offer`; the peer's NEXT upgrade offer
    /// then failed `setRemoteOffer` with "Called in wrong state:
    /// have-local-offer" (the same engine-family error Android documents in
    /// its explicit-rollback fix), which auto-sent accepted=false — one
    /// decline killed upgrades in BOTH directions. No-op unless
    /// signalingState == haveLocalOffer.
    ///
    /// W-OFFERGLARE reuses this SAME primitive for the restart-offer glare
    /// rollback (`QAudionWebRtcCallController.applyRemoteRestartOffer`) —
    /// it is a raw JSEP rollback with no `videoUpgradeInProgress` gate, so
    /// it is safe to call from a non-video-upgrade context too.
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

    /// W-RESPONDERPRIME (2026-09-05, port of Android `PeerConnectionHolder.
    /// restartIce`'s `!activeAsInitiator` branch, `pc.restartIce()` at
    /// `PeerConnectionHolder.kt:4965`) — kick the local ICE agent's
    /// re-gather (fresh ufrag/pwd, fresh candidate gathering) WITHOUT any
    /// SDP exchange: no `createOffer`, no `setLocalDescription`, no
    /// signaling-state change at all.
    ///
    /// This is the missing head start in `QAudionWebRtcCallController.
    /// restartIce`'s W-RESPONDERREQFIRST branch: when this side is the
    /// RESPONDER and the peer negotiated `restart-ice-req-v1`, this side
    /// deliberately never builds its own offer (that is the whole point of
    /// request-first — "exactly one leg ever authors restart offers", see
    /// that branch's own doc) — so nothing on this side previously
    /// triggered local candidate re-gathering before the peer's own
    /// restart offer arrives and gets applied via `applyRemoteRestartOffer`.
    /// Calling this in parallel with the request lets local gathering run
    /// WHILE the request/offer round trip is in flight instead of only
    /// starting once that round trip completes — the same "candidates
    /// already gathering the instant the network changes" property
    /// Android's responder has always had for this branch.
    ///
    /// `createOffer`'s own doc above records why it deliberately avoids
    /// calling `restartIce()` directly: no local toolchain to grep-verify
    /// the symbol against this app's vendored WebRTC binary, so that path
    /// instead leans on the "IceRestart" SDP constraint (core-libwebrtc,
    /// verified stable across every binding). That constraint-based
    /// substitute is not available here — this branch has no SDP to attach
    /// a constraint to in the first place. `restartIce()` is a standard,
    /// long-standing public method on `RTCPeerConnection` (added for W3C
    /// `RTCPeerConnection.restartIce()` spec parity well before this app's
    /// pinned M144 branch, and untouched by this fork's H265/AES-256
    /// FrameCryptor patches, which only touch the encoder/decoder/cryptor
    /// layers — not signaling/ICE) — verified here via CI's real Swift
    /// compiler rather than a local build (still unavailable this
    /// session): a wrong symbol fails the build loud, before merge, rather
    /// than silently at runtime.
    public func primeIceRestart() {
        guard let pc = peerConnection else { return }
        pc.restartIce()
        print("[WebRTC] primeIceRestart: local ICE re-gather kicked (no SDP sent)")
    }

    // MARK: - Offer / Answer

    /// - Parameter iceRestart: W-SILENTPATHDEATH (2026-08-25) — when `true`,
    ///   adds the standard WebRTC `"IceRestart": "true"` mandatory
    ///   constraint so the resulting offer carries FRESH local ICE
    ///   ufrag/pwd, forcing a full local re-gather. This is the SAME
    ///   constraint-key mechanism Android's `createOffer(pc, iceRestart =
    ///   true)` uses (`MediaConstraints.KeyValuePair("IceRestart",
    ///   "true")`, `PeerConnectionHolder.kt`) — "IceRestart" is a
    ///   core-libwebrtc constraint name shared by every SDK binding, not an
    ///   ObjC/Swift-specific API, so this is a verified 1:1 wire-level
    ///   match rather than a guessed API surface (no toolchain available
    ///   here to grep-verify a `restartIce()` method symbol on
    ///   `RTCPeerConnection` directly — this constraint-based path sidesteps
    ///   that entirely and has been stable across every WebRTC ObjC binding
    ///   version).
    public func createOffer(audioOnly: Bool = true,
                            iceRestart: Bool = false,
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

        var mandatory: [String: String] = [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": "true"
        ]
        if iceRestart {
            mandatory["IceRestart"] = "true"
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, err in
            if let err = err {
                completion(.failure(err)); return
            }
            guard let sdp = sdp else {
                completion(.failure(WebRTCError.sdpFailed("offer returned nil"))); return
            }
            // IOS-C4b / W-SRTPPTIME — apply the fixed Opus/audio-srtp profile
            // to every SDP this client produces. Safe on every call, even one
            // that never negotiates audioSrtpV1 (see AudioSdpPolicy's own
            // doc): a no-op transform on an m=audio section carrying no RTP
            // audio.
            let mungedText = AudioSdpPolicy.apply(sdp.sdp)
            let munged = mungedText == sdp.sdp ? sdp : RTCSessionDescription(type: sdp.type, sdp: mungedText)
            logH265FmtpLines(munged.sdp, tag: iceRestart ? "LOCAL_OFFER_ICE_RESTART" : "LOCAL_OFFER")
            self?.peerConnection?.setLocalDescription(munged, completionHandler: { setErr in
                if let setErr = setErr {
                    completion(.failure(setErr))
                } else {
                    completion(.success(munged.sdp))
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
            // IOS-C4b / W-SRTPPTIME — same policy as createOffer, applied
            // AFTER the DTLS-role pin (pure string transforms on disjoint
            // attribute sets — order between them does not matter, but
            // matching Android/createOffer's own "policy last" placement).
            let mungedText = AudioSdpPolicy.apply(pinnedSdpText)
            let pinnedSdp = mungedText == sdp.sdp ? sdp : RTCSessionDescription(type: sdp.type, sdp: mungedText)
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
        // IOS-C4b / W-SRTPPTIME — munging the INBOUND SDP constrains OUR OWN
        // encoder even against a peer that sends unmunged defaults (Android
        // applies the same policy bidirectionally — see AudioSdpPolicy's own
        // doc for why this is unilateral-safe).
        let munged = AudioSdpPolicy.apply(sdp)
        logH265FmtpLines(munged, tag: type == .offer ? "REMOTE_OFFER" : "REMOTE_ANSWER")
        let desc = RTCSessionDescription(type: type, sdp: munged)
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

    /// W-ICEBATCH (2026-08-25) — prune a remote candidate the peer withdrew
    /// (`removed: true` in the batched `call_ice` form). `removeIceCandidates:`
    /// is stock libwebrtc ObjC API (imported as `remove(_:)`); removing a
    /// candidate that was never added is a native no-op, which is exactly
    /// right for a removal that raced ahead of (or outlived) its add.
    public func removeRemoteIce(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        guard let pc = peerConnection else { return }
        let cand = RTCIceCandidate(sdp: candidate,
                                   sdpMLineIndex: sdpMLineIndex,
                                   sdpMid: sdpMid)
        pc.remove([cand])
    }

    // MARK: - Close

    public func close() {
        // Dispose the FrameCryptor BEFORE closing the PC — it holds a native
        // ref into the sender/receiver (Android dispose order
        // PeerConnectionHolder.kt:993-997).
        nativeVideoCryptor?.dispose()
        nativeVideoCryptor = nil
        // IOS-C4b — same ordering discipline for the audio cryptor. Taps are
        // plain Swift objects (no native ref beyond the RTCAudioTrack's own
        // renderer list, which is torn down with the track/PC itself) —
        // dropping the strong references here is enough.
        nativeAudioCryptor?.dispose()
        nativeAudioCryptor = nil
        audioRxTap = nil
        // W-AUDIORXTAPCARRYOVER — drop the track reference alongside the tap
        // it points at, same reasoning as the comment above.
        audioRxTapTrack = nil
        audioTxTap = nil
        audioTransceiver = nil
        nativeAudioSender = nil
        localAudioSrtpTrack = nil
        usingNativeAudioSrtp = false
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
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // W-TURNSUSPECT (IOS-E4) — a fresh cycle starting (covers the
        // initial gather and any future ICE-restart re-gather) resets the
        // counter; reaching `.complete` reports what it found.
        switch newState {
        case .gathering:
            relayCandidateCount = 0
        case .complete:
            delegate?.peerConnection(self, didCompleteIceGatheringWithRelayCandidates: relayCandidateCount)
        default:
            break
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // W-TURNSUSPECT (IOS-E4) — standard ICE-SDP candidate line shape is
        // `candidate:<foundation> <component> <transport> <priority> <ip>
        // <port> typ <type> ...`; " typ relay " is the RFC 5245 marker for a
        // TURN-allocated relay candidate.
        if candidate.sdp.contains(" typ relay ") {
            relayCandidateCount += 1
        }
        delegate?.peerConnection(self,
                                 didDiscoverLocalIceCandidate: candidate.sdp,
                                 sdpMid: candidate.sdpMid,
                                 sdpMLineIndex: candidate.sdpMLineIndex)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    /// W-ROUTETIEREVENT (2026-08-26, P2 audit item 4) — the OPTIONAL
    /// `RTCPeerConnectionDelegate` "selected candidate pair changed" event.
    /// Bound via an EXPLICIT `@objc` selector rather than relying on
    /// Swift's automatic Objective-C name-import (which strips a trailing
    /// piece of the selector matching the parameter's type name and is not
    /// something to guess at for a 5-argument selector — a wrong guess
    /// compiles clean and is just silently never called, the same trap
    /// already documented on `resolveAndApplyRouteTier`). The literal
    /// selector string below was fetched and grepped from the real
    /// `sdk/objc/api/peerconnection/RTCPeerConnection.h` at the pinned
    /// webrtc-sdk/webrtc `m144_release` tag, byte-for-byte:
    ///   `peerConnection:didChangeLocalCandidate:remoteCandidate:
    ///    lastReceivedMs:changeReason:`
    /// Parameter types matter for ABI, not just the selector name — the
    /// header declares `lastReceivedMs:(int)`, so this uses `Int32`
    /// (Swift's plain `Int` bridges to the WIDER `NSInteger`/`long` and
    /// would not match the 4-byte `int` the real caller passes).
    @objc(peerConnection:didChangeLocalCandidate:remoteCandidate:lastReceivedMs:changeReason:)
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                                didChangeLocalCandidate local: RTCIceCandidate,
                                remoteCandidate remote: RTCIceCandidate,
                                lastReceivedMs: Int32,
                                changeReason reason: String) {
        delegate?.peerConnection(self, didChangeSelectedCandidatePairChangeReason: reason)
    }

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
        // W-DCMUX — CALLEE receipt, with the call id attached by the app layer.
        onAudioDataChannelStateChange?(st)
    }

    // Unified-plan track callback.
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let audio = rtpReceiver.track as? RTCAudioTrack {
            // IOS-C4b (2026-08-26): when both peers negotiated
            // CallCapabilities.audioSrtpV1, THIS is the real call audio —
            // the native FrameCryptor decrypts it, native NACK/RTX repair
            // it, NetEQ conceals loss. Keep it enabled and hand the raw
            // receiver to the delegate so the call controller (which owns
            // the PQC session key and the PCM-tap sinks) can attach the
            // audio FrameCryptor + RX PCM tap. `useAudioSrtp` can never be
            // true on an earbud call (CallCapabilities.localCaps withholds
            // the tag), so this branch never fires there. Mirrors Android
            // `PeerConnectionHolder.onTrack`'s AUDIO_SRTP_V1 branch.
            if peerCallCapabilities?.useAudioSrtp == true {
                usingNativeAudioSrtp = true
                delegate?.peerConnection(self, didReceiveNativeAudioSrtpReceiver: rtpReceiver)
                delegate?.peerConnection(self, didReceiveRemoteAudioTrack: audio)
            } else {
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

    // Default no-op so Delegate conformers that don't handle audio-srtp
    // need not implement the audio-cryptor hook (IOS-C4b).
    func peerConnection(_ pc: QAudionPeerConnection,
                        didReceiveNativeAudioSrtpReceiver receiver: RTCRtpReceiver) {}

    func peerConnection(_ pc: QAudionPeerConnection,
                        didChangeConnectionState state: RTCPeerConnectionState) {}

    func peerConnection(_ pc: QAudionPeerConnection,
                        didCompleteIceGatheringWithRelayCandidates count: Int) {}

    // W-ROUTETIEREVENT — default no-op so conformers that only need the
    // existing 3s poll need not implement the event-driven trigger.
    func peerConnection(_ pc: QAudionPeerConnection,
                        didChangeSelectedCandidatePairChangeReason reason: String) {}
}

// MARK: - RTCDataChannelDelegate (W-DCAUDIO sealed-audio channel)
extension QAudionPeerConnection: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel === audioDataChannel else { return }
        let st = dataChannel.readyState.rawValue
        print("[WebRTC] sealed-audio DataChannel state → \(st)")
        // W-DCMUX — the transition the app has to see. A channel that leaves
        // OPEN mid-call is dead air on the DC leg, and this is the only place
        // iOS learns about it: `peer.events`-style ICE transitions say nothing
        // about SCTP, and nothing else polls the readyState.
        onAudioDataChannelStateChange?(st)
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

/// W-DCMUX (2026-08-11) — the two cross-platform string literals of the
/// sealed-audio DataChannel, in one place, so they can be pinned by a test.
///
/// Namespaced outside the `canImport(WebRTC)` block (same shape as
/// ``AudioDcBackpressureGate`` above) so the regression test runs on a CI
/// machine without the WebRTC binary. Nothing here is a decision; it is two
/// constants that three platforms have to agree on byte for byte.
enum SealedAudioDataChannelWire {
    /// The DataChannel label. LOAD-BEARING: both ends select the sealed-audio
    /// channel by comparing this string for equality — Android at
    /// `PeerConnectionHolder.kt:3865`, iOS in `didOpen` above, Desktop in
    /// `MediaTransport.ts`. A rename on any one platform is a silent break that
    /// only shows up as a call with no audio.
    static let label = "qaudion-audio"

    /// The DataChannel subprotocol Android sets (`DataChannel.Init.protocol`,
    /// `PeerConnectionHolder.kt:1461`) and Desktop declares
    /// (`MediaTransport.ts:56`, `DATA_CHANNEL_PROTOCOL`).
    ///
    /// iOS deliberately leaves the channel's subprotocol UNSET. Neither end
    /// reads it — it is symmetry, not negotiation — and the property is spelled
    /// `protocol` in the WebRTC ObjC header
    /// (`sdk/objc/api/peerconnection/RTCDataChannelConfiguration.h`, verified
    /// against upstream), which is a Swift keyword and therefore needs escaping
    /// that could not be compiled or tested on the machine this change was
    /// written on. Setting a field nobody reads is not worth a build risk on an
    /// unverifiable spelling. The constant is kept so the agreed value is
    /// written down once and pinned by a test, and so that whoever does set it
    /// copies the string instead of retyping it.
    static let subprotocol = "qaudion-sealed/1"
}
