import Foundation

public final class LoopbackTransport: SecureChannel, @unchecked Sendable {
    private let simulatedLatencyMs: Int64
    private let packetLossPercent: Int
    private let lock = NSLock()
    private var _isOpen = false
    private var _framesSent: Int64 = 0
    private var _framesReceived: Int64 = 0
    private var _framesLost: Int64 = 0
    private var onFrameReceivedCallback: ((EncryptedFrame) -> Void)?
    private let deliveryQueue = DispatchQueue(label: "com.bcrypto.loopback", attributes: .concurrent)

    public init(simulatedLatencyMs: Int64 = 0, packetLossPercent: Int = 0) {
        precondition(simulatedLatencyMs >= 0); precondition(packetLossPercent >= 0 && packetLossPercent <= 100)
        self.simulatedLatencyMs = simulatedLatencyMs; self.packetLossPercent = packetLossPercent
    }
    public func open(config: ChannelConfig) {
        lock.lock(); defer { lock.unlock() }
        guard !_isOpen else { return }
        _isOpen = true; _framesSent = 0; _framesReceived = 0; _framesLost = 0
    }
    public func close() { lock.lock(); _isOpen = false; lock.unlock() }
    public func send(_ frame: EncryptedFrame) {
        lock.lock()
        precondition(_isOpen, "Channel not open")
        _framesSent += 1
        if packetLossPercent > 0 && Int.random(in: 0..<100) < packetLossPercent {
            _framesLost += 1; lock.unlock(); return
        }
        let callback = onFrameReceivedCallback; lock.unlock()
        deliveryQueue.asyncAfter(deadline: .now() + .milliseconds(Int(simulatedLatencyMs))) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self._isOpen else { self.lock.unlock(); return }
            self._framesReceived += 1; self.lock.unlock()
            callback?(frame)
        }
    }
    public func setOnFrameReceived(_ callback: ((EncryptedFrame) -> Void)?) {
        lock.lock(); onFrameReceivedCallback = callback; lock.unlock()
    }
    public func isOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return _isOpen }
    public func getStats() -> ChannelStats {
        lock.lock(); defer { lock.unlock() }
        return ChannelStats(framesSent: _framesSent, framesReceived: _framesReceived,
            framesLost: _framesLost, avgLatencyMs: Double(simulatedLatencyMs))
    }
    public func getMode() -> TransportMode { .loopback }
}
