import Foundation

public enum AudioConstants {
    public static let sampleRate = 48000
    public static let channels = 1
    public static let bitsPerSample = 16
    public static let frameDurationMs = 20
    public static let samplesPerFrame = (sampleRate * frameDurationMs) / 1000
    public static let bytesPerFrame = samplesPerFrame * (bitsPerSample / 8) * channels
    // W523: 32 kbps CBR — matches Android (`OpusConfig.bitrate=32000`)
    // and firmware (`QA_OPUS_BITRATE_DEFAULT=32000`). The whole
    // ecosystem ships frames of the same on-wire size for traffic-
    // analysis resistance — bumping iOS to 64 kbps would have broken
    // that property (different frame sizes ⇒ device fingerprintable).
    public static let opusBitrate = 32000

    // W-FRAMEAGNOSTIC (2026-08-10) — the longest frame this decoder must be
    // able to RECEIVE, in milliseconds, and the buffer that holds it.
    //
    // `frameDurationMs` is what we ENCODE at. It is not what we may be SENT.
    // A peer on a different profile, a client mid-rollout, or any future
    // negotiated long-frame profile can legitimately deliver a 40 or 60 ms
    // packet, and Opus supports up to 120 ms. Sizing the decode buffer from the
    // encode constant makes every such packet fail OPUS_BUFFER_TOO_SMALL — one
    // failure per inbound frame, i.e. total silence, on an otherwise valid call
    // (iOS `OpusCodec.decode` then falls back to a zero-filled frame, so the
    // failure is not even audible as an error, only as nothing).
    //
    // Decode paths therefore allocate from these constants, never from
    // `bytesPerFrame`. Encode input stays pinned to `bytesPerFrame`, because
    // that side is ours and libopus wants the exact configured frame size.
    //
    // 60 ms rather than Opus's full 120 ms: it covers every profile in the
    // plan, and the buffer is per-decode-call, so unused headroom is not free.
    // Raise it here, in one place, if a longer profile is ever adopted.
    public static let maxFrameDurationMs = 60

    /// Samples in the longest receivable frame: 48000 / 1000 * 60 = 2880.
    public static let maxSamplesPerFrame = (sampleRate * maxFrameDurationMs) / 1000

    /// Bytes in the longest receivable frame: 2880 samples * 2 = 5760.
    public static let maxBytesPerFrame = maxSamplesPerFrame * (bitsPerSample / 8) * channels

    // ---- W-BLOCKSIZE (2026-08-10): the audio block and its bitrate ceiling ----
    //
    // Terminology, because the old wording caused real confusion: the BLOCK is
    // the TOTAL plaintext an audio frame occupies before encryption — 2 bytes
    // of big-endian true-length header, then the Opus frame, then CSPRNG filler
    // up to the block size. It is NOT "the amount of padding". Today's 120-byte
    // block carries an 80-byte frame at 32 kbps / 20 ms, so 38 bytes of every
    // packet are filler.
    //
    // The block must be constant (that is the whole security property) and at
    // least as large as the frame, and nothing more. Sized above the frame it
    // wastes bandwidth; sized below, frames overflow.
    //
    // Mirrors `AudioConstants.kt` on Android byte-for-byte — the two must agree
    // or a cross-platform call disagrees about what fits.

    /// True-length header carried inside the block. Mirrors the sealed-audio
    /// wire in `QAudionEngine.processOutgoingAudio` / `processIncomingAudio`.
    public static let lengthHeaderBytes = 2

    /// Bytes deliberately left unused at the top of the block.
    ///
    /// Not for encoder jitter — there is none (see `opusCbrBytes`). It exists
    /// so the bitrate can be raised later without another fleet-wide format
    /// migration, and so a mistake lands in slack rather than in a lost frame.
    public static let blockSafetyBytes = 14

    /// Block size in use today, and the only one any peer currently accepts.
    public static let blockBytesStandard = 120

    /// Block for the negotiated long-frame profile: 2 header + 240 audio
    /// (32 kbps at 60 ms, i.e. TODAY'S quality) + 14 spare. The saving comes
    /// from sending a third of the packets — a third of the fixed per-packet
    /// seal and envelope overhead — not from a smaller codec.
    ///
    /// NOT the default: changing the block is a wire-format change every
    /// platform must agree on, so it ships behind capability negotiation.
    /// Flipping it unilaterally breaks every call with an un-upgraded peer
    /// instantly.
    public static let blockBytesLong = 256

    /// Bytes an Opus CBR frame occupies, exactly.
    ///
    /// Verified against the libopus vendored in this repo rather than assumed:
    /// `Sources/COpus/src/opus_src/opus_encoder.c:1330` computes
    /// `cbr_bytes = IMIN((bitrate_to_bits(bitrate, Fs, frame_size) + 4) / 8, max_data_bytes)`
    /// once, clamps `max_data_bytes` to it (:1333) and pads the packet up to it,
    /// so EVERY packet is exactly this size — not approximately. There is no
    /// per-packet variation to absorb, so a safety margin is not there to cover
    /// rounding.
    ///
    /// The expression below is Android's `AudioConstants.opusCbrBytes` verbatim
    /// (both reduce to `round(bitrate / (8 * frameRate))`, and both give 80 at
    /// 32 kbps / 20 ms and 240 at 32 kbps / 60 ms); keeping it character-for-
    /// character identical is what stops the two platforms from drifting.
    public static func opusCbrBytes(bitrateBps: Int, frameDurationMs: Int) -> Int {
        let frameSizeSamples = sampleRate / 1000 * frameDurationMs
        let frameRate12 = 12 * sampleRate / frameSizeSamples
        return (12 * bitrateBps / 8 + frameRate12 / 2) / frameRate12
    }

    /// The highest bitrate whose frame still fits `blockBytes`, in bps.
    ///
    /// This is the ceiling every bitrate decision must respect. It is the real
    /// hazard: the frame size is deterministic, but the BITRATE is not fixed
    /// for the life of a call (`AudioAutoTuner` moves it between calls and
    /// `reconfigureAudioCodec` can move it mid-call), and a bitrate raised past
    /// the block is what overflows.
    ///
    /// Deriving it instead of hand-picking a constant means the two can never
    /// drift apart.
    public static func maxBitrateForBlock(blockBytes: Int, frameDurationMs: Int) -> Int {
        let usable = blockBytes - lengthHeaderBytes - blockSafetyBytes
        let frameSizeSamples = sampleRate / 1000 * frameDurationMs
        let frameRate12 = 12 * sampleRate / frameSizeSamples
        // Inverse of opusCbrBytes, floored so the result always fits.
        return usable * frameRate12 * 8 / 12
    }

    /// W-BLOCKSIZE — the single gate every bitrate must pass.
    ///
    /// A frame larger than the block used to be sent in a BIGGER packet (see
    /// `QAudionEngine.processOutgoingAudio`), which put a content-correlated
    /// size on a constant-size stream; it now degrades to a silent frame, which
    /// is still lost audio. Neither should ever happen, and the way to
    /// guarantee that is to make the ceiling impossible to exceed rather than
    /// merely unlikely.
    ///
    /// Applied to every source of a bitrate: the persisted preference, the
    /// post-call auto-tuner, and any mid-call change.
    public static func clampToBlock(
        _ kbps: Int,
        blockBytes: Int = AudioConstants.blockBytesStandard,
        frameDurationMs: Int = AudioConstants.frameDurationMs
    ) -> Int {
        let ceilingKbps = maxBitrateForBlock(blockBytes: blockBytes,
                                             frameDurationMs: frameDurationMs) / 1000
        return min(max(kbps, 1), max(1, ceilingKbps))
    }

    public static let jitterBufferFramesP2P = 3
    public static let jitterBufferFramesWsRelay = 8
    public static let jitterBufferFramesSignalRelay = 150
    public static let playbackRingBufferFrames = 10
    public static let comfortNoiseAmplitude: Int16 = 100
}
