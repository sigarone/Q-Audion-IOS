import Foundation

public struct EngineStats {
    public var sessionDurationMs: Int64 = 0
    public var framesTx: Int64 = 0
    public var framesRx: Int64 = 0
    /// W-PADOVERFLOW — TX frames whose encoder output exceeded the audio block
    /// and were therefore sent with a true-length header of zero (one frame of
    /// silence for the peer) instead of being sent in a larger packet.
    ///
    /// This must stay at zero in a correctly configured build: a non-zero value
    /// means the operating point (bitrate x frame duration) was chosen above
    /// what `AudioConstants.blockBytesStandard` can hold, and the call is
    /// silently losing audio. Reset per session with the rest of `EngineStats`;
    /// read it at call teardown.
    public var padOverflowFrames: Int64 = 0
    /// W-RXREORDER — inbound frames that arrived AFTER the ratchet had already
    /// stepped past their wire position, and were opened with a retained key
    /// instead of being discarded.
    ///
    /// Unlike `padOverflowFrames` a non-zero value here is NOT a defect: it is
    /// the measure of how much audio the unordered sealed-audio DataChannel
    /// (and the per-frame DataChannel/WS-relay alternation above it) reorders,
    /// and therefore how much audio this retention window is recovering. Every
    /// one of these was silently lost before 2026-08-13, along with every frame
    /// queued behind it. Read it at teardown next to `framesRx`: a ratio in the
    /// percent range is normal on a P2P call, zero means the call never left
    /// the ordered WS relay.
    public var framesRxReordered: Int64 = 0
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
