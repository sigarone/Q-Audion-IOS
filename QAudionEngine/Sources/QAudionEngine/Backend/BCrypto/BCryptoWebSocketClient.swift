import Foundation

public final class BCryptoWebSocketClient: @unchecked Sendable {
    public typealias MessageHandler = (String, [String: Any]) -> Void

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

    public init(config: BackendConfig) { self.config = config }

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
        webSocketTask?.send(.string(jsonString)) { _ in }
    }

    public func sendOpaqueMessage(recipientId: String, payload: Data) {
        send(type: "opaque_message", data: ["recipient_id": recipientId, "data": payload.base64EncodedString()])
    }

    public func sendAudioFrame(recipientId: String, frame: Data) {
        send(type: "audio_frame", data: ["recipient_id": recipientId, "frame": frame.base64EncodedString()])
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
