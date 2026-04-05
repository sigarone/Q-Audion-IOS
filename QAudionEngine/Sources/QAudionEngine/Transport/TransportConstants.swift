import Foundation

/// Transport layer constants. All values match Android `TransportConstants.kt` exactly.
public enum TransportConstants {
    public static let frameVersion: UInt8 = 0x01
    public static let headerSize = 29
    public static let nonceSize = 12
    public static let tagSize = 16
    public static let maxPayloadSize = 4096
    public static let minPayloadSize = 0
    public static let flagHasDeepfakeScore: UInt8 = 0x01
    public static let flagIsKeyRatchet: UInt8 = 0x02
    public static let flagIsComfortNoise: UInt8 = 0x04
    public static let flagsValidMask: UInt8 = 0x07
    public static let comfortNoiseIntervalMs: Int64 = 20
    public static let maxOutOfOrderFrames = 50
    public static let statsWindowMs: Int64 = 5000
    public static let backpressureThreshold = 100
    public static let sendTimeoutMs: Int64 = 5000
    public static let defaultMaxBandwidthKbps = 64
    public static let datachannelOrdered = true
    public static let datachannelMaxRetransmitTimeMs = 3000
    public static let seqNumMax: UInt32 = 0xFFFFFFFF
    public static let seqNumWindow = 64
    public static let maxAcceptableJitterMs = 100.0
    public static let maxAcceptableLatencyMs = 150.0
    public static let sendFailureThreshold = 5
    public static let retryDelayMs: Int64 = 1000
    public static let minFrameSize = headerSize + tagSize
    public static let maxFrameSize = headerSize + maxPayloadSize + tagSize + 4
    public static let deepfakeScoreMin: Float = 0.0
    public static let deepfakeScoreMax: Float = 1.0
    public static let deepfakeDetectionThreshold: Float = 0.5
}
