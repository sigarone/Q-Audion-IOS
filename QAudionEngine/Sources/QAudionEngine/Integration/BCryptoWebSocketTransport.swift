import Foundation

public final class BCryptoWebSocketTransport: SecureChannel, @unchecked Sendable {
    private let wsClient: BCryptoWebSocketClient
    private let lock = NSLock()
    private var _isOpen = false
    private var recipientId: String?
    private var callback: ((EncryptedFrame) -> Void)?
    private var _framesSent: Int64 = 0
    private var _framesReceived: Int64 = 0

    public init(wsClient: BCryptoWebSocketClient) { self.wsClient = wsClient }

    public func open(config: ChannelConfig) {
        lock.lock(); _isOpen = true; lock.unlock()
        wsClient.registerHandler(type: "audio_frame") { [weak self] _, data in
            guard let self, let b64 = data["frame"] as? String, let frameData = Data(base64Encoded: b64) else { return }
            guard let frame = try? FrameEncoder.deserialize(frameData) else { return }
            self.lock.lock(); self._framesReceived += 1; let cb = self.callback; self.lock.unlock()
            cb?(frame)
        }
    }

    public func close() { lock.lock(); _isOpen = false; lock.unlock() }

    public func send(_ frame: EncryptedFrame) {
        guard let rid = recipientId else { return }
        let data = FrameEncoder.serialize(frame)
        wsClient.sendAudioFrame(recipientId: rid, frame: data)
        lock.lock(); _framesSent += 1; lock.unlock()
    }

    public func setOnFrameReceived(_ callback: ((EncryptedFrame) -> Void)?) {
        lock.lock(); self.callback = callback; lock.unlock()
    }

    public func setRecipientId(_ id: String) { recipientId = id }
    public func isOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return _isOpen }
    public func getStats() -> ChannelStats {
        lock.lock(); defer { lock.unlock() }
        return ChannelStats(framesSent: _framesSent, framesReceived: _framesReceived)
    }
    public func getMode() -> TransportMode { .dataChannel }
}
