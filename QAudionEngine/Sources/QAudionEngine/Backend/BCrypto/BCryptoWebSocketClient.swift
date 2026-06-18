import Foundation

public final class BCryptoWebSocketClient: @unchecked Sendable {
    public typealias MessageHandler = (String, [String: Any]) -> Void

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

    /// Fired when this client (responder) receives `call_cancel` from the server.
    /// The caller hung up before we picked up — stop ringing locally.
    public var onCallCancel: ((_ callId: String, _ reason: String?) -> Void)?

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
    public var onCallUpgradeResponse: ((_ callId: String, _ accepted: Bool, _ sdp: String) -> Void)?

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
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 20
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
    /// Interval between outbound ping keepalives. Server pings every 20 s with a
    /// 45 s stale threshold; matching 20 s ensures we beat mobile-carrier NAT
    /// idle timeouts (many are ~30 s) and keeps lastInboundAt fresh enough that
    /// the server never marks this device stale before a foreground ping cycle.
    private let pingIntervalSec: TimeInterval = 20
    /// If no inbound traffic arrives within this window after a ping, treat the
    /// connection as dead and tear it down so the reconnect loop picks it up.
    private let pongTimeoutSec: TimeInterval = 25
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

    public init(config: BackendConfig) {
        self.config = config
        // Pre-negotiation dispatch — server emits these on top of the standard
        // call_offer / call_answer / call_hangup signaling envelopes.
        // See bcrypto-server cmd/bcrypto-lite/main.go pre-negotiation flow.
        registerPreNegotiationHandlers()
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

        registerHandler(type: "call_cancel") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let reason = data["reason"] as? String
            self.onCallCancel?(callId, reason)
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

        // W536 — call_upgrade_response (callee→caller). `accepted`
        // defaults to true when the peer omits the field (legacy
        // desktop builds < commit a13b that always implied accepted).
        registerHandler(type: "call_upgrade_response") { [weak self] _, data in
            guard let self = self,
                  let callId = data["call_id"] as? String else { return }
            let sdp = (data["sdp"] as? String) ?? ""
            let accepted = (data["accepted"] as? Bool) ?? true
            self.onCallUpgradeResponse?(callId, accepted, sdp)
        }
    }

    public var state: ConnectionState { lock.lock(); defer { lock.unlock() }; return _state }

    public func connect() {
        lock.lock()
        guard _state == .disconnected else { lock.unlock(); return }
        _state = .connecting
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
        lock.unlock()
        listeners.forEach { $0(.disconnected) }
        connect()

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

    public func sendVideoFrame(recipientId: String, frame: Data, callId: String? = nil) {
        var data: [String: Any] = [
            "recipient_id": recipientId,
            "frame": frame.base64EncodedString(),
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
            case .failure:
                self.handleDisconnect(generation: generation)
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

        // Built-in auth-failure guard: when the server rejects our token it
        // closes the connection and sends {"type":"error","code":"auth_failed"}.
        // Without this check the handleDisconnect reconnect loop would fire
        // all 20 attempts before stopping, but connectPersistentSocket() (called
        // on foreground) would reset the counter and restart the cycle — giving
        // the observed 90-minute reconnect storm with a stale/expired token.
        // Setting reconnectAttempt = maxReconnectAttempts here means the very
        // next handleDisconnect (which fires when the server closes the socket)
        // exits without scheduling another reconnect.
        if type == "error" {
            let errData = json["data"] as? [String: Any] ?? [:]
            let code = errData["code"] as? String ?? ""
            if code == "auth_failed" {
                lock.lock()
                reconnectAttempt = maxReconnectAttempts
                lock.unlock()
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
        lock.unlock()

        guard isAuthenticated else { return }

        let age = Date().timeIntervalSinceReferenceDate - lastInbound
        // If a full ping cycle has passed without any inbound traffic, treat the
        // socket as dead and force a reconnect.
        if age > pingIntervalSec + pongTimeoutSec {
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

    private func handleDisconnect(generation: Int? = nil) {
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
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        // Drop the in-flight flag — the previous reconnect attempt either
        // finished or failed. The next forceReconnect() / send() can kick a
        // fresh attempt without being silently debounced.
        reconnectInFlight = false
        pingTimer?.cancel()
        pingTimer = nil
        let listeners = stateListeners
        lock.unlock()
        listeners.forEach { $0(.disconnected) }

        guard attempt < maxReconnectAttempts else { return }
        // W550 — real exponential backoff with jitter.
        //
        // OLD formula: `min(30, attempt * 0.5)` capped at attempt=10 →
        // attempt 11+ reconnected every 5 s forever. On a broken-token
        // device this generated 720 reconnects/h on the server (the
        // exact pattern we saw on 79.51.170.153). Multiplied by N
        // devices behind the same provider, that's a slow DoS of the
        // app's own auth-deadline budget.
        //
        // NEW formula: 1 s × 2^(attempt-1) capped at 30 s + ±25 %
        // jitter. Recovery on a healthy network is fast (1-2 s) but
        // a wedged token decays to a 30 s probe rate within 6
        // attempts (saves 10x server load). Jitter prevents N
        // devices on a network coming back from a blip from
        // synchronizing into a thundering herd.
        let baseDelay = min(30.0, pow(2.0, Double(min(attempt - 1, 5))))
        let jitter = baseDelay * (Double.random(in: -0.25...0.25))
        let delay = max(0.5, baseDelay + jitter)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
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
