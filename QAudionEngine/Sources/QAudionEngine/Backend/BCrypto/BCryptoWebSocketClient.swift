import Foundation
import Network

public final class BCryptoWebSocketClient: @unchecked Sendable {
    public typealias MessageHandler = (String, [String: Any]) -> Void

    /// Async silent token-recovery callback wired by the integration layer
    /// (BCryptoBackendProvider) to the REST client's refresh → Ed25519
    /// device-renew cascade. Invoked ONCE when the server rejects our token
    /// with `auth_failed`, BEFORE we resume the reconnect loop. Returns
    /// `true` if a fresh token was obtained (resume reconnect), `false` on
    /// genuine revocation (stop — the app layer drives re-onboarding; this
    /// class NEVER forces QR). A plain `() async -> Bool` so the AppState
    /// type is never dragged into this file's symbol graph (CLAUDE.md sec 16).
    public var onAuthFailedRecover: (@Sendable () async -> Bool)?

    // MARK: - Pre-negotiation callbacks
    // Wired by the integration/UI layer. Set on the client BEFORE connect() so
    // the dispatcher catches them as soon as the server starts emitting.
    // Mirror the desktop CallController pre-negotiation events — see
    // qaudion-desktop/src/main/calling/CallController.ts CallProgressPhase.

    /// Fired when this client (caller) receives `call_processing` from the responder.
    /// The responder has acked our call_offer and is starting PQC setup.
    public var onCallProcessing: ((_ callId: String, _ receiverId: String) -> Void)?

    /// Fired when this client (caller) receives `call_ready` from the responder.
    /// The responder finished PQC setup and is now ringing — we should show "Ringing".
    public var onCallReady: ((_ callId: String, _ receiverId: String, _ deviceId: String?) -> Void)?

    /// Fired when this client (responder) receives `call_ring` from the server,
    /// signalling that the caller has been notified we are ringing. Mostly an
    /// informational ack — used to gate fallback ring triggers if the local UI
    /// hasn't already started a CallKit alert.
    public var onCallRing: ((_ callId: String, _ callerId: String) -> Void)?

    /// Fired when this client (caller) receives `call_peer_offline` from the server.
    /// The recipient has no live device — terminate with a "peer offline" error.
    public var onCallPeerOffline: ((_ callId: String, _ recipientId: String) -> Void)?

    /// Fired when this client (caller) receives `call_busy` from the server.
    /// The recipient IS online but is already in another answered call — our
    /// outgoing call was rejected. Sibling of `onCallPeerOffline`: the caller
    /// must stop ringing immediately, briefly show a "busy" state, and tear the
    /// outgoing call down cleanly. Wire payload: {call_id, recipient_id}.
    public var onCallBusy: ((_ callId: String, _ recipientId: String) -> Void)?

    /// Fired when this client (responder) receives `call_cancel` from the server.
    /// The caller hung up before we picked up — stop ringing locally.
    public var onCallCancel: ((_ callId: String, _ reason: String?) -> Void)?

    /// Fired when this client (caller) receives `call_accepted` from the
    /// callee — a real user (or equivalent human-input surface) explicitly
    /// answered, as opposed to `call_ready`'s automatic network-readiness
    /// signal. Gates the caller's SAS/active-call display (WIRE_SPEC §3.5).
    public var onCallAccepted: ((_ callId: String, _ senderId: String) -> Void)?

    /// W536 — mid-call audio↔video upgrade. The initiator side ships a
    /// fresh SDP offer (with the new video m-section); the callee
    /// applies it as a remote offer, generates an answer, and ships
    /// it back via `call_upgrade_response`. Wire format matches
    /// `qaudion-desktop/src/main/calling/CallController.ts:
    /// requestUpgradeToVideo` (call_id + sdp on request, plus
    /// `accepted` boolean on response) so iOS↔desktop↔Android can
    /// upgrade interchangeably.
    /// media-consent v1: `media` is "camera" (peer asks to turn their camera
    /// on — requires the user's consent before answering) or "screen" (peer
    /// is sharing their screen — auto-accepted, never opens our camera).
    /// Absent on the wire ⇒ "camera".
    public var onCallUpgradeRequest: ((_ callId: String, _ senderId: String, _ sdp: String, _ media: String) -> Void)?
    /// `senderId` added 2026-07-07 (GAP-10, cross-platform matrix audit):
    /// unlike `onCallUpgradeRequest`, this callback previously carried no
    /// sender identity at all, so `handleUpgradeResponse` could not validate
    /// who a response actually came from.
    public var onCallUpgradeResponse: ((_ callId: String, _ senderId: String, _ accepted: Bool, _ sdp: String) -> Void)?

    /// `call_upgrade_intent` (peer→us) — the peer wants video but is asking
    /// US to send the real `call_upgrade_request` offer instead of sending
    /// one itself. No SDP attached. Mirrors Android
    /// `WsEvent.CallUpgradeIntent` / `CallController.kt`'s
    /// `upgradeIntentListenerJob` (device-confirmed 2026-07-06: a
    /// Desktop-sent video re-offer added mid-call doesn't reliably reach a
    /// healthy ICE/DTLS state on some peer WebRTC stacks; the callee
    /// sending its own offer does). We answer by generating our own real
    /// offer (same code path as the local user tapping the video button)
    /// after the same consent gate a normal `call_upgrade_request` shows.
    /// media-consent v1: `media` absent on the wire ⇒ "camera".
    public var onCallUpgradeIntent: ((_ callId: String, _ senderId: String, _ media: String) -> Void)?

    /// WIRE_SPEC §8.7 (v1.1) — receiver→sender media readiness. The peer's
    /// receiver-side video cryptor is BOTH keyed and bound to the negotiated
    /// mid; we (the video SENDER) must force a local encoder IDR so the
    /// peer's decoder bootstraps immediately. Server stamps `sender_id` and
    /// relays transparently (same envelope class as call_upgrade_*).
    /// `mid` may be empty when the peer could not resolve the transceiver
    /// mid; `dir` is "recv" today; `keyEpoch` is 0 until rekey epochs ship.
    public var onCallMediaReady: ((_ callId: String, _ senderId: String, _ mid: String, _ keyEpoch: Int, _ dir: String) -> Void)?

    /// WIRE_SPEC §8.7 (v1.1) — receiver→sender explicit keyframe recovery.
    /// The E2EE frame-transform suppresses libwebrtc's native PLI, so the
    /// peer's decoder recovery REQUIRES this wire path. Honor side MUST
    /// force a local encoder IDR, rate-limited to 1/s.
    public var onVideoKeyframeRequest: ((_ callId: String, _ senderId: String) -> Void)?

    /// WIRE_SPEC §8.1 — `call_video_state`, either direction, transparent
    /// relay. Informational signal: the peer toggled their camera
    /// off/on (purely a wire-level heads-up so the receiving side can
    /// show "peer paused their video" / auto-fall-back to the audio-only
    /// call UI — it never drives renegotiation, the underlying
    /// PeerConnection and m=video line stay untouched). Same envelope
    /// class as call_media_ready / video_keyframe_request: the server
    /// stamps `sender_id` and relays transparently.
    ///
    /// WIRE_SPEC §8.9 — `seq` is the beacon's ordering token: nil from a peer
    /// that predates it, which the receive rule treats as "always accept"
    /// (see ``VideoStateBeacon``).
    public var onCallVideoState: ((_ callId: String, _ paused: Bool, _ seq: Int?) -> Void)?

    /// W-ACTIVECALLASSERT (2026-08-25) — live view of the call id this
    /// process currently believes is live, or `nil` when it holds no call
    /// state. Consulted on EVERY `authenticate` frame so a mid-call
    /// reconnect asserts the call and the server cancels its pending
    /// disconnect-grace teardown (exact match only — a wrong or absent
    /// assertion lets the timer run and the call dies). Wired by the
    /// integration layer (BCryptoBackendProvider → the calling impl's
    /// bound call id), mirroring Android's `WsDispatcher
    /// .activeCallIdProvider`, so this transport file never depends on
    /// the call layer. Invoked on the WS delegate thread — the closure
    /// MUST be thread-safe (the calling impl's accessor locks).
    public var activeCallIdProvider: (@Sendable () -> String?)?

    private var webSocketTask: URLSessionWebSocketTask?
    /// SECURITY C-6 / H-5 — strong ref to the session delegate so it
    /// survives the lifetime of the `URLSession` (URLSession only holds
    /// its delegate weakly via the configuration; without this the
    /// pinning + open-callback delegate would be deallocated immediately
    /// after `connect()` returns and the TLS challenge / open frame
    /// would fall back to default handling).
    private var sessionDelegate: WSSessionDelegate?
    private let lock = NSLock()
    private var _state: ConnectionState = .disconnected
    private var config: BackendConfig
    private var messageHandlers: [String: MessageHandler] = [:]
    private var stateListeners: [(ConnectionState) -> Void] = []
    /// Diagnostic only — the underlying `URLSessionWebSocketTask.receive()`
    /// error that produced the most recent `handleDisconnect()`, or a
    /// synthetic string for the explicit-cancel paths (`disconnect()` /
    /// `forceReconnect()`). Was previously discarded entirely (bare `case
    /// .failure:` in receiveLoop), so every "why did the socket drop" signal
    /// — timeout, TLS failure, DNS failure, connection reset — was
    /// unrecoverable even in a live debugger, let alone in telemetry. Read
    /// by `BCryptoPersistentConnectionImpl.lastDisconnectReason` right after
    /// a `.disconnected` state-listener callback.
    private var _lastDisconnectReason: String?
    private var reconnectAttempt = 0
    /// Always-reachable Phase 2: the persistent WS is a FOREGROUND latency
    /// optimization layered on top of the OS push channel (PushKit-VoIP),
    /// which is the real reachability spine. It must therefore retry
    /// INDEFINITELY (no attempt cap) — but with exponential backoff + jitter
    /// and a hard DELAY cap (`maxReconnectDelaySec`) so a wedged network or a
    /// dead-auth socket can never become a reconnect storm. The old
    /// `maxReconnectAttempts = 20` permanent give-up was removed: after 20
    /// failures the device went silently un-connected and only the next
    /// foreground/app-event could revive it.
    private let maxReconnectDelaySec: TimeInterval = 30
    /// Run-once guard for the silent token-recovery cascade. Set true the
    /// first time `auth_failed` triggers `onAuthFailedRecover`; reset to false
    /// on a successful `authenticated` so a *later* token expiry can recover
    /// again. While `authRecoveryInFlight`, further `auth_failed` frames are
    /// ignored (no parallel cascades).
    private var authRecoveryInFlight: Bool = false
    /// Cross-cycle anti-storm gate for the silent recovery cascade. Holds the
    /// monotonic-ish timestamp (`Date.timeIntervalSinceReferenceDate`) of the
    /// LAST time `handleAuthFailed()` actually *fired* the cascade. The
    /// `authRecoveryInFlight` boolean only dedups concurrent/within-cycle
    /// cascades; it is reset on every clean `authenticated` AND at the end of
    /// every recovery completion, so it does NOT throttle the pathological
    /// `auth_failed → recover → reconnectAttempt=0 → forceReconnect →
    /// auth_failed` loop that arises when the server keeps rejecting even a
    /// freshly-renewed token (clock skew / server-side account edge). Without a
    /// gate that survives reconnect cycles the device would run the 2-network-
    /// call cascade roughly every 1-2 s forever, draining radio/battery. This
    /// timestamp is therefore deliberately NEVER reset on `authenticated` —
    /// only advanced when the cascade fires — so consecutive auth_failed
    /// recoveries are spaced at least `minAuthRecoveryIntervalSec` apart.
    private var lastAuthRecoveryAt: TimeInterval = 0
    /// Minimum spacing between two silent recovery cascades. A genuine one-off
    /// token expiry still recovers in ~1 s (gate is open the first time); a
    /// persistent reject is capped to one cascade per this window.
    private let minAuthRecoveryIntervalSec: TimeInterval = 30
    /// Set true only when the recovery cascade itself was rejected (genuine
    /// revocation). Parks the reconnect loop until the app layer re-onboards
    /// and calls `connect()` again. NEVER forces QR from this class.
    private var authPermanentlyRejected: Bool = false
    private var pingTimer: DispatchSourceTimer?
    /// Timestamp (monotonic seconds) of the most recent inbound frame (pong or any
    /// server-sent message). Used to detect stale connections even if OS keepalive
    /// hasn't tripped the URLSessionWebSocketTask yet.
    private var lastInboundAt: TimeInterval = 0
    /// Timestamp recorded when the most recent outbound `ping` was sent.
    /// Paired with the server's `pong`/`heartbeat_ack` to compute WS RTT.
    private var pingSentAt: TimeInterval = 0
    /// Called on the utility queue with the measured WS round-trip time in
    /// milliseconds after each `ping`/`pong` cycle. Consumers should dispatch
    /// to @MainActor before updating UI state.
    public var onLatencyMeasured: ((Int) -> Void)?
    /// FAILOVER signal: invoked with the current (apparently-DEAD) wss URL after
    /// `failoverAfterAttempts` consecutive reconnect attempts to the same node
    /// (reconnectAttempt resets to 0 on a successful auth, so a transient flap
    /// never trips it). The app layer (AppState) wires this to
    /// `ServerSelector.reselectExcluding` so a dead node no longer pins the client
    /// until its ~60s server-side heartbeat TTL clears. The socket's own backoff
    /// reconnect is unchanged — this only adds a fast cross-node recovery path.
    public var onNodeStalled: ((String) -> Void)?
    /// Consecutive failed reconnects to the same node after which `onNodeStalled`
    /// fires. High enough that a flap (counter resets on auth) never trips it.
    private let failoverAfterAttempts = 3
    /// Interval between outbound ping keepalives. ADAPTIVE by transport (set by
    /// `applyAdaptiveTiming(for:)` from the NWPathMonitor): WiFi 20 s (beats
    /// carrier/NAT idle timeouts and keeps the server from marking us stale),
    /// cellular 60 s (relaxed — carrier NAT is more forgiving and radio wakeups
    /// drain battery), wired/other 30 s. Defaults to the WiFi value until the
    /// first path update arrives. `var` (was `let`) so the keepalive can retune.
    private var pingIntervalSec: TimeInterval = 20
    /// If no inbound traffic arrives within this window after a ping, treat the
    /// connection as dead and tear it down so the reconnect loop picks it up.
    /// ADAPTIVE by transport: WiFi 30 s, cellular 120 s, wired/other 45 s.
    private var pongTimeoutSec: TimeInterval = 30
    /// SOCKS5 port from the most recent explicit `connect(viaSocksPort:)` call
    /// (nil = direct dial). Sticky across INTERNAL reconnects (forceReconnect,
    /// the backoff retry below) so a Reality-routed session keeps routing
    /// through Reality after a drop instead of silently falling back to a
    /// direct dial the network may be blocking. Only an explicit external
    /// `connect(viaSocksPort:)` call changes it.
    private var currentSocksPort: Int?
    /// Debounce flag for `forceReconnect()`. iOS suspends URLSessionWebSocketTask
    /// silently when the app is backgrounded; the very first send() after
    /// foregrounding may discover task==nil and kick a reconnect. Without this
    /// flag a burst of dropped sends (e.g. opaque PQC frames) would each spawn
    /// a parallel reconnect — racing connect() calls and confusing the state
    /// machine. While `reconnectInFlight == true`, additional kicks are a no-op.
    private var reconnectInFlight: Bool = false
    /// Monotonically-increasing counter bumped on every `connect()` call.
    /// Each `receiveLoop` and `handleDisconnect` closure captures the generation
    /// at spawn time and silently drops its work if the current generation has
    /// moved on. This prevents a classic zombie-connection pattern:
    ///   1. forceReconnect() cancels old task → calls connect() → gen bumps to N+1
    ///   2. Old task's receive closure fires (failure) → calls handleDisconnect()
    ///   3. handleDisconnect() (gen N) sees gen N != current gen N+1 → returns
    ///   Without this guard, step 3 would corrupt state and schedule yet another
    ///   connect(), creating two simultaneous URLSessionWebSocketTasks that both
    ///   authenticate — server logs "replacing stale ws device" × N, all zombie
    ///   tasks fail ping together 50 s later.
    private var connectionGeneration: Int = 0

    // MARK: - IOS-E1 — outbound WS media-frame bound
    //
    // Investigated + documented per playbook §IOS-E1 (verify OS buffering
    // semantics BEFORE copying Android's numbers — the two clients do not
    // buffer the same way):
    //
    // Android's W-WSQUEUECAP caps OkHttp's `WebSocket.queueSize()` (bytes
    // OkHttp itself has queued in-process, ahead of the kernel socket) at
    // 16 KB text / 64 KB binary, because OkHttp's queue is DOCUMENTED
    // unbounded otherwise — a stalled link accumulates whole seconds of
    // 50 fps audio in process memory, then floods it to the peer on
    // recovery (the "flush of stale audio" failure mode).
    //
    // `URLSessionWebSocketTask` (checked against its full public API:
    // `send(_:completionHandler:)`, `receive(completionHandler:)`,
    // `sendPing(pongReceiveHandler:)`, `maximumMessageSize`, `closeCode`,
    // `closeReason`) exposes NO equivalent — no `bufferedAmount`, no
    // `queueSize()`, nothing that reports how much this process has queued
    // for send. That is a genuine, confirmed platform gap, not an
    // oversight in this file: Apple never shipped the introspection OkHttp
    // and the browser `WebSocket.bufferedAmount` both have. So "copy
    // Android's byte thresholds" is impossible here even in principle —
    // there is no number to cap.
    //
    // What THIS client already has, verified by reading it rather than
    // assumed:
    //   - `send(type:data:)` / `sendBinary(_:kickType:)` call
    //     `task.send(...)` directly, per frame, with NO app-level queue
    //     array in front of it — unlike OkHttp's in-process queue, there is
    //     nothing here for frames to pile up IN before reaching the OS.
    //   - The inbound pending-binary queue (`_pendingBinaryFrames`) is
    //     already hard-capped at `binRelayPendingMaxFrames` (16).
    //   - Media-frame reconnect kicks are already rate-limited to one per
    //     `mediaKickWindowSec` (3 s, W574c) — a stalled socket doesn't spawn
    //     a reconnect storm.
    //
    // What is NOT verifiable from this process: whether
    // `URLSessionWebSocketTask` itself performs unbounded internal
    // buffering ABOVE the kernel TCP send buffer when `send()` is called
    // faster than the network stack drains it. Apple documents neither a
    // bound nor its absence. Given the explicit instruction not to assume
    // either way, and that no Swift toolchain / device is available in
    // this environment to measure it empirically (playbook §0.5), the
    // closest available PROXY this process CAN observe is: how many of its
    // own media sends are currently awaiting their completion handler. A
    // healthy link drains that to 0-1 well inside one frame period; a
    // stalled one accumulates it. Bounding on that proxy — dropping new
    // media frames (never signaling) once too many are outstanding —
    // reproduces the Android invariant ("a stalled link cannot accumulate
    // unbounded stale media in this process") without pretending to know
    // an OS-internal number this platform does not expose.
    private var outboundMediaFramesInFlight: Int = 0
    private let outboundMediaLock = NSLock()
    /// Cap expressed as a FRAME count, not bytes (see kdoc above — this
    /// process has no buffered-byte number to cap against). At the 20 ms
    /// profile this is ~400 ms of outstanding audio, ~1.2 s at 60 ms —
    /// both well under `PlayoutJitterBuffer.capacityMs` (600 ms) × 2, so a
    /// link stalled long enough to trip this has already exceeded what the
    /// receiver's own buffer could hide, making the drop the honest choice
    /// over accumulating frames the peer could never play out in time
    /// anyway.
    static let maxOutboundMediaFramesInFlight: Int = 20

    /// True (and reserves a slot) iff this media send may proceed; false
    /// means the caller must drop the frame outright. Non-media types
    /// (anything outside `{"audio_frame","video_frame"}`) are ALWAYS
    /// admitted — signaling is never subject to this backpressure gate.
    private func admitOutboundMediaFrame(forType type: String) -> Bool {
        guard type == "audio_frame" || type == "video_frame" else { return true }
        outboundMediaLock.lock()
        defer { outboundMediaLock.unlock() }
        guard outboundMediaFramesInFlight < Self.maxOutboundMediaFramesInFlight else { return false }
        outboundMediaFramesInFlight += 1
        return true
    }

    /// Release the slot reserved by `admitOutboundMediaFrame` once the
    /// send's completion handler fires (success or failure — either way
    /// the OS is done with it and the backlog shrinks).
    private func completeOutboundMediaFrame(forType type: String) {
        guard type == "audio_frame" || type == "video_frame" else { return }
        outboundMediaLock.lock()
        outboundMediaFramesInFlight = max(0, outboundMediaFramesInFlight - 1)
        outboundMediaLock.unlock()
    }

    // MARK: - Binary relay framing (per socket, default OFF)

    /// True iff THIS socket's `authenticated` payload carried `bin_relay: 1`.
    ///
    /// Per SOCKET, never per user and never per call: one user holds several
    /// sockets at once (a watch is a real second socket) and the server fans a
    /// relayed `audio_frame` out to all of them. Keying the wire form by user
    /// or by call is what makes the second device go mute with no error
    /// anywhere.
    ///
    /// Reset to `false` on every `connect()`, `disconnect()`, `forceReconnect()`
    /// and `handleDisconnect()` — a reconnect starts from text and stays there
    /// unless the NEW socket is granted the echo again. Guarded by `lock`.
    private var _binRelayNegotiated: Bool = false

    /// Count of inbound binary frames dropped on this client, for whatever
    /// reason (socket not negotiated, malformed header, no registered audio
    /// handler). Counts FRAMES, never bytes, and describes nothing about the
    /// plaintext. Exists because the failure mode this whole contract is built
    /// to prevent is binary arriving somewhere that silently eats it.
    private var _binaryFramesDropped: UInt64 = 0

    /// Count of inbound binary frames successfully parsed and dispatched.
    /// Frames, never bytes.
    private var _binaryFramesReceived: UInt64 = 0

    /// Per-call terminal latch for the OUTBOUND wire form. See
    /// ``BinaryRelayWireFormLatch`` for the four rules it enforces.
    private let wireFormLatch = BinaryRelayWireFormLatch()

    // MARK: - Binary relay LIVENESS FALLBACK (not disableable)
    //
    // The one precondition this whole feature was built on — "a binary
    // WebSocket frame actually traverses the path" — has NOT been demonstrated.
    // The server sits behind Cloudflare (every request line carries `cf_ray`,
    // logged at cmd/bcrypto-lite/main.go:5724) and Caddy, and contract §7
    // Gate 0 (send a binary frame to wss://voip.bcrypto.com/ws and look for
    // `ws: dropping binary frame`) has never been run — it cannot be, until
    // the server speaks binary at all. Cloudflare proxies binary WS frames in
    // general; that is not the same statement as "on this account, through
    // this tunnel, under this config".
    //
    // So the design does not depend on it being true. Once this socket has
    // negotiated binary, the client watches for inbound audio ACTUALLY
    // ARRIVING — in either form. If none does while our own audio is flowing,
    // the socket goes back to text, tells the server, and says so in a log line
    // shaped to survive the redactor on the way to Loki.
    //
    // This is the relay path: the callers who could not establish P2P, i.e.
    // the worst networks. Silent total audio loss there is the single worst
    // outcome of this feature, and it is the failure this block exists to make
    // impossible. There is deliberately NO flag, capability, remote config or
    // debug-menu entry that can switch it off.
    //
    // The SERVER runs the same watch from its end, and its version needs one
    // thing from us. It disarms on an inbound BINARY packet — proof the path
    // carries binary — and in the receive-first step there is no such packet,
    // because this client receives binary and sends text on purpose. So a
    // client that has seen binary arrive says so once, with `bin_relay: 1` on
    // an ordinary `audio_frame` (see `_binRelayAckPending`). That single field
    // is the difference between a server-side detector and a server-side timer
    // that vetoes every negotiated socket after three seconds.

    /// Wall clock (`timeIntervalSinceReferenceDate`) at which the liveness
    /// watch armed on this socket: the first outbound audio frame sent after
    /// the socket negotiated binary. `0` = not armed.
    private var _binLivenessArmedAt: TimeInterval = 0

    /// Outbound audio frames — any form — sent since the watch armed. The
    /// window means nothing unless we were genuinely transmitting into it.
    private var _binLivenessOutboundFrames: Int = 0

    /// Wall clock of the last inbound `audio_frame` of ANY form (text envelope
    /// or parsed binary packet). Compared against `_binLivenessArmedAt`.
    private var _binLivenessLastInboundAudioAt: TimeInterval = 0

    /// Latched once the fallback fires: this socket is on text for the rest of
    /// its life and no later `authenticated` echo may re-grant it. Cleared only
    /// by `connect()`, i.e. by a genuinely new socket.
    private var _binRelayFallbackTripped: Bool = false

    /// True while this socket owes the server ONE downgrade report — the
    /// integer field `bin_relay: 0`, which rides the next outbound text
    /// `audio_frame` (see ``sendAudioFrameAsText(recipientId:frame:callId:)``).
    ///
    /// Held until it is actually written rather than fired once and forgotten.
    /// Losing it is not cosmetic: the server's `client.binRelay` stays true, it
    /// keeps writing binary into a socket that has stopped ACCEPTING binary
    /// (this client dropped the grant when it tripped), and it keeps expecting a
    /// binary uplink that will never come. Our own watchdog cannot fire twice —
    /// `_binRelayFallbackTripped` latches — so nothing would ever recover that
    /// socket, including on the NEXT call placed over it. Pending survives the
    /// end of a call for exactly that reason, and is cleared only by the write
    /// or by the socket dying (`resetBinLivenessStateLocked`).
    private var _binRelayDowngradeReportPending: Bool = false

    /// True while this socket owes the server ONE AFFIRMATIVE ACK — the integer
    /// field `bin_relay: 1`, riding the next outbound text `audio_frame`. Same
    /// field, same carrier, same shape as the downgrade report above; the value
    /// is what distinguishes them.
    ///
    /// This is the POSITIVE half of the signal, and it exists because the server
    /// cannot otherwise tell "my binary downlink is being eaten" from "this
    /// client only sends text". In the RECEIVE-FIRST rollout step this client
    /// advertises that it can RECEIVE binary and keeps SENDING text, so no
    /// binary uplink ever reaches the server — and the server's own watchdog is
    /// disarmed only by an inbound BINARY packet (`noteInboundBinaryAudio`,
    /// cmd/bcrypto-lite/binary_relay.go:363, ticked by `noteBinaryDelivered`
    /// at :383). Without this ack that watchdog fires on every negotiated
    /// socket after its 3 s window whether or not anything is broken: it stops
    /// being a detector and becomes an unconditional timer, and the metric
    /// built to answer "does binary traverse Cloudflare" reports a fallback on
    /// every call.
    ///
    /// It means exactly ONE thing: "binary frames are reaching me on this
    /// socket." It is not a request, not a negotiation, and it never turns
    /// anything on in either direction — the only input that may grant binary
    /// is still this socket's own `authenticated` payload carrying
    /// `bin_relay: 1` (``isBinRelayGrant``), and the only thing this client
    /// does with the ack is state a fact about traffic that already arrived.
    ///
    /// Armed once, on the first binary packet this socket parses, and cleared
    /// when it is written. If a downgrade report is somehow also pending the
    /// report wins and the ack is dropped — see
    /// ``takeBinRelayNoticeForOutboundFrame()``.
    private var _binRelayAckPending: Bool = false

    /// Latched once the ack has actually gone out. Per SOCKET, once — never per
    /// frame. The statement is about the socket, and repeating it would put a
    /// variable-size field on a constant-rate stream for no added information.
    /// Cleared only by `connect()`, i.e. by a genuinely new socket.
    private var _binRelayAckSent: Bool = false

    /// Inbound binary packets received before this socket's own `authenticated`
    /// echo was parsed — held, not dropped. The server flips its own
    /// `client.binRelay` BEFORE it enqueues `authenticated`
    /// (cmd/bcrypto-lite/main.go:6069-6070 vs the enqueue below it) and its
    /// writer goroutine `select`s over the text `Send` and binary `SendBin`
    /// channels (main.go:5740-5765) — Go picks uniformly at random when both
    /// are ready, so a relayed audio packet can reach the socket BEFORE the
    /// text frame that tells us binary is on. Dropping those is a burst of
    /// lost peer audio on every mid-call reconnect, which is a regression
    /// against today's single-FIFO text path. Bounded two ways; see
    /// ``binRelayPendingMaxFrames`` and ``binRelayPendingHoldMs``.
    private var _pendingBinaryFrames: [Data] = []

    /// Wall clock at which the first frame currently in `_pendingBinaryFrames`
    /// was held. `0` = queue empty.
    private var _pendingBinaryFirstHeldAt: TimeInterval = 0

    /// The SERVER's own veto window, restated here rather than re-derived:
    /// `binRelayLivenessWindow = 3 * time.Second`
    /// (cmd/bcrypto-lite/binary_relay.go). The server watches the same failure
    /// from the other end — it has been writing binary into this socket and has
    /// heard no inbound audio from it in either form — and its veto is the
    /// STRICTLY BETTER repair, because it is bidirectional: it stops the server
    /// sending binary AND stops it expecting a binary uplink, in one move, for
    /// both directions of this socket.
    static let binRelayServerVetoWindowMs: Int = 3000

    /// How long the client will wait for inbound audio, in ms, after binary is
    /// negotiated and its own audio is flowing, before falling back to text.
    ///
    /// Derived, not invented, and in this ORDER — the ordering is the point:
    ///   * ``binRelayServerVetoWindowMs`` (3 s) first, in full. The server gets
    ///     the first move because its veto repairs both legs; a client window
    ///     shorter than the server's pre-empts that repair and leaves the server
    ///     still expecting binary from us. This is why the constant is no longer
    ///     the old 1800 ms.
    ///   * plus `PlayoutJitterBuffer.capacityMs * 3` (1800 ms,
    ///     PlayoutJitterBuffer.swift:60) as the client's own floor: 600 ms is
    ///     the hard cap on how much audio the receiver can hold, so one buffer
    ///     of nothing arriving is already the most the playout path can hide,
    ///     and three is not jitter under any reading — the relay path's jitter
    ///     target is 160 ms (`AudioConstants.jitterBufferMsWsRelay`), so this
    ///     margin alone is over 11× the delay variation the path is built for.
    ///
    /// 4800 ms is ABOVE ``mediaKickWindowSec`` (3 s), which the old 1800 ms
    /// deliberately sat below. That is not a regression: the media kick fires
    /// only on a socket `send()` already considers stale — no inbound frame of
    /// ANY type for `pingIntervalSec * 2` (40 s). A socket that is merely
    /// missing AUDIO still answers pings, so it is never stale on this
    /// timescale and the kick does not race this window at all.
    ///
    /// User-visible worst case: the buffer drains at 600 ms and there is
    /// silence until the server's veto lands (~3 s) or, if it never does, until
    /// 4800 ms — then audio resumes on text. A hiccup, not a dead call.
    static let binRelayLivenessWindowMs: Int =
        BCryptoWebSocketClient.binRelayServerVetoWindowMs
        + PlayoutJitterBuffer.capacityMs * 3

    /// Outbound audio frames required inside the window before its expiry means
    /// anything. Half of what the LONGEST supported frame duration
    /// (`AudioConstants.maxFrameDurationMs`, 60 ms) yields across the window,
    /// so a sender on either the 20 ms or the 60 ms profile clears it with room
    /// to spare, while a client that is not actually transmitting never does
    /// and therefore never trips the fallback on its own silence.
    static let binRelayLivenessMinOutboundFrames: Int =
        BCryptoWebSocketClient.binRelayLivenessWindowMs
        / (2 * AudioConstants.maxFrameDurationMs)

    /// Cap on inbound binary packets held across the `authenticated` race.
    /// Small on purpose: this covers a two-channel write race on one socket,
    /// not an outage.
    static let binRelayPendingMaxFrames: Int = 16

    /// How long a held packet may wait before it is too stale to be worth
    /// playing. `PlayoutJitterBuffer.emergencyWatermarkMs`
    /// (PlayoutJitterBuffer.swift:69) is the deepest the playout buffer will
    /// ever let itself get before it starts dropping audio to catch up; a
    /// packet older than that would be discarded downstream anyway.
    static let binRelayPendingHoldMs: Int = PlayoutJitterBuffer.emergencyWatermarkMs

    /// True iff this socket negotiated binary relay framing. Read-only.
    public var binRelayNegotiated: Bool {
        lock.lock(); defer { lock.unlock() }; return _binRelayNegotiated
    }

    /// Inbound binary frames dropped (frames, not bytes). Read-only diagnostic.
    public var binaryFramesDropped: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _binaryFramesDropped
    }

    /// Inbound binary frames parsed and dispatched (frames, not bytes).
    public var binaryFramesReceived: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _binaryFramesReceived
    }

    /// True once the liveness fallback has fired on this socket. Read-only;
    /// there is no setter and no way to clear it short of a new connection.
    public var binRelayFallbackTripped: Bool {
        lock.lock(); defer { lock.unlock() }; return _binRelayFallbackTripped
    }

    // MARK: - Network path monitoring (always-reachable Phase 2)

    /// Watches for connectivity changes (path → satisfied, WiFi↔cellular
    /// transport switch, wake) and reacts FAST — `forceReconnect()` instead of
    /// waiting up to the `pingIntervalSec + pongTimeoutSec` staleness window to
    /// notice the old socket is dead. Also drives adaptive ping timing.
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.qaudion.ws.pathmonitor", qos: .utility)
    /// Last transport we tuned for / reconnected on. Guards against reacting to
    /// duplicate path updates (NWPathMonitor can fire repeatedly with the same
    /// transport) — only a genuine transport change kicks a reconnect.
    private var lastTransport: NWInterface.InterfaceType?
    /// True once the path is satisfied; used to detect the unsatisfied→satisfied
    /// edge (network came back) so we reconnect immediately on recovery.
    private var lastPathSatisfied: Bool = false
    /// True once the path monitor has delivered its first callback. Guards
    /// `lastPathSatisfied` from being read as "offline" during the brief
    /// window between `init` and NWPathMonitor's first report, when it is
    /// simply unknown rather than actually down — mirrors Android's own
    /// caveat on `shouldParkForOffline()` ("with no monitor wired we never
    /// park"): here the monitor IS always wired, but its first callback is
    /// not synchronous with `start()`.
    private var hasReceivedPathUpdate: Bool = false
    /// IOS-E5 (W-OFFLINEPARK) — true while `handleDisconnect` has parked the
    /// reconnect loop instead of scheduling a backoff attempt, because the
    /// path was strictly `.unsatisfied` (no network transport at all) at
    /// the moment of disconnect. Cleared (and the parked reconnect fired)
    /// the instant `handlePathUpdate` sees the path become satisfied again.
    /// Mirrors Android `WsDispatcher.scheduleReconnect`'s W-OFFLINEPARK
    /// (2026-08-25): every attempt against a genuinely absent network is a
    /// guaranteed instant failure that still costs a DNS/connect attempt
    /// and a radio wake, so parking — rather than walking the normal
    /// exponential-backoff curve — is both cheaper and faster to recover
    /// (ConnectivityMonitor tells us the instant the path returns; a timer
    /// would otherwise still be sitting out its last backoff window).
    private var reconnectParkedForOffline: Bool = false
    /// Debounce wall-clock of the most recent path-triggered reconnect. Anti-
    /// hammer: a flapping interface (WiFi roaming, elevator) can emit many path
    /// updates per second; we kick at most one path-driven reconnect per window.
    private var lastPathReconnectAt: TimeInterval = 0
    // 15 s (was 2 s): a VPN / flaky path can storm NWPathMonitor with
    // satisfied↔unsatisfied edges every ~3 s. With the live-task bail in the
    // handler this is belt-and-suspenders, but it also caps a non-live reconnect
    // to at most one per 15 s so the socket has time to fully (re)authenticate +
    // go fresh between attempts instead of being re-torn-down mid-handshake.
    private let pathReconnectDebounceSec: TimeInterval = 15.0

    public init(config: BackendConfig) {
        self.config = config
        // Pre-negotiation dispatch — server emits these on top of the standard
        // call_offer / call_answer / call_hangup signaling envelopes.
        // See bcrypto-server cmd/bcrypto-lite/main.go pre-negotiation flow.
        registerPreNegotiationHandlers()
        startPathMonitor()
    }

    deinit {
        // Deterministically tear down the socket when this client (and its
        // BCryptoBackendProvider) is released. A transient, per-use provider
        // never calls disconnect(); without this, its URLSessionWebSocketTask
        // → URLSession → delegate retain cycle kept the WebSocket TCP-alive as
        // a zombie until the server's keepalive ping timed it out ~50s later,
        // churning the per-(user,deviceID) slot. Cancelling here closes it at
        // once. No lock: the instance is being deallocated, so no other thread
        // can hold a reference. We deliberately do NOT fire state listeners
        // (transient providers register none; avoids reentrancy during dealloc).
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        pingTimer?.cancel()
        // Cancel the path monitor so its DispatchQueue handler stops firing
        // after this instance is gone (no leak / no use-after-free of self).
        pathMonitor.cancel()
    }

    /// Register the 5 pre-negotiation message handlers on the generic dispatcher.
    /// Each handler parses the envelope `data` and forwards to the matching public
    /// callback property. Called once from init — keeps wiring local to this class.
    private func registerPreNegotiationHandlers() {
        registerHandler(type: "call_processing") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let receiverId = (data["receiver_id"] as? String)
                ?? (data["caller_id"] as? String)
                ?? ""
            self.onCallProcessing?(callId, receiverId)
        }

        registerHandler(type: "call_ready") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let receiverId = (data["receiver_id"] as? String)
                ?? (data["caller_id"] as? String)
                ?? ""
            let deviceId = data["device_id"] as? String
            self.onCallReady?(callId, receiverId, deviceId)
        }

        registerHandler(type: "call_ring") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let callerId = (data["caller_id"] as? String) ?? ""
            self.onCallRing?(callId, callerId)
        }

        registerHandler(type: "call_peer_offline") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let recipientId = (data["recipient_id"] as? String) ?? ""
            self.onCallPeerOffline?(callId, recipientId)
        }

        // call_busy (caller side) — recipient is already in an answered call.
        // Same envelope shape as call_peer_offline: {call_id, recipient_id}.
        registerHandler(type: "call_busy") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let recipientId = (data["recipient_id"] as? String) ?? ""
            self.onCallBusy?(callId, recipientId)
        }

        registerHandler(type: "call_cancel") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let reason = data["reason"] as? String
            self.onCallCancel?(callId, reason)
        }

        // call_accepted (callee→caller) — real user accept, WIRE_SPEC §3.5.
        // Server stamps sender_id before relaying, same envelope class as
        // call_processing/call_ready above.
        registerHandler(type: "call_accepted") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let senderId = (data["sender_id"] as? String) ?? (data["caller_id"] as? String) ?? ""
            self.onCallAccepted?(callId, senderId)
        }

        // W536 — call_upgrade_request (caller→callee). Same wire shape
        // as desktop's CallUpgradeRequestData: { call_id, sdp,
        // sender_id?, from? }. Android's WsCodec parses sender_id; the
        // desktop server normalises to `sender_id`. Fall back to `from`
        // for any legacy variant. recipient_id is not delivered to
        // this client (the server already routed by it).
        registerHandler(type: "call_upgrade_request") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String,
                  let sdp = data["sdp"] as? String else { return }
            let senderId = (data["sender_id"] as? String)
                ?? (data["from"] as? String)
                ?? ""
            // media-consent v1: absent ⇒ camera (consent dialog default).
            let media = (data["media"] as? String) ?? "camera"
            self.onCallUpgradeRequest?(callId, senderId, sdp, media)
        }

        // W536 — call_upgrade_response (callee→caller).
        // GAP-10 fix (2026-07-07, cross-platform matrix audit): `accepted`
        // used to default to true when the peer omitted the field (legacy
        // desktop builds < commit a13b that always implied accepted) — a
        // malformed/spoofed response with no `accepted` key was silently
        // treated as an accept. All shipping clients (Android, Desktop,
        // iOS) now always send the field explicitly, so the no-legacy
        // safe default flips to false. senderId extraction mirrors the
        // call_upgrade_request handler above, feeding AppState's new
        // sender-validation guard in handleUpgradeResponse.
        registerHandler(type: "call_upgrade_response") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let senderId = (data["sender_id"] as? String)
                ?? (data["from"] as? String)
                ?? ""
            let sdp = (data["sdp"] as? String) ?? ""
            let accepted = (data["accepted"] as? Bool) ?? false
            self.onCallUpgradeResponse?(callId, senderId, accepted, sdp)
        }

        // call_upgrade_intent (peer→us) — see onCallUpgradeIntent doc /
        // Android WsEvent.CallUpgradeIntent kdoc for the full rationale.
        // No `sdp` field on the wire; senderId/media extraction mirrors the
        // call_upgrade_request handler above.
        registerHandler(type: "call_upgrade_intent") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let senderId = (data["sender_id"] as? String)
                ?? (data["from"] as? String)
                ?? ""
            // media-consent v1: absent ⇒ camera (consent dialog default).
            let media = (data["media"] as? String) ?? "camera"
            self.onCallUpgradeIntent?(callId, senderId, media)
        }

        // WIRE_SPEC §8.7 (v1.1) — call_media_ready (receiver→sender).
        // Same envelope class as call_upgrade_*: the server stamps
        // `sender_id` and relays transparently. `from` fallback mirrors
        // the call_upgrade_request handler above.
        registerHandler(type: "call_media_ready") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let senderId = (data["sender_id"] as? String)
                ?? (data["from"] as? String)
                ?? ""
            let mid = (data["mid"] as? String) ?? ""
            let keyEpoch = (data["key_epoch"] as? Int) ?? 0
            let dir = (data["dir"] as? String) ?? "recv"
            self.onCallMediaReady?(callId, senderId, mid, keyEpoch, dir)
        }

        // WIRE_SPEC §8.7 (v1.1) — video_keyframe_request (receiver→sender).
        registerHandler(type: "video_keyframe_request") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let senderId = (data["sender_id"] as? String)
                ?? (data["from"] as? String)
                ?? ""
            self.onVideoKeyframeRequest?(callId, senderId)
        }

        // WIRE_SPEC §8.1 — call_video_state (either direction). Same
        // envelope class as call_upgrade_*/call_media_ready: the server
        // stamps `sender_id` and relays transparently. `from` fallback
        // mirrors the call_upgrade_request handler above.
        registerHandler(type: "call_video_state") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            // sender_id/from is available on the envelope but the
            // onCallVideoState callback (mirroring the contract used by
            // the AppState wiring) only needs callId + paused — the
            // active-call filter happens downstream via getActiveCallId().
            let paused = (data["paused"] as? Bool) ?? false
            // WIRE_SPEC §8.9 — nil when the peer predates the beacon.
            let seq = data["seq"] as? Int
            self.onCallVideoState?(callId, paused, seq)
        }
    }

    public var state: ConnectionState { lock.lock(); defer { lock.unlock() }; return _state }

    /// Diagnostic only. See `_lastDisconnectReason` for why this exists.
    public var lastDisconnectReason: String? { lock.lock(); defer { lock.unlock() }; return _lastDisconnectReason }

    /// - Parameter viaSocksPort: when set, routes the WS connection through a
    ///   local loopback SOCKS5 proxy on `127.0.0.1:<port>` instead of dialing
    ///   directly — same shape `TorObfsTransport.connectViaSocks(port:)`
    ///   already uses for Tor. Additive, second backend (RealityManager);
    ///   default `nil` preserves today's direct-dial behavior unchanged.
    ///   Caller is responsible for having the tunnel already up (e.g.
    ///   `await RealityManager.shared.start(params:)`) before passing its port.
    public func connect(viaSocksPort socksPort: Int? = nil) {
        lock.lock()
        guard _state == .disconnected else { lock.unlock(); return }
        _state = .connecting
        currentSocksPort = socksPort
        // IOS-E5 — any explicit connect() (forceReconnect, willEnterForeground,
        // the un-park call from handlePathUpdate itself) takes ownership away
        // from a park, exactly like it cancels a timer-based backoff retry.
        reconnectParkedForOffline = false
        // A NEW socket has negotiated nothing. The binary wire form is a
        // property of one connection and never survives it: no cached value,
        // no inference, no carry-over. The flag can only go true again when
        // this socket's own `authenticated` payload grants it.
        _binRelayNegotiated = false
        resetBinLivenessStateLocked()
        // The fallback latch is per SOCKET, so a genuinely new connection is
        // the one and only thing that clears it.
        _binRelayFallbackTripped = false
        // Same rule for the affirmative ack: "binary reaches me" is a claim
        // about ONE socket, so the replacement socket has never made it and
        // must be able to make it again once it too sees a binary frame.
        _binRelayAckSent = false
        // Bump generation so any zombie receiveLoop or handleDisconnect closure
        // that fires after this point sees a stale generation and returns early.
        connectionGeneration &+= 1
        let gen = connectionGeneration
        // Capture and nil out any lingering task — this can happen when
        // handleDisconnect fires while a previous connect() is still in flight
        // (e.g. TLS handshake stall). The old task is cancelled below, outside
        // the lock, to avoid lock inversion with URLSession internals.
        let oldTask = webSocketTask
        webSocketTask = nil
        let listeners = stateListeners
        lock.unlock()

        // Cancel the old task AFTER releasing the lock.
        oldTask?.cancel(with: .goingAway, reason: nil)
        listeners.forEach { $0(.connecting) }

        guard let url = URL(string: config.serverUrl.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + "/ws") else { return }

        // VoIP-grade session configuration:
        //   - timeoutIntervalForRequest = 0  → no read timeout (server's
        //     keepalive governs the connection; without this the default
        //     60 s read timeout fires on quiet calls and emits EOF).
        //   - waitsForConnectivity = true    → queue send() calls while
        //     transitioning between WiFi / LTE instead of failing fast.
        //   - These settings survive iOS background network suspension
        //     better than URLSession.shared defaults, which combine with
        //     VoIP background mode to keep the WS alive during active calls.
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 0   // no read timeout
        sessionConfig.waitsForConnectivity = true
        // Mark this traffic as call-signaling so iOS gives it priority routing
        // and (with the voip UIBackgroundMode) keeps the socket alive longer
        // when the app is in background.
        sessionConfig.networkServiceType = .callSignaling

        // Reality censorship-bypass path (additive, default off — see
        // RealityManager.swift / bcrypto-server's CENSORSHIP_RESISTANT_
        // TRANSPORT_DESIGN.md §4.4). The WSS handshake + cert pinning below
        // runs UNCHANGED through this tunnel — nothing above the transport
        // layer needs to know Reality exists, same as Tor's SOCKS5 override.
        if let socksPort {
            sessionConfig.connectionProxyDictionary = [
                "SOCKSEnable": true,
                "SOCKSProxy": "127.0.0.1",
                "SOCKSPort": socksPort
            ] as [String: Any]
        }

        // SECURITY C-6 / H-1 / H-5 — pick the TLS-challenge mode the same
        // way BCryptoRestClient does, and route the WS-open event so the
        // auth token is sent ONLY after the upgrade completes (H-5):
        //   - DEBUG + acceptSelfSignedCerts → trust-all (local dev only)
        //   - certPinSha256B64 set          → reuse the REST client's
        //     DER-SHA256 CertPinningDelegate (was: NO pinning at all)
        //   - otherwise                     → system default TLS chain
        let challengeMode: WSSessionDelegate.ChallengeMode
        #if DEBUG
        if config.acceptSelfSignedCerts {
            challengeMode = .trustAll
        } else if let pin = config.certPinSha256B64 {
            challengeMode = .pinned(CertPinningDelegate(pinB64: pin))
        } else {
            challengeMode = .systemDefault
        }
        #else
        if let pin = config.certPinSha256B64 {
            challengeMode = .pinned(CertPinningDelegate(pinB64: pin))
        } else {
            challengeMode = .systemDefault
        }
        #endif

        // H-5: send the auth frame from the open callback, not right
        // after resume(). The previous code called authenticate() before
        // the WS upgrade completed, so the `authenticate` frame could be
        // queued on (or dropped by) a socket that had not finished the
        // HTTP→WS handshake — the server then saw an unauthenticated
        // socket and silently dropped subsequent frames.
        let pendingToken = config.accessToken
        let delegate = WSSessionDelegate(mode: challengeMode) { [weak self] in
            guard let self = self, let token = pendingToken else { return }
            self.authenticate(token: token)
        }
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)

        lock.lock()
        sessionDelegate = delegate
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        lock.unlock()
        task.resume()
        receiveLoop(generation: gen)
    }

    public func disconnect() {
        lock.lock()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        // Release the session delegate — a fresh one is built per connect().
        sessionDelegate = nil
        _state = .disconnected
        _lastDisconnectReason = "explicit disconnect()"
        // The socket is gone; so is anything it negotiated.
        _binRelayNegotiated = false
        resetBinLivenessStateLocked()
        reconnectAttempt = 0
        pingTimer?.cancel()
        pingTimer = nil
        let listeners = stateListeners
        lock.unlock()
        listeners.forEach { $0(.disconnected) }
    }

    /// Tear down any existing task and trigger a fresh `connect()`. Idempotent
    /// while a reconnect is already in flight (debounced via `reconnectInFlight`)
    /// so a burst of dropped sends does not spawn parallel connect attempts.
    ///
    /// Used by:
    ///   - `send(...)` when `webSocketTask == nil` (control envelopes only)
    ///   - `ensureAuthenticated(...)` when staleness is detected
    ///   - `AppState.willEnterForeground` after iOS resumes the app
    public func forceReconnect() {
        lock.lock()
        if reconnectInFlight {
            lock.unlock()
            return
        }
        reconnectInFlight = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        _state = .disconnected
        _lastDisconnectReason = "forceReconnect()"
        // Same rule as connect()/disconnect(): the replacement socket starts
        // from text and only its own echo can grant binary again.
        _binRelayNegotiated = false
        resetBinLivenessStateLocked()
        pingTimer?.cancel()
        pingTimer = nil
        // NOTE: deliberately do NOT reset reconnectAttempt here. Resetting it
        // defeated the exponential backoff: a call_offer/message that found the
        // socket momentarily non-fresh forceReconnect()ed with a 0-backoff, and
        // combined with the server replacing the prior same-deviceID socket this
        // produced a fast "replacing stale ws device" reconnect storm during
        // calls. Letting the attempt count carry over lets handleDisconnect's
        // backoff actually throttle a runaway loop; a genuinely successful
        // reconnect still resets it to 0 in handleMessage("authenticated").
        let listeners = stateListeners
        let socksPort = currentSocksPort
        lock.unlock()
        listeners.forEach { $0(.disconnected) }
        connect(viaSocksPort: socksPort)

        // Failsafe (per OpenRouter glm-5.1 review 2026-05-08 Bug 1):
        // if `connect()` opens a task that NEVER authenticates AND NEVER
        // delivers a `receive` failure (e.g. silent TCP timeout on iOS
        // when the carrier dropped the connection mid-DNS), neither
        // `handleMessage("authenticated")` nor `handleDisconnect()` will
        // fire — `reconnectInFlight` would stay true forever and brick
        // every future reconnect attempt. Schedule a guard that clears
        // the flag after 10 s if we haven't progressed past `.connecting`.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.expireReconnectGuardIfStuck()
        }
    }

    /// Clear `reconnectInFlight` if the most recent `forceReconnect()` is
    /// still pending after the failsafe deadline. Called from a delayed
    /// dispatch scheduled by `forceReconnect()` itself. Idempotent.
    private func expireReconnectGuardIfStuck() {
        lock.lock()
        // Only clear if we never reached .authenticated AND no other
        // path already cleared the flag (e.g. handleDisconnect fired).
        if reconnectInFlight && _state != .authenticated {
            reconnectInFlight = false
        }
        lock.unlock()
    }

    /// Block the caller (asynchronously) until the WS is `.authenticated` AND
    /// the underlying task is non-nil AND inbound traffic is recent. Returns
    /// `true` on success, `false` on timeout. Safe to call from `MainActor` —
    /// the polling Task does not require main-thread access.
    ///
    /// This is the gate the call-setup path (`sendCallOffer*`) uses to avoid
    /// the silent "DROPPED" + CallKit-flash failure mode where iOS suspended
    /// the task in background but the local state machine still believes
    /// itself authenticated.
    public func ensureAuthenticated(timeoutSec: TimeInterval = 5) async -> Bool {
        // Fast path: the connection is fresh.
        if isFreshlyAuthenticated() {
            return true
        }
        // If we are authenticated with a LIVE task but merely "stale" (no inbound
        // JSON within the freshness window — usually just a delayed/OS-throttled
        // keepalive pong, NOT a dead socket), do NOT tear it down. Probe it with a
        // ping and wait briefly for the pong to refresh liveness. Tearing a live
        // socket down on every call_offer/message is what drove the same-deviceID
        // "replacing stale ws device" reconnect storm during calls: each teardown
        // reopened the persistent socket, the server replaced the previous one,
        // and the cycle repeated. Only fall through to forceReconnect() if the
        // probe gets no pong (genuinely dead / OS-suspended ghost socket).
        // Single overall budget so a probe + a reconnect never exceed timeoutSec.
        let deadline = Date().addingTimeInterval(timeoutSec)
        if hasLiveAuthenticatedTask() {
            send(type: "ping", data: [:])
            // A healthy socket pongs in well under a second; cap the probe at 1 s
            // (bounded by the overall deadline) before deciding it's a ghost.
            let probeDeadline = min(Date().addingTimeInterval(1.0), deadline)
            while Date() < probeDeadline {
                if isFreshlyAuthenticated() {
                    return true
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        // Genuinely disconnected (no task) or the live-socket probe got no pong —
        // force a clean reconnect, then poll until authenticated or the deadline.
        forceReconnect()
        while Date() < deadline {
            if isFreshlyAuthenticated() {
                return true
            }
            // 100 ms polling — a 5 s budget covers TLS handshake + JWT auth
            // round-trip on a slow LTE link without busy-looping.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// True iff authenticated with a non-nil task, regardless of inbound recency.
    /// Lets ensureAuthenticated() distinguish a live-but-idle socket (probe it
    /// with a ping) from a genuinely disconnected one (reconnect). Splitting this
    /// out of isFreshlyAuthenticated() is what stops a live socket from being
    /// needlessly torn down on every call.
    private func hasLiveAuthenticatedTask() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _state == .authenticated && webSocketTask != nil
    }

    /// True iff the WS is authenticated, the task pointer is non-nil, and the
    /// last inbound frame was within `pingIntervalSec * 2` seconds. The latter
    /// guards against the iOS "suspended-task ghost" where state still says
    /// authenticated but no pong has arrived for several minutes.
    private func isFreshlyAuthenticated() -> Bool {
        lock.lock()
        let st = _state
        let hasTask = (webSocketTask != nil)
        let lastInbound = lastInboundAt
        lock.unlock()
        guard st == .authenticated, hasTask else { return false }
        // lastInboundAt == 0 means we never received anything — not fresh.
        if lastInbound == 0 { return false }
        let age = Date().timeIntervalSinceReferenceDate - lastInbound
        return age < (pingIntervalSec * 2)
    }

    /// Send a JSON envelope matching the server's `Envelope { type, data, id }` schema
    /// (internal/signaling/messages.go). `id` is a UUID used for request/response
    /// correlation (e.g. pairing a server `pong` with the triggering `ping`).
    public func send(type: String, data: [String: Any]) {
        let message: [String: Any] = [
            "type": type,
            "data": data,
            "id": UUID().uuidString
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        // W419 — log dispatch attempt + capture send errors. The previous
        // `{ _ in }` swallowed every transmission failure: if the WS was
        // suspended (app backgrounded) or already torn down, sends became
        // silent no-ops and the server never knew a hangup was attempted.
        // This was the root cause of the Android "ghost call" bug — iOS
        // user pressed end, sendHangup fired into the void, server only
        // detected the WS EOF 41s later as a generic disconnect.
        //
        // 2026-05-08 hardening (per OpenRouter glm-5.1 review Bug 2 + 3):
        //   - read `webSocketTask` UNDER the lock (was a Swift-level
        //     data race against forceReconnect's write path)
        //   - kick a reconnect ALSO when the task is non-nil but stale
        //     (no inbound traffic in pingInterval*2 — iOS suspended the
        //     task without firing a delegate callback, so neither nil
        //     nor a receive failure ever surfaced)
        lock.lock()
        let task = webSocketTask
        lock.unlock()
        let stale = !isFreshlyAuthenticated()
        if task == nil {
            print("[BCryptoWS] send(\(type)) DROPPED — webSocketTask is nil (WS not connected)")
            // Recovery: kick a reconnect so the NEXT send has a chance, but
            // ONLY for control envelopes. audio_frame / video_frame run at
            // ~50 fps and would each spawn a parallel reconnect storm — the
            // call-setup path (sendCallOffer*) calls `ensureAuthenticated()`
            // before this code path is reached, so a control-envelope kick
            // here is the safety net for less critical messages.
            if Self.shouldKickReconnect(forType: type) {
                forceReconnect()
            }
            return
        }
        if stale && Self.shouldKickReconnect(forType: type) {
            print("[BCryptoWS] send(\(type)) STALE socket — kicking reconnect; attempting send anyway (best-effort)")
            forceReconnect()
            // Fall through and try the send — `task.send` will report the
            // error in its completion if the cancelled task rejects it.
        }
        // IOS-E1 — media-only backpressure gate (see the kdoc block above
        // `outboundMediaFramesInFlight`). No-op for non-media types.
        guard admitOutboundMediaFrame(forType: type) else {
            // Verified against scripts/ship-ios-logs.py's own redact_body
            // (iOS log-line rule) — "kind=audio"/"kind=video" survives the
            // shipper's structured-shape gate intact; "type=audio_frame"
            // (underscore-joined) gets blob-redacted and "send(audio_frame)
            // DROPPED outbound media backlog…" (prose-heavy) is DROPPED
            // whole, both re-verified 2026-08-25.
            print("[BCryptoWS] media send drop kind=\(type.hasPrefix("audio") ? "audio" : "video") cap=\(Self.maxOutboundMediaFramesInFlight)")
            return
        }
        task?.send(.string(jsonString)) { [weak self] error in
            self?.completeOutboundMediaFrame(forType: type)
            if let error = error {
                print("[BCryptoWS] send(\(type)) FAILED: \(error.localizedDescription)")
            }
        }
    }

    /// Whitelist of message types that warrant a reconnect kick when the
    /// task is gone. Real-time media frames (audio/video) and outbound
    /// pings are excluded to avoid reconnect storms — those callers either
    /// tolerate the drop or run alongside a control envelope that already
    /// triggered recovery.
    ///
    /// CRITICAL: `authenticate` MUST be excluded. It is the handshake frame
    /// sent from `onOpen()` on a freshly-upgraded socket whose state is still
    /// `.connecting` (NOT `.authenticated`). The staleness check in `send()`
    /// (`!isFreshlyAuthenticated()`) is therefore ALWAYS true for the auth
    /// frame — gating it on "is this socket already authenticated?" is
    /// circular and self-defeating: it would `forceReconnect()` and cancel
    /// the very task carrying the auth frame, producing a connect→auth→
    /// self-cancel→reconnect storm (observed server-side as a new `/ws`
    /// every 1-2s, client-side as "STALE socket … FAILED: cancelled").
    /// That storm left the device permanently un-authenticated → shown
    /// offline → unable to send call_answer / PQC ACCEPT / audio frames.
    private static func shouldKickReconnect(forType type: String) -> Bool {
        switch type {
        case "audio_frame", "video_frame":
            // W574c — media frames DO kick a reconnect, but rate-limited to
            // one kick per window instead of the blanket exclusion. The old
            // `return false` meant a call whose socket died mid-stream
            // dropped EVERY remaining frame silently with no recovery:
            // call 382c46bb lost 2244/2245 TX frames (tx_enc=2245 client
            // telemetry vs relayed=1 server-side) because nothing on the
            // 50 fps media path was allowed to trigger reconnection. A 3 s
            // rate limit preserves the anti-storm property (≤1 kick / 3 s
            // instead of 50/s) while restoring in-call self-healing.
            mediaKickLock.lock()
            defer { mediaKickLock.unlock() }
            let now = Date()
            if now.timeIntervalSince(lastMediaKick) > mediaKickWindowSec {
                lastMediaKick = now
                return true
            }
            return false
        case "ping", "authenticate": return false
        default: return true
        }
    }

    /// W574c — rate limiter state for media-frame reconnect kicks.
    private static var lastMediaKick = Date.distantPast
    private static let mediaKickLock = NSLock()

    /// The W574c window, named rather than restated. Same 3 s it has always
    /// been — this is only so ``binRelayLivenessWindowMs`` can be bounded
    /// against the real number instead of a copy of it.
    static let mediaKickWindowSec: TimeInterval = 3.0

    public func sendOpaqueMessage(recipientId: String, payload: Data) {
        send(type: "opaque_message", data: ["recipient_id": recipientId, "data": payload.base64EncodedString()])
    }

    /// Ship a LITERAL UTF-8 string verbatim in `opaque_message.data` (NOT
    /// base64-wrapped). Used for the Android JSON HandshakeBundle wire
    /// format which is `"<callId>|<JSON>"` — Android's WsCodec reads
    /// `data["data"] as String` and the dispatcher splits on `|`. If we
    /// went through `sendOpaqueMessage(payload: Data)` the Data would be
    /// base64-encoded and Android's `dispatch()` would reject the
    /// envelope as malformed because there is no `|` in the base64
    /// alphabet of the wrapped payload. WIRE_SPEC.md §3.1.
    public func sendOpaqueMessageString(recipientId: String, payload: String) {
        send(type: "opaque_message", data: ["recipient_id": recipientId, "data": payload])
    }

    /// W525 — `callId` is OPTIONAL only for backwards compatibility with
    /// callers that haven't been updated yet. In production it MUST be
    /// passed: Android's `BcryptoWsFrameRelayTransport.parseRawFrame`
    /// and the Desktop `MediaTransport.socketHandler` both filter
    /// inbound `audio_frame`/`video_frame` envelopes by `call_id` —
    /// if it's missing the frame is silently dropped, producing
    /// asymmetric one-way audio (Android→iOS works because iOS doesn't
    /// filter; iOS→Android dies because Android does).
    public func sendAudioFrame(recipientId: String, frame: Data, callId: String? = nil) {
        // Wire form is resolved ONCE per call and held (see
        // BinaryRelayWireFormLatch). Both compile-time switches are tested
        // before anything else, so a shipped build with them off never reads
        // the socket flag, never touches the lock here, and behaves identically
        // to the code that shipped before binary framing existed — it costs two
        // Bool tests against `let false` constants. The latch re-checks the
        // send switch — one source of truth, checked twice.
        var form = BinaryRelayWireFormLatch.WireForm.text
        if CallCapabilities.binRelaySendEnabled {
            form = wireFormLatch.resolve(
                callId: callId,
                socketNegotiated: binRelayNegotiated,
                sendEnabled: CallCapabilities.binRelaySendEnabled
            )
        }
        // LIVENESS WATCH. Deliberately OUTSIDE the `binRelaySendEnabled` test
        // above and outside the switch below: during the receive-first rollout
        // step this client negotiates binary and still SENDS text, and that is
        // precisely the configuration in which a path that eats binary leaves
        // us stone deaf while our own uplink looks perfect. The watch keys off
        // "this socket negotiated binary" and "our audio is flowing", never off
        // which form we happen to be sending.
        //
        // The compile-time test here is NOT a way to switch the fallback off:
        // with `binRelayReceiveEnabled` false this build never asks for binary,
        // so no socket can ever negotiate it and there is nothing to fall back
        // from. It exists so a shipped build folds this whole block away and
        // the 50 fps send path keeps costing exactly what it cost before this
        // feature existed. Whenever binary CAN happen, the watch runs, and no
        // flag, capability, remote config or debug entry can stop it.
        if CallCapabilities.binRelayReceiveEnabled {
            noteOutboundAudioForLiveness()
        }
        switch form {
        case .binary:
            // The latch only ever returns .binary for a call id the encoder
            // also accepts, so a nil here means the frame length fell outside
            // [1, 32750] — unreachable for a sealed audio frame (187 / 323).
            //
            // If it somehow happens, DROP this one frame. The previous
            // behaviour here (ship it as text) put one 479-byte text packet in
            // the middle of a stream of 205-byte binary ones, with a WebSocket
            // opcode change to match: both are visible to a passive observer,
            // and the constant-rate property is the entire reason this header
            // is fixed-size. Losing one 20 ms frame costs one concealment; a
            // size flip costs the property.
            guard let cid = callId,
                  let packet = BinaryRelayFraming.encodeAudio(callId: cid, frame: frame) else {
                noteBinaryDrop(.encodeRefused)
                return
            }
            sendBinary(packet, kickType: "audio_frame")
        case .text:
            sendAudioFrameAsText(recipientId: recipientId, frame: frame, callId: callId)
        }
    }

    /// Arm (or advance) the liveness watch for one outbound audio frame, and
    /// trip the fallback if the window has expired with nothing inbound.
    ///
    /// Runs on the audio TX queue at frame rate, so it does exactly one lock
    /// acquisition in the common case and no allocation.
    private func noteOutboundAudioForLiveness() {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        guard _binRelayNegotiated, !_binRelayFallbackTripped else {
            // Not negotiated (or already fallen back): nothing to watch.
            lock.unlock()
            return
        }
        if _binLivenessArmedAt == 0 {
            _binLivenessArmedAt = now
            _binLivenessOutboundFrames = 1
            lock.unlock()
            return
        }
        _binLivenessOutboundFrames &+= 1
        // Any inbound audio at all, in any form, since we armed ⇒ the path
        // works. Re-arm from now so the watch keeps covering the call rather
        // than being satisfied once and never looking again.
        if _binLivenessLastInboundAudioAt > _binLivenessArmedAt {
            _binLivenessArmedAt = now
            _binLivenessOutboundFrames = 1
            lock.unlock()
            return
        }
        let elapsedMs = (now - _binLivenessArmedAt) * 1000
        guard elapsedMs >= Double(Self.binRelayLivenessWindowMs),
              _binLivenessOutboundFrames >= Self.binRelayLivenessMinOutboundFrames,
              webSocketTask != nil else {
            lock.unlock()
            return
        }
        // TRIP. Text for the rest of this socket; only a new connection can
        // undo it, and nothing in configuration can prevent it.
        _binRelayNegotiated = false
        _binRelayFallbackTripped = true
        let sent = _binLivenessOutboundFrames
        let dropped = _binaryFramesDropped
        let rx = _binaryFramesReceived
        let heldCount = _pendingBinaryFrames.count
        resetBinLivenessStateLocked()
        // AFTER the reset, which clears this flag along with the rest of the
        // watch state. The report is what makes the trip more than half a fix:
        // without it this socket has stopped accepting binary while the server
        // still believes binary works, and no later event on either side can
        // put that right.
        _binRelayDowngradeReportPending = true
        lock.unlock()

        // Loud, and shaped to survive the trip to Loki. The stdout tee records
        // every `print` at INFO with tag "stdout" (RuntimeLogSink.swift, the
        // W416 block; "stdout" is in the shipper's TAG_SCOPE_PREFIXES at
        // ship-ios-logs.py:569), and the shipper's redactor is a fail-closed
        // allow-list: integer `k=v` pairs survive intact, while an unrecognised
        // prose token can cost the WHOLE line, not just that word.
        //
        // This exact wording was executed against `scripts/ship-ios-logs.py`'s
        // own `redact_body` and comes back unchanged. Do NOT reword it without
        // re-running that check — "binrelay liveness fallback to text" and
        // "binrelay fallback text" both come back dropped, i.e. invisible, and
        // an invisible fallback is the failure this whole block exists to
        // prevent being invisible. `binfb` is the WHICH-SIDE code: 1 = our own
        // watchdog fired, 2 = the server told us (see
        // ``honourServerBinRelayVeto``). The word "veto" does NOT survive the
        // redactor, so the distinction is an integer, not a word — re-verified
        // 2026-08-10 against the same `redact_body`. `rpt=1` means the
        // downgrade report is QUEUED for the next outbound audio frame, not
        // that it is already on the wire; `rpt=0` (the server-told case) means
        // there is nothing to report back.
        let line: String = "[BCryptoWS] binrelay fallback to text" +
            " binfb=1 rpt=1 win=" + String(Self.binRelayLivenessWindowMs) +
            " sent=" + String(sent) +
            " rx=" + String(rx) +
            " drop=" + String(dropped) +
            " held=" + String(heldCount)
        print(line)

        // Telling the server is NOT done here. It is one integer field,
        // `bin_relay: 0`, on the next outbound `audio_frame` — the frame this
        // client is already sending at 50 fps — parsed by the server at
        // cmd/bcrypto-lite/main.go:6294 into `vetoBinRelay`, which is the same
        // terminal downgrade its own watchdog performs. That is the ONE
        // spelling of this signal (it is also honoured on `authenticate`,
        // main.go:6123); the `bin_relay_fallback` message type this used to
        // send existed nowhere on the server — the WS switch has no `default:`
        // case, so it was read by nothing, and a signal read by nothing is the
        // same as no signal.
        //
        // It rides an existing frame rather than a re-`authenticate` because
        // this has to be sendable at the exact moment audio is already broken:
        // a re-auth on a live socket re-registers the client, re-broadcasts
        // presence, may rotate the token pair and re-runs pending delivery.
        // Far too heavy for that moment.
    }

    /// Record that inbound audio arrived, in whatever form. Caller must NOT
    /// hold `lock`.
    private func noteInboundAudioForLiveness() {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        _binLivenessLastInboundAudioAt = now
        lock.unlock()
    }

    /// Clear the liveness watch and anything held for the echo race. Caller
    /// holds `lock`. Deliberately does NOT clear `_binRelayFallbackTripped` —
    /// that is per socket and only `connect()` resets it.
    ///
    /// It DOES clear the pending downgrade report, because every caller other
    /// than the trip itself is a socket that is going away (`connect`,
    /// `disconnect`, `forceReconnect`, `handleDisconnect`) or a server veto: in
    /// all of those there is nothing left to report — the server's own
    /// `client.binRelay` dies with the socket, and a veto means the server is
    /// the one telling US. The trip therefore sets the flag AFTER calling this.
    ///
    /// It clears the pending AFFIRMATIVE ACK for the same reason and in the
    /// same breath: a socket that is going away has nobody to tell, and on the
    /// two paths that stay (our own trip, the server's veto) this socket is now
    /// on text for the rest of its life — an ack claiming binary reaches it
    /// would contradict the downgrade riding the very next frame. It does NOT
    /// clear `_binRelayAckSent`, which is per socket like the fallback latch.
    private func resetBinLivenessStateLocked() {
        _binLivenessArmedAt = 0
        _binLivenessOutboundFrames = 0
        _binLivenessLastInboundAudioAt = 0
        _pendingBinaryFrames.removeAll(keepingCapacity: false)
        _pendingBinaryFirstHeldAt = 0
        _binRelayDowngradeReportPending = false
        _binRelayAckPending = false
    }

    /// Arm the affirmative ack. Caller HOLDS `lock`.
    ///
    /// Folded into a lock the caller already owns rather than taking its own:
    /// this runs on the inbound audio path at frame rate, and after the first
    /// frame every call is three Bool reads.
    ///
    /// Gated on the fallback latch: a socket already back on text must not
    /// claim binary reaches it. Nothing here can put a socket ON binary.
    private func armBinRelayAckLocked() {
        guard !_binRelayAckSent,
              !_binRelayAckPending,
              !_binRelayFallbackTripped else { return }
        _binRelayAckPending = true
    }

    /// Lock-taking wrapper around ``armBinRelayAckLocked()``. The seam the
    /// tests drive, so the ordering rules can be exercised without opening a
    /// socket; the live path arms inside ``dispatchBinaryAudio(_:)``'s existing
    /// lock acquisition instead.
    func noteInboundBinaryFrameForAck() {
        lock.lock()
        armBinRelayAckLocked()
        lock.unlock()
    }

    /// Take the ONE `bin_relay` transport notice this socket owes, if any, for
    /// exactly one outbound text `audio_frame`. Returns the integer to place on
    /// that frame, or `nil` when nothing is owed — which is every frame of a
    /// healthy socket after the first.
    ///
    /// The two values are mutually exclusive by construction, and the DOWNGRADE
    /// WINS. Both can be pending at once — a socket can receive binary (arming
    /// the ack), then go deaf and trip the liveness watch before the ack has
    /// found a text frame to ride — and in that order the ack is stale: the
    /// client is already back on text and the server must stop writing binary
    /// to it. Sending `1` there would tell the server the exact opposite of the
    /// repair, on the one frame that had to carry the repair.
    ///
    /// One lock acquisition, on the 50 fps send path, exactly as the
    /// take-and-clear it replaces.
    func takeBinRelayNoticeForOutboundFrame() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let owesDowngrade = _binRelayDowngradeReportPending
        let owesAck = _binRelayAckPending
        if owesDowngrade {
            // The downgrade consumes the ack with it: a stale ack outliving the
            // trip would tell the server the opposite of the fix.
            _binRelayDowngradeReportPending = false
            _binRelayAckPending = false
        } else if owesAck {
            _binRelayAckPending = false
            _binRelayAckSent = true
        }
        return Self.binRelayNotice(owesDowngrade: owesDowngrade, owesAck: owesAck)
    }

    /// The precedence rule as a pure function of what is owed, so it can be
    /// pinned by a test without a socket, a server or a mutable client.
    /// `nil` = the frame carries no `bin_relay` key at all, which is every
    /// frame of a healthy socket after the first.
    static func binRelayNotice(owesDowngrade: Bool, owesAck: Bool) -> Int? {
        if owesDowngrade { return 0 }
        if owesAck { return 1 }
        return nil
    }

    /// True while this socket owes the affirmative ack. Read-only diagnostic.
    var binRelayAckPending: Bool {
        lock.lock(); defer { lock.unlock() }; return _binRelayAckPending
    }

    /// True once this socket has sent the affirmative ack. Read-only; once per
    /// socket, cleared only by `connect()`.
    var binRelayAckSent: Bool {
        lock.lock(); defer { lock.unlock() }; return _binRelayAckSent
    }

    /// The text `audio_frame` envelope: same three keys, same absence of any
    /// timestamp, same `send(type:data:)` path, same `websocket.MessageText` on
    /// the wire. Split out of ``sendAudioFrame(recipientId:frame:callId:)``
    /// verbatim so the binary branch cannot drift it.
    ///
    /// ONE exception, and only on a socket that negotiated binary: a fourth
    /// key, `bin_relay`, on exactly ONE frame. Two possible values, one meaning
    /// each, and the server reads them in the same place
    /// (cmd/bcrypto-lite/main.go:6323, `BinRelay *int`):
    ///
    ///   * `0` — the DOWNGRADE REPORT. Our liveness watch fired; this socket is
    ///     back on text and the server must stop writing binary into it.
    ///   * `1` — the AFFIRMATIVE ACK. A binary frame reached us on this socket,
    ///     so the server's watchdog can be disarmed without ever seeing a
    ///     binary uplink from us. This is what makes the watchdog a detector
    ///     rather than a timer during the receive-first step, where the uplink
    ///     is text by design.
    ///
    /// Both describe the TRANSPORT, never the plaintext; neither is relayed
    /// onward (`buildAudioRelay` builds the peer's frame from scratch and knows
    /// nothing about this field); and both are absent from every other frame,
    /// so the constant-size property costs one packet each, once per socket.
    ///
    /// The ack has no binary carrier: the 18-byte header has room for a magic,
    /// a version/kind nibble pair and a call id, and nothing else. That costs
    /// nothing — a socket sending binary proves the same fact by sending it,
    /// which is the disarm the server already has. If a build ever sends binary
    /// on one call and text on another over one socket, the ack simply rides
    /// the first text frame, because the claim is about the socket.
    private func sendAudioFrameAsText(recipientId: String, frame: Data, callId: String?) {
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "frame": frame.base64EncodedString(),
        ]
        if let cid = callId, !cid.isEmpty { data["call_id"] = cid }
        // THE TRANSPORT NOTICE — one spelling, one place, two values.
        //
        // An integer `bin_relay` on an ordinary `audio_frame`, read by the
        // server as `*int` (absent ≠ zero) at cmd/bcrypto-lite/main.go:6323.
        // `0` calls `vetoBinRelay`, which stops it writing binary to this
        // socket AND stops it expecting a binary uplink — the whole repair, in
        // one field, on a frame we were sending anyway. `1` is the affirmative
        // ack: binary reached us here, so its watchdog can stand down without
        // ever seeing binary come back the other way.
        //
        // Take-and-clear: exactly one frame carries each. WebSocket is over
        // TCP, so a frame that reaches `task.send` reaches the server; and if
        // the socket dies instead, both flags die with it in
        // `resetBinLivenessStateLocked()` and the replacement socket owes
        // nothing. Neither is cleared at end of call, so if this call ends
        // before another frame goes out, the first frame of the next call on
        // this socket carries it.
        //
        // Guarded by the compile-time ask for the same reason the liveness
        // watch is (see `sendAudioFrame`): with `binRelayReceiveEnabled` false
        // no socket can ever negotiate binary, so nothing can ever trip and
        // nothing can ever arrive to acknowledge — the guard folds this away
        // and the text path costs exactly what it cost before this feature
        // existed. It is not, and cannot be used as, a way to switch either
        // signal off.
        if CallCapabilities.binRelayReceiveEnabled,
           let notice = takeBinRelayNoticeForOutboundFrame() {
            data["bin_relay"] = notice
        }
        send(type: "audio_frame", data: data)
    }

    /// Binary sibling of ``send(type:data:)``. Mirrors its task/staleness
    /// policy exactly — drop with a log when there is no task, kick a
    /// rate-limited reconnect for the same message types, attempt the send
    /// anyway on a stale-but-live socket — so a call on the binary path
    /// self-heals identically to one on the text path.
    ///
    /// - Parameter kickType: the message type used for the reconnect-kick
    ///   whitelist, so `audio_frame` keeps its 3 s rate limit instead of
    ///   spawning one reconnect per frame at 50 fps.
    private func sendBinary(_ payload: Data, kickType: String) {
        // ONE acquisition for both the task pointer and the negotiation flag.
        // Reading them separately is a real TOCTOU: `forceReconnect()` and
        // `connect()` clear the flag and install a new task between the two
        // reads, so a frame whose form was resolved against socket A gets
        // written to socket B — for which the server has `binRelay == false`
        // and which therefore drops it and counts a protocol error
        // (cmd/bcrypto-lite/main.go:5871-5877), with no error surfaced here.
        lock.lock()
        let task = webSocketTask
        let stillNegotiated = _binRelayNegotiated
        lock.unlock()
        guard stillNegotiated else {
            // The socket lost (or never had) the grant between form resolution
            // and here. INVARIANT 2: binary must never reach a peer that did
            // not agree. Drop this one frame — the next frame re-resolves and
            // the latch downgrades the call to text terminally.
            noteBinaryDrop(.sendNotNegotiated)
            return
        }
        let stale = !isFreshlyAuthenticated()
        if task == nil {
            print("[BCryptoWS] sendBinary(\(kickType)) DROPPED — webSocketTask is nil (WS not connected)")
            if Self.shouldKickReconnect(forType: kickType) {
                forceReconnect()
            }
            return
        }
        if stale && Self.shouldKickReconnect(forType: kickType) {
            print("[BCryptoWS] sendBinary(\(kickType)) STALE socket — kicking reconnect; attempting send anyway (best-effort)")
            forceReconnect()
        }
        // IOS-E1 — same media-only backpressure gate as ``send(type:data:)``.
        guard admitOutboundMediaFrame(forType: kickType) else {
            // See the send(type:data:) sibling above — same shipper-verified
            // "kind=" format.
            print("[BCryptoWS] media send drop kind=\(kickType.hasPrefix("audio") ? "audio" : "video") cap=\(Self.maxOutboundMediaFramesInFlight)")
            return
        }
        task?.send(.data(payload)) { [weak self] error in
            self?.completeOutboundMediaFrame(forType: kickType)
            if let error = error {
                print("[BCryptoWS] sendBinary(\(kickType)) FAILED: \(error.localizedDescription)")
            }
        }
    }

    /// Task 10 (2026-07-01) — `fragIdx`/`totalFrags`/`isKeyFrame` are
    /// carried as TOP-LEVEL JSON fields (`frag_idx`/`total_frags`/
    /// `is_key_frame`), matching Android's real `WsCommand.VideoFrame` /
    /// `WsCodec` encoding exactly (`frag_idx`, `total_frags`,
    /// `is_key_frame` — see qaudion-android-new's `WsCodec.kt`). Defaults
    /// (0/1/false) exist only so any pre-Task-10 call site still compiles;
    /// production callers (AppState.startVideoPipeline) always pass the
    /// real per-fragment values.
    public func sendVideoFrame(
        recipientId: String, frame: Data, callId: String? = nil,
        fragIdx: UInt16 = 0, totalFrags: UInt16 = 1, isKeyFrame: Bool = false
    ) {
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "frame": frame.base64EncodedString(),
            "frag_idx": Int(fragIdx),
            "total_frags": Int(totalFrags),
            "is_key_frame": isKeyFrame,
        ]
        if let cid = callId, !cid.isEmpty { data["call_id"] = cid }
        send(type: "video_frame", data: data)
    }

    public func registerHandler(type: String, handler: @escaping MessageHandler) {
        lock.lock(); messageHandlers[type] = handler; lock.unlock()
    }

    public func addStateListener(_ listener: @escaping (ConnectionState) -> Void) {
        lock.lock(); stateListeners.append(listener); lock.unlock()
    }

    public func updateConfig(_ newConfig: BackendConfig) {
        lock.lock(); config = newConfig; lock.unlock()
    }

    private func authenticate(token: String) {
        var data: [String: Any] = ["token": token]
        // Binary relay framing is negotiated per socket, inside the existing
        // auth handshake — no new message type, one added field. An old server
        // unmarshals into an anonymous struct and drops the unknown key, so a
        // client that asks behaves identically against a server that cannot
        // answer. While `binRelayReceiveEnabled` is false the field is absent
        // entirely and this frame is byte-for-byte what it was before.
        if CallCapabilities.binRelayReceiveEnabled {
            data["bin_relay"] = 1
        }
        // W-ACTIVECALLASSERT — assert the call this process still believes
        // is live so the server cancels the pending disconnect-grace
        // teardown on reconnect (it cancels ONLY on exact match). Same
        // omit-when-absent shape as `bin_relay`: no live call means no key,
        // and the frame stays byte-for-byte what it was before. A stale
        // assertion is answered by the server with a plain `call_hangup`
        // on this fresh socket, which the normal handler treats as
        // definitive teardown — no special-case code anywhere here.
        if let liveCallId = activeCallIdProvider?(), !liveCallId.isEmpty {
            data["active_call_id"] = liveCallId
        }
        send(type: "authenticate", data: data)
    }

    /// The ONE input that may turn binary framing on for a socket: a literal
    /// integer `1` under `bin_relay` in that socket's `authenticated` payload.
    ///
    /// Deliberately strict. Absent key, wrong type, wrong value, or a JSON
    /// boolean `true` (which `NSNumber` would otherwise happily report as 1)
    /// all mean text forever on this socket. Being generous here would let a
    /// malformed reply latch the wire form, and the safety of the whole design
    /// rests on the negotiation shape alone — no client consumes
    /// `audio_relay_degraded` or `call_relay_reject`, so a framing mismatch
    /// surfaces nowhere.
    /// Internal (not private) so the negotiation-strictness test can drive it
    /// directly without opening a socket.
    static func isBinRelayGrant(_ raw: Any?) -> Bool {
        guard let number = raw as? NSNumber else { return false }
        #if canImport(Darwin)
        // JSONSerialization represents JSON `true` as kCFBooleanTrue, which
        // bridges to NSNumber with intValue 1. Reject it explicitly.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return false }
        #endif
        return number.intValue == 1 && number.doubleValue == 1.0
    }

    /// The server→client half of the SAME signal: a literal integer `0` under
    /// `bin_relay`, on whatever message the server is already sending us.
    ///
    /// One field, one value, both directions — client→server `bin_relay: 0` is
    /// our downgrade report, server→client `bin_relay: 0` is the server's veto.
    /// There is no second message type and no second spelling in either
    /// direction.
    ///
    /// Same strictness as ``isBinRelayGrant``, and for the same reason: absent
    /// key, wrong type, a string `"0"`, or a JSON boolean `false` (which
    /// `NSNumber` would report as 0) are NOT a veto. Being generous here would
    /// let a malformed or unrelated payload silently downgrade a healthy call.
    static func isBinRelayVeto(_ raw: Any?) -> Bool {
        guard let number = raw as? NSNumber else { return false }
        #if canImport(Darwin)
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return false }
        #endif
        return number.intValue == 0 && number.doubleValue == 0.0
    }

    /// Honour the server's veto: this socket is on text for the rest of its
    /// life, exactly as if our own watchdog had fired, and it may not be
    /// re-granted by a later `authenticated` echo.
    ///
    /// Terminal because the server's own flag is terminal (`binRelayVetoed`,
    /// cmd/bcrypto-lite/binary_relay.go:289 — CAS'd once, never cleared) and
    /// because a text→binary flip mid-call would change every packet size at a
    /// moment correlated with a network event.
    ///
    /// No report is queued back: the server is the one telling US, and both
    /// sides now agree. Generation-guarded like every other binary-relay state
    /// change, so a zombie socket's buffered frame cannot downgrade the live
    /// one.
    private func honourServerBinRelayVeto(generation: Int) {
        lock.lock()
        guard generation == connectionGeneration else { lock.unlock(); return }
        let alreadyText = _binRelayFallbackTripped && !_binRelayNegotiated
        _binRelayNegotiated = false
        _binRelayFallbackTripped = true
        let sent = _binLivenessOutboundFrames
        let dropped = _binaryFramesDropped
        let rx = _binaryFramesReceived
        let heldCount = _pendingBinaryFrames.count
        resetBinLivenessStateLocked()
        lock.unlock()
        // Once per socket, not once per frame: the server may repeat the field.
        guard !alreadyText else { return }
        // Same prose as the self-trip line, on purpose — that exact wording is
        // what survives `scripts/ship-ios-logs.py`'s fail-closed redactor, and
        // "veto"/"server" in the prose does NOT (re-verified 2026-08-10). The
        // side that decided is the integer: binfb=2 is the server.
        let line: String = "[BCryptoWS] binrelay fallback to text" +
            " binfb=2 rpt=0 win=" + String(Self.binRelayLivenessWindowMs) +
            " sent=" + String(sent) +
            " rx=" + String(rx) +
            " drop=" + String(dropped) +
            " held=" + String(heldCount)
        print(line)
    }

    private func receiveLoop(generation: Int) {
        // Guard: if a newer connect() has run since this loop was spawned, stop
        // recursing. Without this check a zombie loop from a cancelled task would
        // call handleDisconnect() when the task teardown finally delivers its
        // failure result, corrupting the state machine of the newer connection.
        lock.lock()
        let curGen = connectionGeneration
        let task = webSocketTask
        lock.unlock()
        guard curGen == generation, let task = task else { return }

        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handleMessage(text, generation: generation)
                case .data(let data): self.handleBinaryMessage(data, generation: generation)
                @unknown default: break
                }
                self.receiveLoop(generation: generation)
            case .failure(let error):
                self.handleDisconnect(generation: generation, reason: (error as NSError).description)
            }
        }
    }

    /// Inbound WebSocket BINARY frame.
    ///
    /// INVARIANT 1 — a client that has not negotiated binary must behave
    /// byte-identically to today, on both send and receive, INCLUDING which
    /// WebSocket message arms it handles at all. So the `.data` arm still does
    /// exactly what it did before this feature existed
    /// (`String(data:encoding:.utf8)` → ``handleMessage(_:generation:)``)
    /// whenever this socket has not negotiated binary — which is every shipped
    /// build and every build through rollout steps 1-4. The earlier revision
    /// removed that unconditionally and made every non-negotiated client's
    /// receive path differ from today's; that was the breach and this restores
    /// it.
    ///
    /// The `0xB1` test in front of the UTF-8 attempt does not change the
    /// outcome and is not meant to: `0xB1` lies in the UTF-8 continuation range
    /// `0x80...0xBF`, so it can never begin a valid UTF-8 sequence and
    /// `String(data:encoding:.utf8)` returns nil for such a packet anyway. It
    /// is there so the drop is counted under a reason that says what happened
    /// rather than "this wasn't text".
    ///
    /// A binary frame on a socket that did not negotiate is dropped with a
    /// counter — no error, no state change, no log spam at 50 frames a second,
    /// and above all no path that can error the call.
    private func handleBinaryMessage(_ data: Data, generation: Int) {
        lock.lock()
        // GENERATION GUARD. `handleDisconnect` re-checks the generation for
        // exactly this reason and the inbound dispatch did not: a zombie task
        // from a replaced socket delivers buffered frames long after
        // `connect()` has moved on (the "replacing stale ws device × N"
        // pattern this class documents above), and those frames must not be
        // handled against the live socket's state.
        let live = (generation == connectionGeneration)
        let negotiated = live && _binRelayNegotiated
        lock.unlock()

        guard negotiated else {
            // ── today's behaviour, unchanged ──
            if data.first != BinaryRelayFraming.magic,
               let text = String(data: data, encoding: .utf8) {
                handleMessage(text, generation: generation)
                return
            }
            // ── the `authenticated` echo race ──
            // The server sets `client.binRelay` before it enqueues
            // `authenticated`, and its writer goroutine picks between the text
            // and binary channels at random when both are ready, so a relayed
            // packet can beat the echo that tells us binary is on. Dropping it
            // costs a burst of peer audio on every mid-call reconnect —
            // a regression against today's single-FIFO text path, on the worst
            // networks. Hold it instead; `authenticated` either drains or
            // discards the queue a few milliseconds later.
            if live, holdPendingBinaryIfRacingTheEcho(data) { return }
            noteBinaryDrop(live ? .notNegotiated : .staleGeneration)
            return
        }

        // Only now — on a socket that DID negotiate — does an inbound binary
        // frame count as traffic for the staleness detector. Doing this
        // unconditionally would refresh `lastInboundAt` for non-UTF-8 binary
        // frames that today refresh nothing, which is a receive-side behaviour
        // change for a non-negotiated client.
        lock.lock()
        lastInboundAt = Date().timeIntervalSinceReferenceDate
        lock.unlock()

        dispatchBinaryAudio(data)
    }

    /// Parse one binary packet and hand it to the registered `audio_frame`
    /// handler. Shared by the live receive path and the pending-queue drain, so
    /// a held frame is delivered through exactly the same code.
    private func dispatchBinaryAudio(_ data: Data) {
        guard let parsed = BinaryRelayFraming.parseAudio(data) else {
            // Malformed header, wrong magic, a future version, or the reserved
            // video kind. Drop this ONE frame; the call and the socket live on.
            noteBinaryDrop(.malformed)
            return
        }

        lock.lock()
        let handler = messageHandlers["audio_frame"]
        if handler != nil { _binaryFramesReceived &+= 1 }
        // THE AFFIRMATIVE ACK, armed here and only here: a packet that parsed
        // is a binary WebSocket frame that survived the whole path, which is
        // exactly and only what the ack claims. Armed BEFORE the handler test
        // below on purpose — a missing local audio handler is our own wiring,
        // not the network's, and it does not make the traversal less true.
        //
        // Deliberately NOT armed on a malformed packet (that path returns
        // above): a frame the parser rejects proves nothing about the framing
        // contract, and the ack is the one input the server will trust in place
        // of seeing binary itself.
        //
        // Inside the lock this method already takes, so the steady state costs
        // three Bool reads per inbound frame and no extra acquisition.
        armBinRelayAckLocked()
        lock.unlock()

        guard let handler else {
            noteBinaryDrop(.noAudioHandler)
            return
        }

        // Inbound audio ACTUALLY ARRIVED. This is the observation the liveness
        // fallback is waiting for.
        noteInboundAudioForLiveness()

        // Hand the existing `audio_frame` handlers exactly the payload shape
        // the text path gives them — `frame` as base64, `call_id` as the
        // canonical lowercase UUID — so every registration site
        // (CallService.attachIncomingAudioHandler / wireTransport / the W522
        // lazy fallback, and BCryptoWebSocketTransport) works unchanged and
        // this stays a per-hop ENCODING rather than a second internal
        // representation. `sender_id` is absent by design: the binary header
        // carries strictly less than the JSON did, and no iOS `audio_frame`
        // consumer reads it.
        handler("audio_frame", [
            "call_id": parsed.callId,
            "frame": parsed.frame.base64EncodedString()
        ])
    }

    /// Hold one inbound binary packet across the `authenticated` echo race.
    /// Returns `true` if the packet was held (caller must not also drop it).
    ///
    /// Only ever engages when this build ASKED for binary and this socket has
    /// not yet reached `.authenticated`. Bounded by count and by age, so a path
    /// that delivers binary to a socket that will never be granted it queues at
    /// most ``binRelayPendingMaxFrames`` packets and then drops as before.
    private func holdPendingBinaryIfRacingTheEcho(_ data: Data) -> Bool {
        guard CallCapabilities.binRelayReceiveEnabled,
              data.first == BinaryRelayFraming.magic else { return false }
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        guard _state != .authenticated, !_binRelayFallbackTripped else { return false }
        if _pendingBinaryFrames.isEmpty {
            _pendingBinaryFirstHeldAt = now
        } else if (now - _pendingBinaryFirstHeldAt) * 1000 > Double(Self.binRelayPendingHoldMs) {
            // Older than the playout buffer would ever tolerate: this is not a
            // channel race any more. Give up holding.
            _pendingBinaryFrames.removeAll(keepingCapacity: false)
            _pendingBinaryFirstHeldAt = 0
            return false
        }
        guard _pendingBinaryFrames.count < Self.binRelayPendingMaxFrames else { return false }
        _pendingBinaryFrames.append(data)
        return true
    }

    /// Reason an inbound (or outbound) binary frame was dropped. An enum with a
    /// numeric code rather than a free string: the iOS→Loki redactor is a
    /// fail-closed allow-list that blobs hyphenated words and unknown enum
    /// tokens, so `not-negotiated` never survived the trip — verified against
    /// `scripts/ship-ios-logs.py`'s own `redact_body`, which drops the whole
    /// line. Integer `k=v` pairs survive intact.
    private enum BinaryDropReason: Int {
        case notNegotiated = 1
        case malformed = 2
        case noAudioHandler = 3
        case staleGeneration = 4
        case sendNotNegotiated = 5
        case encodeRefused = 6
    }

    /// Count a dropped binary frame and log it SAMPLED (first three, then every
    /// 500th). Frames, never bytes; the reason code describes the framing
    /// decision and never the payload.
    private func noteBinaryDrop(_ reason: BinaryDropReason) {
        lock.lock()
        _binaryFramesDropped &+= 1
        let n = _binaryFramesDropped
        lock.unlock()
        if n <= 3 || n % 500 == 0 {
            // Concatenated, not multi-segment interpolated: CLAUDE.md §13
            // (Xcode 26.4 type-checker traps).
            let line: String = "[BCryptoWS] binrelay frame drop rsn=" +
                String(reason.rawValue) + " drop=" + String(n)
            print(line)
        }
    }

    private func handleMessage(_ text: String, generation: Int) {
        // Any inbound frame, including pong/heartbeat_ack, keeps the connection
        // fresh for the staleness detector.
        lock.lock()
        lastInboundAt = Date().timeIntervalSinceReferenceDate
        lock.unlock()

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        // THE SERVER'S VETO, checked before any per-type handling and on EVERY
        // message type — because it rides whatever message the server is
        // already sending this client, not a message type of its own. The
        // `authenticated` branch below is left to do its own grant logic
        // unchanged; an `authenticated` carrying an explicit 0 lands here first,
        // latches the socket to text, and that branch's
        // `binRelayGranted && !_binRelayFallbackTripped` then evaluates false —
        // so the same frame can never veto and re-grant.
        //
        // Compile-time-guarded first, so a build that never asks for binary
        // does not read this key on any inbound frame and its receive path
        // stays byte-identical to the one that shipped before this feature.
        if CallCapabilities.binRelayReceiveEnabled,
           let payload = json["data"] as? [String: Any],
           Self.isBinRelayVeto(payload["bin_relay"]) {
            honourServerBinRelayVeto(generation: generation)
        }

        if type == "authenticated" {
            // Per-socket binary-relay grant. Read from THIS payload only, and
            // ANDed with our own compile-time ask: a server that echoes the
            // field at a build which never asked for it still gets text, so a
            // shipped build with the switch off can never be talked into
            // binary by anything on the network.
            let authPayload = json["data"] as? [String: Any] ?? [:]
            let binRelayGranted = CallCapabilities.binRelayReceiveEnabled &&
                Self.isBinRelayGrant(authPayload["bin_relay"])
            lock.lock()
            _state = .authenticated
            // GENERATION GUARD, scoped as narrowly as it can be. Only the
            // binary-relay state is gated on the generation; everything else in
            // this branch keeps behaving exactly as it does today, because a
            // client that never negotiates binary must not see any change at
            // all (invariant 1).
            //
            // Why it matters: a zombie task from a replaced socket can deliver
            // a buffered `authenticated` frame after `connect()` has installed
            // a new one. Without this test that stale echo sets
            // `_binRelayNegotiated` for the CURRENT socket — a socket that
            // never sent `bin_relay` and was never granted it — and the send
            // path then writes binary to it. The server drops those frames
            // (cmd/bcrypto-lite/main.go:5851-5877) with a sampled warn and no
            // error frame, `task.send` reports success, and the call goes
            // one-way silent with nothing to see anywhere. That is invariant 2.
            var drainPending: [Data] = []
            if generation == connectionGeneration {
                // Assignment, not OR: a re-authentication whose payload omits
                // the key takes this socket back to text. AND-ed with the
                // fallback latch: once the liveness watch has fired on this
                // socket, no later echo can put it back on binary.
                _binRelayNegotiated = binRelayGranted && !_binRelayFallbackTripped
                if _binRelayNegotiated {
                    drainPending = _pendingBinaryFrames
                }
                _pendingBinaryFrames.removeAll(keepingCapacity: false)
                _pendingBinaryFirstHeldAt = 0
                _binLivenessArmedAt = 0
                _binLivenessOutboundFrames = 0
            }
            // else: a stale generation's echo leaves the live socket's
            // negotiated state untouched — it may neither grant nor revoke.
            reconnectAttempt = 0
            // Clear the debounce flag set by forceReconnect() — the recovery
            // is complete; a future suspension can trigger another reconnect.
            reconnectInFlight = false
            // A clean auth means the token is good again: re-arm the one-shot
            // recovery guards so a LATER expiry can recover once more.
            authRecoveryInFlight = false
            authPermanentlyRejected = false
            let listeners = stateListeners
            lock.unlock()
            // Deliver anything held across the echo race, in arrival order,
            // through the same code a live frame takes. Empty on every build
            // that did not ask for binary, so this is a no-op array walk on the
            // default path.
            for held in drainPending { dispatchBinaryAudio(held) }
            listeners.forEach { $0(.authenticated) }
            startPingTimer()
            return
        }

        // `pong` and `heartbeat_ack` are server responses to our ping. Compute
        // round-trip time if we have a recorded pingSentAt, then fire the callback.
        if type == "pong" || type == "heartbeat_ack" {
            lock.lock()
            let sent = pingSentAt
            let cb = onLatencyMeasured
            lock.unlock()
            if sent > 0 {
                let rttMs = Int((Date().timeIntervalSinceReferenceDate - sent) * 1000)
                if rttMs > 0 { cb?(rttMs) }
                // Fix (2026-07-31, found during full-audit) — see the
                // ping-sent print in tickKeepalive for why this exists: the
                // only way to tell "pings aren't leaving the device" from
                // "pongs aren't arriving" from a device log is having BOTH
                // sides of the round trip actually print something.
                print("[BCryptoWS] \(type) received rtt=\(rttMs)ms")
            }
            return
        }

        // Built-in auth-failure handler: when the server rejects our token it
        // closes the connection and sends {"type":"error","code":"auth_failed"}.
        //
        // Always-reachable Phase 2 — DO NOT park the reconnect loop forever
        // (the old code set reconnectAttempt = maxReconnectAttempts so the next
        // handleDisconnect stopped scheduling). Hammering a dead-auth socket
        // would just churn the server, but giving up permanently means the
        // device silently falls off until the app is relaunched. Correct
        // behaviour: fire the SILENT token-recovery cascade (REST refresh →
        // Ed25519 device-renew, wired in BCryptoBackendProvider) exactly ONCE,
        // then resume the normal backoff reconnect with the fresh token. Only a
        // genuine revocation (the cascade itself rejected) parks the loop — and
        // even then this class NEVER forces QR; the app layer drives re-onboard.
        if type == "error" {
            let errData = json["data"] as? [String: Any] ?? [:]
            let code = errData["code"] as? String ?? ""
            if code == "auth_failed" {
                handleAuthFailed()
            }
        }

        lock.lock()
        let handler = messageHandlers[type]
        lock.unlock()
        // Inbound audio in the TEXT form counts for the liveness watch too.
        // The watch asks "is peer audio reaching us at all", not "is it
        // reaching us in the form we negotiated" — a server that answers our
        // binary socket with text is working correctly (contract §3: text in /
        // binary out and every other combination are supported forever), and
        // tearing that down would be the fallback firing on a healthy call.
        if type == "audio_frame", CallCapabilities.binRelayReceiveEnabled {
            noteInboundAudioForLiveness()
        }
        let messageData = json["data"] as? [String: Any] ?? [:]
        handler?(type, messageData)
    }

    // MARK: - Keepalive

    /// Start the keepalive timer that sends a `ping` envelope every
    /// `pingIntervalSec` and tears the connection down if no inbound frame
    /// arrives within `pongTimeoutSec` of the last ping. Must be called
    /// after the server has accepted our `authenticate` message.
    private func startPingTimer() {
        lock.lock()
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pingIntervalSec, repeating: pingIntervalSec)
        timer.setEventHandler { [weak self] in self?.tickKeepalive() }
        pingTimer = timer
        lastInboundAt = Date().timeIntervalSinceReferenceDate
        lock.unlock()
        timer.resume()
    }

    private func tickKeepalive() {
        lock.lock()
        let lastInbound = lastInboundAt
        let isAuthenticated = _state == .authenticated
        let gen = connectionGeneration
        // Capture the adaptive timing under the lock — applyAdaptiveTiming()
        // mutates these from the path-monitor queue.
        let pingInterval = pingIntervalSec
        let pongTimeout = pongTimeoutSec
        lock.unlock()

        guard isAuthenticated else { return }

        let age = Date().timeIntervalSinceReferenceDate - lastInbound
        // If a full ping cycle has passed without any inbound traffic, treat the
        // socket as dead and force a reconnect.
        if age > pingInterval + pongTimeout {
            // Fix (2026-07-31, found during full-audit): this is the ONE
            // disconnect path in this file that passed no `reason:` — every
            // other teardown path records a real one, so `_lastDisconnectReason`
            // fell through to "unknown" here specifically. This exact branch
            // is what a live capture (device+server logs, 2026-07-31) showed
            // firing continuously — authenticate, ~30-90s silence, this
            // abrupt local self-teardown (matches the server's observed
            // "read error ... EOF" signature), reconnect, repeat — for an
            // entire test session. Without a real reason there was no way to
            // even confirm from logs alone that this was the exact branch
            // firing versus some other disconnect path with a similar
            // symptom. Now self-documenting on the next capture.
            let reason = "keepalive-dead-timeout: no inbound for \(String(format: "%.1f", age))s (pingInterval=\(pingInterval)s pongTimeout=\(pongTimeout)s)"
            print("[BCryptoWS] \(reason)")
            lock.lock()
            webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
            webSocketTask = nil
            lock.unlock()
            handleDisconnect(generation: gen, reason: reason)
            return
        }

        lock.lock()
        pingSentAt = Date().timeIntervalSinceReferenceDate
        lock.unlock()
        // Fix (2026-07-31, found during full-audit): the send-ping and
        // receive-pong paths were both completely silent on success — only
        // failures printed anywhere in this class. That made it impossible
        // to tell, from a device log alone, "pings genuinely aren't leaving
        // the device" from "pongs aren't arriving" from "this code isn't
        // running at all" — three very different explanations for the same
        // churn symptom. This print + the pong-received one in
        // handleMessage's "pong"/"heartbeat_ack" branch are the minimum
        // needed to actually distinguish them on the next capture.
        print("[BCryptoWS] ping sent (age=\(String(format: "%.1f", age))s)")
        send(type: "ping", data: [:])
    }

    // MARK: - Silent token recovery (always-reachable Phase 2)

    /// Handle a server `auth_failed`. Runs the silent token-recovery cascade
    /// (REST refresh → Ed25519 device-renew, wired via `onAuthFailedRecover`)
    /// at most ONCE per authenticated session, then either resumes reconnect
    /// (recovery produced a fresh token) or parks the loop (genuine
    /// revocation). NEVER forces QR — re-onboarding is the app layer's job.
    private func handleAuthFailed() {
        lock.lock()
        // Already recovering, or no recovery hook wired → fall back to the old
        // behaviour of just letting the reconnect loop continue with backoff.
        // (Without a hook we cannot silently re-auth; indefinite backoff still
        // beats a permanent give-up because the token may be renewed out-of-band
        // by the app layer between probes.)
        if authRecoveryInFlight {
            lock.unlock()
            return
        }
        // Cross-cycle anti-storm gate: even though `authRecoveryInFlight` is
        // reset after each cascade, a server that keeps rejecting a freshly-
        // renewed token would otherwise re-fire the (2-network-call) cascade
        // every ~1-2 s because the success path resets `reconnectAttempt = 0`,
        // restarting backoff. This timestamp gate survives reconnect cycles
        // (it is never reset on `authenticated`) and caps cascades to one per
        // `minAuthRecoveryIntervalSec`. The very first auth_failed after a long
        // quiet period passes immediately (lastAuthRecoveryAt == 0), so a
        // genuine one-off expiry still recovers in ~1 s. Subsequent rapid
        // rejects fall through here; the reconnect loop continues with its
        // normal exponential backoff (capped at maxReconnectDelaySec) so the
        // socket still retries, just without re-running the cascade.
        let now = Date().timeIntervalSinceReferenceDate
        if lastAuthRecoveryAt != 0,
           now - lastAuthRecoveryAt < minAuthRecoveryIntervalSec {
            lock.unlock()
            return
        }
        let hook = onAuthFailedRecover
        guard let recover = hook else {
            lock.unlock()
            return
        }
        authRecoveryInFlight = true
        lastAuthRecoveryAt = now
        lock.unlock()

        Task { [weak self] in
            guard let self = self else { return }
            let ok = await recover()
            // Swift 6 — NSLock.lock()/unlock() are unavailable from async
            // contexts (they can block the cooperative pool). Mutate the shared
            // state under a scoped `withLock` (synchronous, no await inside),
            // then act on the decision OUTSIDE the lock.
            self.lock.withLock {
                self.authRecoveryInFlight = false
                if ok {
                    // Fresh token applied (updateConfig already broadcast by the
                    // provider). Reset backoff and reconnect immediately with the
                    // new credentials.
                    self.authPermanentlyRejected = false
                    self.reconnectAttempt = 0
                } else {
                    // Genuine revocation — park the reconnect loop until the app
                    // layer re-onboards and calls connect() again. No QR forced.
                    self.authPermanentlyRejected = true
                }
            }
            if ok {
                let okLine: String = "[BCryptoWS] auth_failed → silent recovery OK, reconnecting"
                print(okLine)
                // forceReconnect() (not connect()) so the fresh token is used
                // even if the auth_failed socket hasn't finished closing yet —
                // connect() early-returns unless state is .disconnected, which
                // would lose the recovery on that race. forceReconnect cancels
                // any lingering task first and is debounced against storms.
                self.forceReconnect()
            } else {
                let failLine: String = "[BCryptoWS] auth_failed → silent recovery REJECTED (revoked); pausing reconnect"
                print(failLine)
            }
        }
    }

    // MARK: - Network path monitoring (always-reachable Phase 2)

    /// Begin watching the network path. On the unsatisfied→satisfied edge
    /// (network came back) or a transport switch (WiFi↔cellular, wake), kick a
    /// fast `forceReconnect()` instead of waiting out the staleness window, and
    /// retune the adaptive ping cadence for the new transport.
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// React to an NWPathMonitor update. Anti-hammer: only a genuine edge
    /// (network recovered, or transport changed) triggers a reconnect, and at
    /// most one reconnect per `pathReconnectDebounceSec`.
    private func handlePathUpdate(_ path: NWPath) {
        let satisfied = (path.status == .satisfied)
        // Primary transport: the first non-loopback interface on the path.
        let transport: NWInterface.InterfaceType? = satisfied
            ? path.availableInterfaces.first(where: { $0.type != .loopback })?.type
            : nil

        // Retune adaptive ping/dead-timeout for this transport (cheap; always).
        applyAdaptiveTiming(for: transport)

        lock.lock()
        let wasSatisfied = lastPathSatisfied
        let prevTransport = lastTransport
        let now = Date().timeIntervalSinceReferenceDate
        let sinceLastKick = now - lastPathReconnectAt
        lastPathSatisfied = satisfied
        lastTransport = transport
        hasReceivedPathUpdate = true
        let rejected = authPermanentlyRejected
        // IOS-E5 (W-OFFLINEPARK) — un-park the instant the path is
        // satisfied again. This is deliberately NOT gated by the W-PATHFLAP
        // debounce/live-task bail below: parking only ever happens from
        // `handleDisconnect` when the socket is ALREADY disconnected with
        // no live task and NO backoff timer scheduled (see there), so there
        // is nothing here to storm — going from "zero scheduled attempts"
        // to "one immediate attempt" on a genuine recovery is the entire
        // point of the park, and waiting out the normal debounce would
        // reintroduce the exact "still sitting out a stale backoff window"
        // cost the park exists to avoid.
        var shouldUnpark = false
        if reconnectParkedForOffline, satisfied, !rejected {
            reconnectParkedForOffline = false
            reconnectAttempt = 0
            shouldUnpark = true
        }
        let socksPortForUnpark = currentSocksPort
        lock.unlock()

        if shouldUnpark {
            // Verified against ship-ios-logs.py's redact_body — "net
            // park=0/1 attempt=N" survives the structured-shape gate intact;
            // "offlinepark unpark reconnect_attempt=N" (prose-heavy, two
            // unrecognized words) does not, re-verified 2026-08-25.
            print("[BCryptoWS] net park=0 attempt=0")
            connect(viaSocksPort: socksPortForUnpark)
            return
        }

        // Only act on a meaningful edge:
        //   - network came back (unsatisfied → satisfied), OR
        //   - the transport changed while still satisfied (WiFi↔cellular).
        let networkRecovered = satisfied && !wasSatisfied
        let transportSwitched = satisfied && wasSatisfied && (transport != prevTransport)
        guard networkRecovered || transportSwitched else { return }

        // Do not revive a deliberately-parked (revoked) socket — the app layer
        // owns re-onboarding in that case.
        if rejected { return }

        // Debounce: ignore a flapping interface storming path updates.
        if sinceLastKick < pathReconnectDebounceSec { return }

        // CRITICAL anti-flap: a "recovered"/"switched" path event must NOT tear
        // down a socket that still has a LIVE authenticated task. On VPN/Tor/
        // flaky-WiFi setups iOS NWPathMonitor reports satisfied↔unsatisfied every
        // few seconds; forceReconnect()ing on each "recovery" produced a ~3 s
        // reconnect storm — device report 2026-06-25: "path change
        // (network-recovered) → fast forceReconnect()" EVERY ~3 s for an entire
        // iOS↔Android call → 97% packet loss, repeated "M-15 unseal failed/replay
        // — dropped", the ACCEPT bundle lost so one direction never reached SAS,
        // and no audio either way. The earlier `isFreshlyAuthenticated()` bail was
        // NOT enough: the storm itself keeps the socket non-fresh (no inbound
        // arrives between teardowns) → the bail never fires → vicious cycle. Bail
        // on the WEAKER `hasLiveAuthenticatedTask()` instead: if the task is still
        // authenticated + non-nil, LEAVE IT ALONE — a genuinely dead / zombie
        // socket is recovered by the ping/pong staleness detector (pongTimeout)
        // and by AppState.willEnterForeground, NOT by churning it on every phantom
        // path edge. Mirrors Android KeepAlive (never force-reconnect a live socket).
        if hasLiveAuthenticatedTask() { return }

        lock.lock()
        lastPathReconnectAt = now
        lock.unlock()

        // W-PATHFLAP 2026-06-25: do NOT forceReconnect() on a path edge.
        // On iPad / iOS-26.5 the path reported "network-recovered" every ~3 s
        // (exactly periodic, WiFi, no VPN). Each forceReconnect() spawned a fresh
        // URLSession socket whose setup itself re-triggered NWPathMonitor →
        // another "network-recovered" → forceReconnect: a SELF-PERPETUATING ~3 s
        // reconnect storm. The 15 s debounce + hasLiveAuthenticatedTask bail could
        // NOT stop it because the cycle never lets the socket stay live and keeps
        // re-arming the edge → 97% packet loss, dropped PQC/ACCEPT frames, the
        // ACCEPT lost so one direction never reached SAS, dead calls (device
        // reports on v1.0.677 AND v1.0.678). The reconnect storm was APP-amplified,
        // not a genuine network change. Recovery of a genuinely dead socket is
        // owned by the ping/pong staleness detector (pongTimeout) +
        // willEnterForeground + the send()/ensureAuthenticated() reconnect paths —
        // none of which self-loop. The path handler now ONLY retunes adaptive ping
        // timing (applyAdaptiveTiming, above) and tracks state for logging.
        let reason: String = networkRecovered ? "network-recovered" : "transport-switch"
        print("[BCryptoWS] path edge (" + reason + ") — adaptive-timing only, NOT reconnecting (ping/pong owns recovery)")
    }

    /// Map the current primary transport to (pingInterval, pongTimeout) and,
    /// if it changed, re-arm the keepalive timer so the new cadence takes
    /// effect immediately rather than on the next natural tick.
    ///   WiFi      → 20 / 30   (beat carrier/NAT idle timeouts)
    ///   cellular  → 60 / 120  (relaxed: carrier NAT forgiving, save radio/battery)
    ///   wired/other → 30 / 45
    private func applyAdaptiveTiming(for transport: NWInterface.InterfaceType?) {
        let ping: TimeInterval
        let pong: TimeInterval
        switch transport {
        case .wifi:
            ping = 20; pong = 30
        case .cellular:
            ping = 60; pong = 120
        case .wiredEthernet:
            ping = 30; pong = 45
        default:
            // .loopback / .other / nil (no satisfied path yet) → conservative.
            ping = 30; pong = 45
        }

        lock.lock()
        let changed = (ping != pingIntervalSec) || (pong != pongTimeoutSec)
        pingIntervalSec = ping
        pongTimeoutSec = pong
        let authed = (_state == .authenticated) && (webSocketTask != nil)
        lock.unlock()

        // Re-arm the keepalive only when the cadence actually changed AND we
        // have a live authenticated socket to keep alive (startPingTimer is a
        // no-op otherwise and would needlessly churn the timer).
        if changed && authed {
            startPingTimer()
        }
    }

    private func handleDisconnect(generation: Int? = nil, reason: String? = nil) {
        lock.lock()
        // Drop stale disconnect callbacks from zombie connections. This fires when
        // a cancelled task's receive closure delivers its .failure result AFTER a
        // newer connect() has already created a replacement task. Without the check,
        // the zombie would overwrite _state = .disconnected and schedule a redundant
        // connect() that creates a second concurrent WS task — the root cause of the
        // "replacing stale ws device × N" pattern seen in server logs.
        if let gen = generation, gen != connectionGeneration {
            lock.unlock()
            return
        }
        _state = .disconnected
        _lastDisconnectReason = reason ?? "unknown"
        // The socket that negotiated binary is dead. Clearing here (and not
        // only in the connect() that follows) closes the window between the
        // drop and the reconnect, in which an in-flight relay frame would
        // otherwise still resolve to binary against a socket that no longer
        // exists. The per-call latch reads this flag, sees false, and
        // downgrades that call to text for good.
        _binRelayNegotiated = false
        resetBinLivenessStateLocked()
        // IOS-E5 (W-OFFLINEPARK) — strictly `.unsatisfied` (no network
        // transport at all), same "guaranteed instant failure" signal
        // Android's `shouldParkForOffline()` checks, restated on
        // `NWPath.status`. `hasReceivedPathUpdate` guards the brief window
        // before the monitor's first callback, where "offline" would
        // otherwise be a false positive rather than a real reading.
        let offline = hasReceivedPathUpdate && !lastPathSatisfied
        let permanentlyRejected = authPermanentlyRejected
        let recoveryRunning = authRecoveryInFlight
        // Auth-rejection/recovery-in-flight are stronger stop conditions
        // than the offline park — checked first, unchanged from before.
        if !permanentlyRejected && !recoveryRunning && offline {
            reconnectParkedForOffline = true
            // Deliberately SKIP attempt++ and the onNodeStalled failover
            // trigger — a dead LOCAL network says nothing about whether the
            // signaling node is healthy, exactly mirroring the Android
            // comment this ports (WsDispatcher.scheduleReconnect).
            reconnectInFlight = false
            pingTimer?.cancel()
            pingTimer = nil
            let listeners = stateListeners
            let attemptFrozen = reconnectAttempt
            lock.unlock()
            listeners.forEach { $0(.disconnected) }
            // See the un-park print in handlePathUpdate above — same
            // shipper-verified "net park=" format.
            print("[BCryptoWS] net park=1 attempt=\(attemptFrozen)")
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        // FAILOVER trigger: after enough consecutive reconnects the node is likely
        // DEAD. Signal the app to fail over to a different node (it re-selects +
        // reconnects). The backoff reconnect below still proceeds and is superseded
        // when the app switches the server URL.
        if attempt >= failoverAfterAttempts, let onStalled = onNodeStalled {
            let deadWss = config.serverUrl
                .replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://", with: "ws://") + "/ws"
            onStalled(deadWss)
        }
        // Drop the in-flight flag — the previous reconnect attempt either
        // finished or failed. The next forceReconnect() / send() can kick a
        // fresh attempt without being silently debounced.
        reconnectInFlight = false
        pingTimer?.cancel()
        pingTimer = nil
        let listeners = stateListeners
        let socksPort = currentSocksPort
        lock.unlock()
        listeners.forEach { $0(.disconnected) }

        // Always-reachable Phase 2: NO attempt cap — the persistent WS retries
        // indefinitely (push remains the reachability spine in the meantime).
        // Two — and only two — conditions stop scheduling here:
        //   1. The token-recovery cascade was genuinely rejected (revocation):
        //      reconnecting would just earn another instant auth_failed. The
        //      app layer re-onboards and calls connect() again (which resets
        //      authPermanentlyRejected on the next successful authenticate).
        //   2. The silent recovery is currently in flight — its completion
        //      handler will call connect() once the fresh token is applied, so
        //      scheduling a backoff reconnect here too would double-fire.
        if permanentlyRejected || recoveryRunning { return }
        // W550 — real exponential backoff with jitter.
        //
        // OLD formula: `min(30, attempt * 0.5)` capped at attempt=10 →
        // attempt 11+ reconnected every 5 s forever. On a broken-token
        // device this generated 720 reconnects/h on the server (the
        // exact pattern we saw on 79.51.170.153). Multiplied by N
        // devices behind the same provider, that's a slow DoS of the
        // app's own auth-deadline budget.
        //
        // NEW formula: 1 s × 2^(attempt-1) capped at maxReconnectDelaySec
        // (30 s) + ±25 % jitter. Recovery on a healthy network is fast
        // (1-2 s) but a wedged token decays to a 30 s probe rate within 6
        // attempts (saves 10x server load). The exponent is clamped at 5 so
        // the now-unbounded attempt counter can never overflow `pow`; the
        // delay plateaus at the 30 s cap and stays there forever — steady
        // background probing, never a storm. Jitter prevents N devices on a
        // network coming back from a blip from synchronizing into a
        // thundering herd.
        let baseDelay = min(maxReconnectDelaySec, pow(2.0, Double(min(attempt - 1, 5))))
        let jitter = baseDelay * (Double.random(in: -0.25...0.25))
        let delay = max(0.5, baseDelay + jitter)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect(viaSocksPort: socksPort)
        }
    }
}

/// SECURITY C-6 / H-1 / H-5 — the WS session's single delegate. It
/// (a) handles the TLS server-trust challenge with the same DER-SHA256
/// pinning the REST client uses, and (b) fires `onOpen` exactly when
/// the WebSocket upgrade completes so the auth token is never sent
/// before the socket is actually open.
final class WSSessionDelegate: NSObject, URLSessionWebSocketDelegate {

    enum ChallengeMode {
        /// Reuse the REST client's DER-SHA256 chain pinning.
        case pinned(CertPinningDelegate)
        /// System default TLS chain validation (CA-signed certs).
        case systemDefault
        #if DEBUG
        /// DEBUG-only: trust any server cert (local self-signed box).
        case trustAll
        #endif
    }

    private let mode: ChallengeMode
    private let onOpen: () -> Void
    /// Guard so a reconnect on the same delegate instance can't double-fire.
    private var didOpen = false
    private let openLock = NSLock()

    init(mode: ChallengeMode, onOpen: @escaping () -> Void) {
        self.mode = mode
        self.onOpen = onOpen
        super.init()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch mode {
        case .pinned(let pinDelegate):
            // Delegate the exact REST pinning logic (chain DER-SHA256).
            pinDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        case .systemDefault:
            completionHandler(.performDefaultHandling, nil)
        #if DEBUG
        case .trustAll:
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        #endif
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        openLock.lock()
        let firstOpen = !didOpen
        didOpen = true
        openLock.unlock()
        guard firstOpen else { return }
        // H-5: the HTTP→WS upgrade is now complete — safe to authenticate.
        onOpen()
    }
}
