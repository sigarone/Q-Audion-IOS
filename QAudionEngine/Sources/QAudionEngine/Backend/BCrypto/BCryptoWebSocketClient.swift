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

    private var webSocketTask: URLSessionWebSocketTask?
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
    /// Interval between outbound ping keepalives. Server-side idle timeout is
    /// usually 60s; 30s gives us one retry window before the server drops us.
    private let pingIntervalSec: TimeInterval = 30
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

    public init(config: BackendConfig) {
        self.config = config
        // Pre-negotiation dispatch — server emits these on top of the standard
        // call_offer / call_answer / call_hangup signaling envelopes.
        // See bcrypto-server cmd/bcrypto-lite/main.go pre-negotiation flow.
        registerPreNegotiationHandlers()
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
    }

    public var state: ConnectionState { lock.lock(); defer { lock.unlock() }; return _state }

    public func connect() {
        lock.lock()
        guard _state == .disconnected else { lock.unlock(); return }
        _state = .connecting
        let listeners = stateListeners
        lock.unlock()
        listeners.forEach { $0(.connecting) }

        guard let url = URL(string: config.serverUrl.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + "/ws") else { return }

        let session: URLSession
        if config.acceptSelfSignedCerts {
            session = URLSession(configuration: .default, delegate: SelfSignedCertDelegate(), delegateQueue: nil)
        } else {
            session = URLSession.shared
        }
        let task = session.webSocketTask(with: url)
        lock.lock()
        webSocketTask = task
        lock.unlock()
        task.resume()
        receiveLoop()

        if let token = config.accessToken { authenticate(token: token) }
    }

    public func disconnect() {
        lock.lock()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
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
        // Reset reconnectAttempt so the backoff in handleDisconnect is fresh.
        reconnectAttempt = 0
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
        // Stale or disconnected — force a clean reconnect, then poll until
        // either the state flips to .authenticated or we time out.
        forceReconnect()

        let deadline = Date().addingTimeInterval(timeoutSec)
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
    private static func shouldKickReconnect(forType type: String) -> Bool {
        switch type {
        case "audio_frame", "video_frame", "ping": return false
        default: return true
        }
    }

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

    public func sendAudioFrame(recipientId: String, frame: Data) {
        send(type: "audio_frame", data: ["recipient_id": recipientId, "frame": frame.base64EncodedString()])
    }

    public func sendVideoFrame(recipientId: String, frame: Data) {
        send(type: "video_frame", data: ["recipient_id": recipientId, "frame": frame.base64EncodedString()])
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

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handleMessage(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.handleMessage(text) }
                @unknown default: break
                }
                self.receiveLoop()
            case .failure:
                self.handleDisconnect()
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

        // `pong` and `heartbeat_ack` are server responses to our ping. No listener
        // handler is needed — just refreshing `lastInboundAt` above is enough.
        if type == "pong" || type == "heartbeat_ack" { return }

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
        lock.unlock()

        guard isAuthenticated else { return }

        let age = Date().timeIntervalSinceReferenceDate - lastInbound
        // If a full ping cycle has passed without any inbound traffic, treat the
        // socket as dead and force a reconnect.
        if age > pingIntervalSec + pongTimeoutSec {
            webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
            handleDisconnect()
            return
        }

        send(type: "ping", data: [:])
    }

    private func handleDisconnect() {
        lock.lock()
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
        let delay = min(30.0, Double(min(attempt, 10)) * 0.5)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
}

private class SelfSignedCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
