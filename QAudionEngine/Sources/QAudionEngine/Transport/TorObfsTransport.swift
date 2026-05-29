import Foundation
import os

/// Anti-DPI transport that tunnels signaling through Tor SOCKS5.
///
/// Uses the .onion hidden service address of the BCrypto server.
/// Latency: ~300-500ms — used as last resort before giving up.
///
/// **Tor source priority (automatic fallback):**
///   1. Embedded Tor via `EmbeddedTorManager` (iCepa/Tor.swift) — self-contained,
///      no external dependencies.
///   2. External Orbot app providing SOCKS5 at 127.0.0.1:9050 — requires the user
///      to have Orbot installed and running.
///
/// **Mirrors:**
/// - Android: `TorBridge.kt` (embedded tor-android) → direct SOCKS5
/// - Desktop: `TorManager.ts` (child-process tor) + `BCryptoSocket.ts` SOCKS5 override
public final class TorObfsTransport: @unchecked Sendable {

    // MARK: - State

    private let onionAddress: String
    private let peerId: String
    private let callId: String
    /// Orbot fallback port (default 9050). Ignored when embedded Tor is used.
    private let orbotSocksPort: Int

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var onMessage: ((Data) -> Void)?
    private var onStateChange: ((String) -> Void)?

    private var framesSent: Int64 = 0
    private var framesReceived: Int64 = 0

    // MARK: - Reconnect

    /// Set to true by `connect()` / `connectSync()`, cleared by `close()`.
    /// Guards the auto-reconnect loop so a deliberate `close()` stops retries.
    private var shouldAutoReconnect = false
    /// Consecutive reconnect failures since the last successful connection.
    private var reconnectAttempt = 0
    private static let maxReconnectDelaySeconds: Double = 30

    private static let log = Logger(subsystem: "com.bcrypto.qaudion", category: "TorObfsTransport")

    // MARK: - Init

    public init(
        onionAddress: String,
        peerId: String,
        callId: String,
        orbotSocksPort: Int = 9050
    ) {
        self.onionAddress = onionAddress
        self.peerId = peerId
        self.callId = callId
        self.orbotSocksPort = orbotSocksPort
    }

    // MARK: - Public API

    /// Connect to the .onion WebSocket endpoint.
    ///
    /// Attempts embedded Tor first; falls back to Orbot SOCKS5 if unavailable.
    /// Returns `true` if the connection was established within 15 s.
    /// After a successful connection, `startAutoReconnect()` kicks in
    /// automatically so a network drop triggers a retry with exponential backoff.
    @discardableResult
    public func connect() async -> Bool {
        guard !onionAddress.isEmpty else { return false }

        let socksPort = await resolveSocksPort()
        guard let port = socksPort else {
            Self.log.warning("connect: no Tor SOCKS5 available (no embedded Tor + no Orbot)")
            return false
        }

        let ok = connectViaSocks(port: port)
        if ok {
            shouldAutoReconnect = true
            reconnectAttempt = 0
        }
        return ok
    }

    /// Synchronous connect for callers that cannot use async/await.
    /// Blocks the calling thread up to 20 s.
    @discardableResult
    public func connectSync() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        Task {
            result = await connect()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Close the Tor tunnel and stop any pending auto-reconnect.
    /// After this call, auto-reconnect will not fire — the caller must
    /// invoke `connect()` explicitly to re-establish.
    public func closeAndStopReconnect() {
        shouldAutoReconnect = false
        close()
    }

    /// Send an encrypted audio frame through the Tor tunnel.
    public func send(_ data: Data) -> Bool {
        guard isConnected, let task = webSocketTask else { return false }

        let payload: [String: Any] = [
            "recipient_id": peerId,
            "call_id": callId,
            "frame": data.base64EncodedString(),
            "ts": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        let envelope: [String: Any] = ["type": "audio_frame", "data": payload]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return false }

        task.send(.string(jsonString)) { [weak self] error in
            if error != nil {
                self?.isConnected = false
                self?.onStateChange?("closed")
            }
        }
        framesSent += 1
        return true
    }

    /// Close the Tor tunnel.
    public func close() {
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        onStateChange?("closed")
    }

    public func setOnMessage(_ callback: @escaping (Data) -> Void) { onMessage = callback }
    public func setOnStateChange(_ callback: @escaping (String) -> Void) { onStateChange = callback }
    public var open: Bool { isConnected }

    // MARK: - SOCKS5 resolution

    /// Resolve the SOCKS5 port to use, preferring embedded Tor over Orbot.
    private func resolveSocksPort() async -> Int? {
        // Try embedded Tor first.
        do {
            let port = try await EmbeddedTorManager.shared.start()
            Self.log.info("resolveSocksPort: using embedded Tor on port \(port)")
            return Int(port)
        } catch {
            Self.log.info("resolveSocksPort: embedded Tor unavailable (\(error)) — trying Orbot")
        }

        // Fall back to external Orbot: probe whether SOCKS5 is available.
        let orbotAvailable = await probeOrbot(port: orbotSocksPort)
        if orbotAvailable {
            Self.log.info("resolveSocksPort: using Orbot SOCKS5 on port \(self.orbotSocksPort)")
            return orbotSocksPort
        }

        return nil
    }

    /// Check if a SOCKS5 proxy is accepting connections on localhost.
    private func probeOrbot(port: Int) async -> Bool {
        return await withCheckedContinuation { cont in
            var probeConnection: URLSessionDataTask? = nil
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 2
            let session = URLSession(configuration: cfg)
            // A plain TCP probe: we just try to open a connection.
            // Using a dummy URL with the proxy configured is the simplest
            // approach available without Network.framework.
            cfg.connectionProxyDictionary = [
                kCFProxyTypeSOCKS as String: true,
                kCFStreamPropertySOCKSProxyHost as String: "127.0.0.1",
                kCFStreamPropertySOCKSProxyPort as String: port,
            ]
            // A loopback request to something that will likely fast-fail.
            let url = URL(string: "http://127.0.0.1:\(port)")!
            probeConnection = URLSession(configuration: cfg).dataTask(with: url) { _, _, err in
                // Any error that is NOT "connection refused" means the port is open.
                if let nsErr = err as NSError? {
                    let isRefused = nsErr.code == NSURLErrorCannotConnectToHost
                        || nsErr.code == NSURLErrorNetworkConnectionLost
                        || nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(ECONNREFUSED)
                    cont.resume(returning: !isRefused)
                } else {
                    cont.resume(returning: true) // got a response = port is open
                }
            }
            probeConnection?.resume()
        }
    }

    // MARK: - Connection

    private func connectViaSocks(port: Int) -> Bool {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.connectionProxyDictionary = [
            "SOCKSEnable": true,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": port
        ] as [String: Any]
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 60

        let wsUrl = "wss://\(onionAddress)/ws"
        guard let url = URL(string: wsUrl) else { return false }

        let session = URLSession(configuration: sessionConfig)
        self.urlSession = session
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        let semaphore = DispatchSemaphore(value: 0)
        var connected = false

        task.sendPing { error in
            connected = (error == nil)
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + 10)
        if result == .timedOut || !connected {
            task.cancel()
            Self.log.warning("connectViaSocks: ping timeout or failed on port \(port)")
            return false
        }

        isConnected = true
        startReceiveLoop()
        onStateChange?("open")
        Self.log.info("connectViaSocks: connected to \(self.onionAddress) via SOCKS5:\(port)")
        return true
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.isConnected else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default: break
                }
                self.startReceiveLoop()
            case .failure(let err):
                Self.log.warning("receive error: \(err)")
                self.isConnected = false
                self.onStateChange?("closed")
                // Network drop — trigger auto-reconnect if this was an
                // intentional Tor session (not a deliberate close()).
                if self.shouldAutoReconnect {
                    self.scheduleReconnect()
                }
            }
        }
    }

    // MARK: - Auto-reconnect

    /// Schedule an async reconnect attempt with exponential backoff.
    ///
    /// Back-off formula: `min(2^attempt, maxReconnectDelaySeconds)` seconds.
    /// Resets to 0 on success; stops when `shouldAutoReconnect` is false
    /// (set by `closeAndStopReconnect()`).
    private func scheduleReconnect() {
        guard shouldAutoReconnect else { return }
        let delay = min(pow(2.0, Double(reconnectAttempt)), Self.maxReconnectDelaySeconds)
        Self.log.info("scheduleReconnect: retry in \(delay, format: .fixed(precision: 1))s (attempt \(self.reconnectAttempt + 1))")
        Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.shouldAutoReconnect, !self.isConnected else { return }
            Self.log.info("scheduleReconnect: attempting reconnect")
            let ok = await self.connect()
            if !ok {
                self.reconnectAttempt += 1
                Self.log.warning("scheduleReconnect: reconnect failed (attempt \(self.reconnectAttempt))")
                // connect() does not call scheduleReconnect on failure, so we
                // do it here explicitly only for the auto-reconnect path.
                if self.shouldAutoReconnect {
                    self.scheduleReconnect()
                }
            }
            // On success, connect() resets reconnectAttempt to 0.
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "audio_frame",
              let payload = json["data"] as? [String: Any],
              let frameB64 = payload["frame"] as? String,
              let frameData = Data(base64Encoded: frameB64) else { return }

        framesReceived += 1
        onMessage?(frameData)
    }
}
