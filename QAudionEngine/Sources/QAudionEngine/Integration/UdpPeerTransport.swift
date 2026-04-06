import Foundation
import Network

public final class UdpPeerTransport: SecureChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var _isOpen = false
    private var callback: ((EncryptedFrame) -> Void)?
    private var _framesSent: Int64 = 0
    private var _framesReceived: Int64 = 0

    public init() {}

    public func open(config: ChannelConfig) { lock.lock(); _isOpen = true; lock.unlock() }

    public func connectToPeer(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let params = NWParameters.udp
        connection = NWConnection(to: endpoint, using: params)
        connection?.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.startReceiving() }
        }
        connection?.start(queue: .global())
    }

    public func send(_ frame: EncryptedFrame) {
        let data = FrameEncoder.serialize(frame)
        connection?.send(content: data, completion: .contentProcessed { _ in })
        lock.lock(); _framesSent += 1; lock.unlock()
    }

    public func close() {
        connection?.cancel(); connection = nil
        lock.lock(); _isOpen = false; lock.unlock()
    }

    public func setOnFrameReceived(_ callback: ((EncryptedFrame) -> Void)?) {
        lock.lock(); self.callback = callback; lock.unlock()
    }

    public func isOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return _isOpen }
    public func getStats() -> ChannelStats {
        lock.lock(); defer { lock.unlock() }
        return ChannelStats(framesSent: _framesSent, framesReceived: _framesReceived)
    }
    public func getMode() -> TransportMode { .dataChannel }

    private func startReceiving() {
        connection?.receiveMessage { [weak self] content, _, _, _ in
            guard let self, let data = content, let frame = try? FrameEncoder.deserialize(data) else {
                self?.startReceiving(); return
            }
            self.lock.lock(); self._framesReceived += 1; let cb = self.callback; self.lock.unlock()
            cb?(frame)
            self.startReceiving()
        }
    }
}
