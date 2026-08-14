import Foundation

public final class QAudionAudioProcessor {
    public let codec: OpusCodec
    public let jitterBuffer: JitterBuffer
    public var onRawPcmFrame: ((Data) -> Void)?
    public var onEncodedFrame: ((Data) -> Void)?
    private var isMuted = false

    /// W-LONGAUDIO (2026-08-10) — the jitter capacity is a DURATION, not a frame
    /// count. `jitterBufferMsWsRelay` is 160 ms, which is 8 frames at 20 ms
    /// (unchanged) and 3 at 60 ms. Sized in frames it would have been 480 ms of
    /// standing latency on a long-profile call.
    /// W-ALL60 (2026-08-14) — the default codec is built FOR the default
    /// profile, not from `OpusCodec`'s bare 20 ms defaults. A processor whose
    /// encoder disagreed with the call's profile rejects every `encode` and the
    /// call goes out silent at a perfectly constant rate, which is the failure
    /// this default exists to make unconstructible.
    public init(codec: OpusCodec = OpusCodec(config: OpusCodec.Config(profile: AudioProfile.defaultProfile)),
                jitterBufferMs: Int = AudioConstants.jitterBufferMsWsRelay) {
        self.codec = codec
        self.jitterBuffer = JitterBuffer(
            capacity: AudioConstants.framesForMs(jitterBufferMs,
                                                 frameDurationMs: codec.encodeFrameDurationMs),
            frameDurationMs: codec.encodeFrameDurationMs
        )
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
        // W-PADOVERFLOW (2026-08-10) — a zero-length body is the fleet's
        // "this packet carries no audio" convention (see `OpusCodec.fallbackEncode`
        // and `QAudionEngine.processOutgoingAudio`). Conceal it like the lost
        // frame it represents. Without this, `codec.decode` rejects the empty
        // frame, returns nil, and the `??` fallbacks upstream hand an EMPTY
        // buffer to the playout path as if it were PCM.
        guard !frame.isEmpty else { return codec.decodePLC() }
        return codec.decode(frame)
    }

    public func setMuted(_ muted: Bool) { isMuted = muted }
    public var muted: Bool { isMuted }

    private func generateComfortNoise() -> Data { jitterBuffer.generateComfortNoise() }
}
