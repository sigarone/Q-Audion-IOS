import Foundation

public final class QAudionAudioProcessor {
    public let codec: OpusCodec
    public let jitterBuffer: JitterBuffer
    public var onRawPcmFrame: ((Data) -> Void)?
    public var onEncodedFrame: ((Data) -> Void)?
    private var isMuted = false

    public init(codec: OpusCodec = OpusCodec(), jitterBufferCapacity: Int = AudioConstants.jitterBufferFramesWsRelay) {
        self.codec = codec; self.jitterBuffer = JitterBuffer(capacity: jitterBufferCapacity)
    }

    public func processOutgoing(pcmFrame: Data) -> Data? {
        onRawPcmFrame?(pcmFrame)
        guard !isMuted else { return codec.encode(generateComfortNoise()) }
        guard let encoded = codec.encode(pcmFrame) else { return nil }
        onEncodedFrame?(encoded)
        return encoded
    }

    public func processIncoming(opusFrame: Data) -> Data? {
        jitterBuffer.push(opusFrame)
        guard let frame = jitterBuffer.pop() else { return codec.decodePLC() }
        return codec.decode(frame)
    }

    public func setMuted(_ muted: Bool) { isMuted = muted }
    public var muted: Bool { isMuted }

    private func generateComfortNoise() -> Data { jitterBuffer.generateComfortNoise() }
}
