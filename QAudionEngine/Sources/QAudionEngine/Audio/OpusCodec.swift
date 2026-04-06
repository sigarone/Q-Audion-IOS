import Foundation

public final class OpusCodec {
    public struct Config {
        public var bitrate: Int
        public var complexity: Int
        public var enableHpf: Bool
        public var enableAgc: Bool
        public init(bitrate: Int = AudioConstants.opusBitrate, complexity: Int = 5,
                    enableHpf: Bool = true, enableAgc: Bool = false) {
            self.bitrate = bitrate; self.complexity = complexity
            self.enableHpf = enableHpf; self.enableAgc = enableAgc
        }
        public static func secure() -> Config { Config(bitrate: 32000, complexity: 5, enableHpf: true) }
        public static func highQuality() -> Config { Config(bitrate: 64000, complexity: 10) }
        public static func lowLatency() -> Config { Config(bitrate: 24000, complexity: 3) }
    }
    private var config: Config
    private var framesEncoded: Int64 = 0
    private var framesDecoded: Int64 = 0

    public init(config: Config = .secure()) { self.config = config }

    public func encode(_ pcmFrame: Data) -> Data? {
        guard pcmFrame.count == AudioConstants.bytesPerFrame else { return nil }
        framesEncoded += 1
        return pcmFrame.prefix(min(100, pcmFrame.count))
    }
    public func decode(_ opusFrame: Data) -> Data? {
        guard !opusFrame.isEmpty else { return nil }
        framesDecoded += 1
        return Data(count: AudioConstants.bytesPerFrame)
    }
    public func decodePLC() -> Data { Data(count: AudioConstants.bytesPerFrame) }
    public func getStats() -> (encoded: Int64, decoded: Int64) { (framesEncoded, framesDecoded) }
    public func reconfigure(_ newConfig: Config) { config = newConfig }
}
