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

    // ── W-LONGAUDIO (2026-08-10): frame counts are durations in disguise ──
    //
    // Every constant below was chosen as a DURATION and then written down as a
    // number of frames, because there was only ever one frame duration. The
    // moment a second one exists that arithmetic is silently wrong by 3x: a
    // "150 frame" relay buffer is 3 s at 20 ms and 9 s at 60 ms, and nothing
    // in the type system notices.
    //
    // The millisecond value is now the constant and the frame count is derived
    // at the point of use. The old names are kept as derived properties so no
    // call site has to move and so the two can never disagree.

    /// Jitter depth for a direct peer-to-peer path: 60 ms.
    public static let jitterBufferMsP2P = 60
    /// Jitter depth for the WS relay: 160 ms.
    public static let jitterBufferMsWsRelay = 160
    /// Jitter depth for the store-and-forward signal relay: 3 s.
    public static let jitterBufferMsSignalRelay = 3000
    /// Playback ring depth: 200 ms.
    public static let playbackRingBufferMs = 200

    /// Frames covering `ms` at `frameDurationMs`, rounded to NEAREST and never
    /// below 1.
    ///
    /// Rounding, not truncation, is load-bearing. Two watermarks 20 ms apart
    /// (140 and 160) both floor to 2 frames at 60 ms and stop being two
    /// watermarks at all — a tier boundary that silently ceases to exist is
    /// exactly the class of bug this profile is most likely to introduce.
    /// At 20 ms every value in this file is an exact multiple, so rounding is
    /// provably a no-op there and today's numbers are unchanged.
    public static func framesForMs(_ ms: Int, frameDurationMs: Int = AudioConstants.frameDurationMs) -> Int {
        guard frameDurationMs > 0 else { return 1 }
        return max(1, (ms + frameDurationMs / 2) / frameDurationMs)
    }

    /// 3 at 20 ms — unchanged.
    public static var jitterBufferFramesP2P: Int { framesForMs(jitterBufferMsP2P) }
    /// 8 at 20 ms — unchanged.
    public static var jitterBufferFramesWsRelay: Int { framesForMs(jitterBufferMsWsRelay) }
    /// 150 at 20 ms — unchanged.
    public static var jitterBufferFramesSignalRelay: Int { framesForMs(jitterBufferMsSignalRelay) }
    /// 10 at 20 ms — unchanged.
    public static var playbackRingBufferFrames: Int { framesForMs(playbackRingBufferMs) }

    public static let comfortNoiseAmplitude: Int16 = 100
}

/// W-LONGAUDIO (2026-08-10) — the two audio wire profiles, as one value.
///
/// A profile is exactly two independent numbers — how long a frame is, and how
/// big the constant plaintext block that carries it is — plus everything
/// derivable from them. They are independent axes on purpose: a 40 ms frame
/// fits today's 120-byte block, so neither number may ever be inferred from
/// the other.
///
/// `standard` is what every build ships and what every un-negotiated call
/// uses. `long60x256` is reached ONLY through capability negotiation with a
/// peer that advertised it (see `CallCapabilities.resolveAudioProfile`), and
/// only in a build whose send kill switch is on. There is no third profile and
/// no way to construct an arbitrary one from outside this file: the memberwise
/// initialiser is private so a stray `AudioProfile(frameDurationMs: 33, ...)`
/// cannot appear in a call path.
///
/// Mirrors Kotlin `com.bcrypto.qaudion.audio.AudioProfile` and the Desktop
/// `AudioProfile` object. All arithmetic below is `AudioConstants`', so the
/// three platforms cannot compute different sizes from the same profile.
public struct AudioProfile: Equatable, Sendable {
    /// Opus frame duration in milliseconds. 20 or 60.
    public let frameDurationMs: Int
    /// Total constant plaintext block: 2-byte length header + Opus frame +
    /// CSPRNG filler. 120 or 256.
    public let blockBytes: Int

    private init(frameDurationMs: Int, blockBytes: Int) {
        self.frameDurationMs = frameDurationMs
        self.blockBytes = blockBytes
    }

    /// Today's profile, and the only one a build sends without negotiating:
    /// 20 ms frames in a 120-byte block at 32 kbps CBR.
    public static let standard = AudioProfile(frameDurationMs: 20, blockBytes: AudioConstants.blockBytesStandard)

    /// `aprof-60x256-v1`: 60 ms frames in a 256-byte block at 32 kbps CBR.
    /// Same audio quality as `standard`; a third of the packets, and therefore
    /// a third of the fixed 67 bytes of seal and envelope per packet.
    public static let long60x256 = AudioProfile(frameDurationMs: 60, blockBytes: AudioConstants.blockBytesLong)

    /// PCM samples in one frame of this profile. 960 / 2880.
    public var samplesPerFrame: Int { AudioConstants.sampleRate / 1000 * frameDurationMs }

    /// PCM bytes in one frame of this profile (mono S16). 1920 / 5760.
    public var bytesPerFrame: Int { samplesPerFrame * (AudioConstants.bitsPerSample / 8) * AudioConstants.channels }

    /// Bytes the Opus CBR frame occupies inside the block. 80 / 240.
    public func opusBytes(bitrateBps: Int = AudioConstants.opusBitrate) -> Int {
        AudioConstants.opusCbrBytes(bitrateBps: bitrateBps, frameDurationMs: frameDurationMs)
    }

    /// The highest bitrate whose frame still fits this profile's block, in bps.
    /// 41600 for `standard`, 32000 for `long60x256`.
    ///
    /// Note the direction: the LONG profile's ceiling is LOWER than the
    /// standard one's, and it has exactly zero headroom — 32 kbps at 60 ms is
    /// 240 bytes against a 240-byte budget. Every bitrate that reaches the
    /// encoder must be clamped with the ACTIVE profile's numbers, never with
    /// the defaults, or a user preference of 40 kbps overflows every single
    /// frame and the call degrades to constant-rate silence.
    public var maxBitrateBps: Int {
        AudioConstants.maxBitrateForBlock(blockBytes: blockBytes, frameDurationMs: frameDurationMs)
    }

    /// Clamp `kbps` to what this profile's block can carry.
    public func clamp(kbps: Int) -> Int {
        AudioConstants.clampToBlock(kbps, blockBytes: blockBytes, frameDurationMs: frameDurationMs)
    }

    /// Frames covering `ms` at this profile's frame duration, rounded to
    /// nearest, never below 1.
    public func framesForMs(_ ms: Int) -> Int {
        AudioConstants.framesForMs(ms, frameDurationMs: frameDurationMs)
    }
}
