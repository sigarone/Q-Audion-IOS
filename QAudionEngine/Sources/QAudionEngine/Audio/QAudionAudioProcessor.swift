import Foundation

public final class QAudionAudioProcessor {
    public let codec: OpusCodec
    public let jitterBuffer: JitterBuffer
    public var onRawPcmFrame: ((Data) -> Void)?
    public var onEncodedFrame: ((Data) -> Void)?
    private var isMuted = false

    /// W-FECDECODE (2026-08-25) — fired synchronously from `processIncoming`,
    /// BEFORE that call returns, whenever a single-frame wire gap let
    /// `codec.decodeFEC` reconstruct the frame immediately preceding the one
    /// `processIncoming` is about to return. The recovered frame is
    /// chronologically EARLIER than `processIncoming`'s own return value, so
    /// the caller must play it first — mirrors Android's
    /// `CallAudioBridge.registerDecodedOpusListener`, which plays the FEC
    /// reconstruction before decoding the carrying packet.
    public var onFecRecoveredPcm: ((Data) -> Void)?

    /// W-FECDECODE — wire sequence number of the last frame handed to
    /// `processIncoming`, or `nil` before the first one. Only ever moves
    /// FORWARD: a reordered/late frame (seq <= lastRxSeq) must not reset gap
    /// tracking backward, or a late arrival would be misread as a fresh gap
    /// on the next in-order frame. Mirrors Android's `lastRxAudioSeq`.
    private var lastRxSeq: UInt32?

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

    /// - Parameter sequenceNumber: this packet's WIRE sequence number, when
    ///   known. `nil` (the default) disables the W-FECDECODE gap check below
    ///   — every existing caller that does not pass one keeps today's
    ///   behaviour exactly, byte for byte.
    public func processIncoming(opusFrame: Data, sequenceNumber: UInt32? = nil) -> Data? {
        // W-FECDECODE (2026-08-25) — exactly ONE lost frame (seq == last+2):
        // this packet's LBRR carries a real reconstruction of the frame
        // between `lastRxSeq` and this one. Decode it FIRST — decoder state
        // is one serial stream, FEC frame then this frame, see `decodeFEC`'s
        // call-order contract — and hand it to the caller via
        // `onFecRecoveredPcm` before this method's own return. Gaps of 2+:
        // LBRR only ever covers the immediately previous frame, so this does
        // nothing and the older holes still fall to `decodePLC` via the
        // normal underrun/empty-body paths below.
        if let seq = sequenceNumber {
            if let last = lastRxSeq, seq == last &+ 2 {
                onFecRecoveredPcm?(codec.decodeFEC(opusFrame))
            }
            // Only advance on a genuine forward step. A reordered/late frame
            // (seq <= lastRxSeq) is still delivered normally below, but must
            // not move the watermark backward — doing so would make the next
            // in-order frame look like a fresh gap it is not.
            if let last = lastRxSeq {
                if seq > last { lastRxSeq = seq }
            } else {
                lastRxSeq = seq
            }
        }
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
