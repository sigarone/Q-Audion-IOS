import Foundation

/// Anti-DPI transport that tunnels audio frames through Tor SOCKS5 proxy.
/// Uses the .onion hidden service address of the BCrypto server.
/// Latency: ~300-500ms — used as last resort before giving up.
///
/// Requires Tor running on device (e.g., Orbot app providing SOCKS5 at 127.0.0.1:9050)
public final class TorObfsTransport: @unchecked Sendable {

    private let onionAddress: String
    private let peerId: String
    private let callId: String
    private let socksPort: Int

    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var onMessage: ((Data) -> Void)?
    private var onStateChange: ((String) -> Void)?

    private var framesSent: Int64 = 0
    private var framesReceived: Int64 = 0

    public init(onionAddress: String, peerId: String, callId: String, socksPort: Int = 9050) {
        self.onionAddress = onionAddress
        self.peerId = peerId
        self.callId = callId
        self.socksPort = socksPort
    }

    /// Connect to the .onion WebSocket endpoint through Tor SOCKS5 proxy
    public func connect() -> Bool {
        guard !onionAddress.isEmpty else { return false }

        // Configure URLSession with SOCKS5 proxy
        let proxyConfig: [AnyHashable: Any] = [
            kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
            kCFStreamPropertySOCKSProxyHost: "127.0.0.1",
            kCFStreamPropertySOCKSProxyPort: socksPort
        ]

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.connectionProxyDictionary = [
            "SOCKSEnable": true,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": socksPort
        ]
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 60

        let wsUrl = "wss://\(onionAddress)/ws"
        guard let url = URL(string: wsUrl) else { return false }

        let session = URLSession(configuration: sessionConfig)
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // Wait for connection (blocking with timeout)
        let semaphore = DispatchSemaphore(value: 0)
        var connected = false

        // Try sending a ping to verify connection
        task.sendPing { error in
            connected = (error == nil)
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + 10)
        if result == .timedOut || !connected {
            task.cancel()
            return false
        }

        isConnected = true
        startReceiveLoop()
        onStateChange?("open")
        return true
    }

    /// Send an encrypted audio frame through Tor tunnel
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

    /// Close the Tor tunnel
    public func close() {
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        onStateChange?("closed")
    }

    public func setOnMessage(_ callback: @escaping (Data) -> Void) { onMessage = callback }
    public func setOnStateChange(_ callback: @escaping (String) -> Void) { onStateChange = callback }
    public var open: Bool { isConnected }

    // MARK: - Private

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
                self.startReceiveLoop() // Continue listening
            case .failure:
                self.isConnected = false
                self.onStateChange?("closed")
            }
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
