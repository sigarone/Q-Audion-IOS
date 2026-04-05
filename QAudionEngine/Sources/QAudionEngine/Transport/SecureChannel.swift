import Foundation

public enum TransportMode { case dataChannel; case doubleEncryption; case loopback }

public struct ChannelConfig {
    public let mode: TransportMode
    public let maxBandwidthKbps: Int
    public let reliableDelivery: Bool
    public init(mode: TransportMode, maxBandwidthKbps: Int = TransportConstants.defaultMaxBandwidthKbps, reliableDelivery: Bool = true) {
        precondition(maxBandwidthKbps > 0)
        self.mode = mode; self.maxBandwidthKbps = maxBandwidthKbps; self.reliableDelivery = reliableDelivery
    }
}

public struct ChannelStats {
    public let framesSent: Int64; public let framesReceived: Int64; public let framesLost: Int64
    public let avgLatencyMs: Double; public let jitterMs: Double; public let timestampMs: Int64
    public init(framesSent: Int64 = 0, framesReceived: Int64 = 0, framesLost: Int64 = 0,
                avgLatencyMs: Double = 0, jitterMs: Double = 0,
                timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.framesSent = framesSent; self.framesReceived = framesReceived; self.framesLost = framesLost
        self.avgLatencyMs = avgLatencyMs; self.jitterMs = jitterMs; self.timestampMs = timestampMs
    }
}

public protocol SecureChannel: AnyObject {
    func open(config: ChannelConfig)
    func close()
    func send(_ frame: EncryptedFrame)
    func setOnFrameReceived(_ callback: ((EncryptedFrame) -> Void)?)
    func isOpen() -> Bool
    func getStats() -> ChannelStats
    func getMode() -> TransportMode
}
