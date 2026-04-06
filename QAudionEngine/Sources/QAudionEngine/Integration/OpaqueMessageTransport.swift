import Foundation

public final class OpaqueMessageTransport: SecureChannel, @unchecked Sendable {
    private let sendOpaque: (Data) async throws -> Void
    private let lock = NSLock()
    private var _isOpen = false
    private var callback: ((EncryptedFrame) -> Void)?
    private var _framesSent: Int64 = 0

    public init(sendOpaque: @escaping (Data) async throws -> Void) { self.sendOpaque = sendOpaque }

    public func open(config: ChannelConfig) { lock.lock(); _isOpen = true; lock.unlock() }
    public func close() { lock.lock(); _isOpen = false; lock.unlock() }

    public func send(_ frame: EncryptedFrame) {
        let data = FrameEncoder.serialize(frame)
        Task { try? await sendOpaque(data) }
        lock.lock(); _framesSent += 1; lock.unlock()
    }

    public func onOpaqueMessageReceived(_ data: Data) {
        guard let frame = try? FrameEncoder.deserialize(data) else { return }
        lock.lock(); let cb = callback; lock.unlock()
        cb?(frame)
    }

    public func setOnFrameReceived(_ callback: ((EncryptedFrame) -> Void)?) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    public func isOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return _isOpen }
    public func getStats() -> ChannelStats { lock.lock(); defer { lock.unlock() }; return ChannelStats(framesSent: _framesSent) }
    public func getMode() -> TransportMode { .doubleEncryption }
}
