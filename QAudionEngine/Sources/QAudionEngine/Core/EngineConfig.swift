import Foundation

public struct EngineConfig: Equatable {
    public var enableOpusCodec: Bool
    public var enableGuardianMode: Bool
    public var enableVoiceAnalysis: Bool
    public var enableLogging: Bool
    public var sampleRate: Int
    public var opusBitrate: Int
    public var frameSize: Int
    public var deepfakeAnalysisRate: Int
    public var transportMode: TransportMode

    public init(enableOpusCodec: Bool = true, enableGuardianMode: Bool = true,
                enableVoiceAnalysis: Bool = true, enableLogging: Bool = false,
                sampleRate: Int = 48000, opusBitrate: Int = 32000,
                frameSize: Int = 20, deepfakeAnalysisRate: Int = 5,
                transportMode: TransportMode = .dataChannel) {
        self.enableOpusCodec = enableOpusCodec; self.enableGuardianMode = enableGuardianMode
        self.enableVoiceAnalysis = enableVoiceAnalysis; self.enableLogging = enableLogging
        self.sampleRate = sampleRate; self.opusBitrate = opusBitrate; self.frameSize = frameSize
        self.deepfakeAnalysisRate = deepfakeAnalysisRate; self.transportMode = transportMode
    }

    public static func production() -> EngineConfig { EngineConfig() }
    public static func development() -> EngineConfig { EngineConfig(enableLogging: true, transportMode: .loopback) }
    public static func highQuality() -> EngineConfig { EngineConfig(opusBitrate: 64000) }
    public static func lowLatency() -> EngineConfig { EngineConfig(opusBitrate: 24000, deepfakeAnalysisRate: 10) }
    public static func batteryOptimized() -> EngineConfig { EngineConfig(enableGuardianMode: false, enableVoiceAnalysis: false, deepfakeAnalysisRate: 20) }

    public func isValid() -> Bool { getValidationErrors().isEmpty }
    public func getValidationErrors() -> [String] {
        var errors: [String] = []
        if sampleRate != 48000 { errors.append("sampleRate must be 48000") }
        if opusBitrate < 6000 || opusBitrate > 510000 { errors.append("opusBitrate out of range") }
        if frameSize != 20 { errors.append("frameSize must be 20ms") }
        if deepfakeAnalysisRate < 1 { errors.append("deepfakeAnalysisRate must be >= 1") }
        return errors
    }
}
