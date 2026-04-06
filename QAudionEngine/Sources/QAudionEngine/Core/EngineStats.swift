import Foundation

public struct EngineStats {
    public var sessionDurationMs: Int64 = 0
    public var framesTx: Int64 = 0
    public var framesRx: Int64 = 0
    public var avgEncryptionMs: Double = 0
    public var avgDecryptionMs: Double = 0
    public var keyRatchetCount: Int64 = 0
    public var avgDeepfakeConfidence: Float = 0.5
    public var trustReport: TrustReport?

    public enum ThreatLevel: String { case safe; case uncertain; case suspicious; case critical }

    public var threatLevel: ThreatLevel {
        if avgDeepfakeConfidence >= 0.8 { return .safe }
        if avgDeepfakeConfidence >= 0.5 { return .uncertain }
        if avgDeepfakeConfidence >= 0.3 { return .suspicious }
        return .critical
    }

    public func calculateFrameRate() -> Double {
        guard sessionDurationMs > 0 else { return 0 }
        return Double(framesTx) / (Double(sessionDurationMs) / 1000.0)
    }

    public func isPerformanceHealthy() -> Bool {
        avgEncryptionMs < 5.0 && avgDecryptionMs < 5.0
    }

    public init() {}
}
