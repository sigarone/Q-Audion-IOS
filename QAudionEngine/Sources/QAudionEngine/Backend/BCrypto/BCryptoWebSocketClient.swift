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
    public var onCallVideoState: ((_ callId: String, _ paused: Bool) -> Void)?

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
            self.onCallVideoState?(callId, paused)
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
        task?.send(.string(jsonString)) { error in
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
            if now.timeIntervalSince(lastMediaKick) > 3.0 {
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
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "frame": frame.base64EncodedString(),
        ]
        if let cid = callId, !cid.isEmpty { data["call_id"] = cid }
        send(type: "audio_frame", data: data)
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
        send(type: "authenticate", data: ["token": token])
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
                case .string(let text): self.handleMessage(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.handleMessage(text) }
                @unknown default: break
                }
                self.receiveLoop(generation: generation)
            case .failure(let error):
                self.handleDisconnect(generation: generation, reason: (error as NSError).description)
            }
        }
    }

    private func handleMessage(_ text: String) {
        // Any inbound frame, including pong/heartbeat_ack, keeps the connection
        // fresh for the staleness detector.
        lock.lock()
        lastInboundAt = Date().timeIntervalSinceReferenceDate
        lock.unlock()

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "authenticated" {
            lock.lock()
            _state = .authenticated
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
            lock.lock()
            webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
            webSocketTask = nil
            lock.unlock()
            handleDisconnect(generation: gen)
            return
        }

        lock.lock()
        pingSentAt = Date().timeIntervalSinceReferenceDate
        lock.unlock()
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
        let rejected = authPermanentlyRejected
        lock.unlock()

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
        let permanentlyRejected = authPermanentlyRejected
        let recoveryRunning = authRecoveryInFlight
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
