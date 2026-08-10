import Foundation
import COpus

/// Opus codec using libopus C library via SPM COpus target.
/// Replaces the Phase 2 stub with real encode/decode calls.
public final class OpusCodec {

    public struct Config {
        public var bitrate: Int
        public var complexity: Int
        public var enableHpf: Bool
        public var enableAgc: Bool
        /// W-LONGAUDIO (2026-08-10) — the ENCODE frame duration for this call.
        ///
        /// Defaults to `AudioConstants.frameDurationMs` (20), so every existing
        /// construction site — including the four in this file's own `secure()`
        /// / `highQuality()` / `lowLatency()` presets — keeps producing exactly
        /// today's wire without being touched. It moves to 60 only when a call
        /// has NEGOTIATED the long profile and the send kill switch is on.
        ///
        /// This is the ENCODE side only. Decode never reads it: what a peer
        /// sends is not ours to assume (see `decode` and `decodePLC`).
        public var frameDurationMs: Int
        /// W-LONGAUDIO (2026-08-10) — the constant plaintext block this
        /// encoder's output has to fit inside. 120 by default.
        ///
        /// The codec owns the whole operating point (bitrate x frame duration x
        /// block) precisely so it can refuse to exceed it. §2.4's rule is that
        /// the ceiling must be impossible to exceed rather than merely unlikely,
        /// and the only place that can be enforced for EVERY bitrate source —
        /// the settings slider, the auto-tuner, a mid-call change — is here.
        public var blockBytes: Int
        public init(bitrate: Int = AudioConstants.opusBitrate, complexity: Int = 5,
                    enableHpf: Bool = true, enableAgc: Bool = false,
                    frameDurationMs: Int = AudioConstants.frameDurationMs,
                    blockBytes: Int = AudioConstants.blockBytesStandard) {
            self.bitrate = bitrate; self.complexity = complexity
            self.enableHpf = enableHpf; self.enableAgc = enableAgc
            self.frameDurationMs = frameDurationMs
            self.blockBytes = blockBytes
        }

        /// Build a config for a negotiated profile. The bitrate is clamped to
        /// what the profile's block can carry before it can reach libopus.
        public init(profile: AudioProfile,
                    bitrate: Int = AudioConstants.opusBitrate,
                    complexity: Int = 10,
                    enableHpf: Bool = true) {
            self.init(bitrate: min(bitrate, profile.maxBitrateBps),
                      complexity: complexity,
                      enableHpf: enableHpf,
                      enableAgc: false,
                      frameDurationMs: profile.frameDurationMs,
                      blockBytes: profile.blockBytes)
        }

        /// The highest bitrate whose CBR frame still fits `blockBytes` at
        /// `frameDurationMs`, in bps. 41600 at the 120-byte/20 ms default,
        /// 32000 at 256/60 — note the long profile's ceiling is LOWER, and
        /// has zero headroom.
        public var maxBitrateBps: Int {
            AudioConstants.maxBitrateForBlock(blockBytes: blockBytes,
                                              frameDurationMs: frameDurationMs)
        }

        /// PCM samples the encoder expects per `encode` call. 960 at 20 ms.
        public var samplesPerFrame: Int { AudioConstants.sampleRate / 1000 * frameDurationMs }
        /// PCM bytes the encoder expects per `encode` call. 1920 at 20 ms.
        public var bytesPerFrame: Int {
            samplesPerFrame * (AudioConstants.bitsPerSample / 8) * AudioConstants.channels
        }
        // W523: aligned with Android/firmware ecosystem — 32 kbps CBR
        // complexity 10. Higher bitrate would desynchronise the CBR
        // anti-traffic-analysis property (every device emits frames of
        // the SAME size). Quality improvement comes from complexity 10 +
        // PLR 30 % (FEC envelope) rather than raw bitrate.
        public static func secure() -> Config { Config(bitrate: 32000, complexity: 10, enableHpf: true) }
        public static func highQuality() -> Config { Config(bitrate: 64000, complexity: 10) }
        public static func lowLatency() -> Config { Config(bitrate: 24000, complexity: 3) }
    }

    private var encoder: OpaquePointer?
    private var decoder: OpaquePointer?
    private var config: Config
    private var framesEncoded: Int64 = 0
    private var framesDecoded: Int64 = 0
    private let maxEncodedSize: Int32 = 4000  // Max Opus frame bytes

    /// W-LONGAUDIO (2026-08-10) — duration of the last packet this decoder
    /// successfully decoded, in milliseconds, or 0 before the first one.
    ///
    /// The fallback input to concealment when libopus's own
    /// `OPUS_GET_LAST_PACKET_DURATION` is unavailable. Observed from the
    /// INBOUND stream, never from the negotiated profile: an endpoint that
    /// holds no negotiation state at all still conceals the right duration.
    private var lastDecodedDurationMs: Int = 0

    /// Read-only view of the observed inbound frame duration, in ms. 0 until
    /// the first successful decode. Exposed so the playout side can size its
    /// geometry from what is actually arriving.
    public var observedInboundFrameMs: Int { lastDecodedDurationMs }

    /// The ENCODE frame duration this codec is configured for, in ms.
    public var encodeFrameDurationMs: Int { config.frameDurationMs }

    public init(config: Config = .secure()) {
        self.config = config

        var error: Int32 = 0
        encoder = opus_encoder_create(Int32(AudioConstants.sampleRate),
            Int32(AudioConstants.channels), OPUS_APPLICATION_VOIP, &error)
        if error == OPUS_OK, let enc = encoder {
            // CBR mode (constant bitrate for anti-traffic-analysis).
            opus_helper_set_vbr(enc, Int32(0))
            opus_helper_set_bitrate(enc, Int32(config.bitrate))
            opus_helper_set_complexity(enc, Int32(config.complexity))
            // In-band FEC: encoder embeds redundancy in subsequent frames so
            // the decoder can reconstruct a lost frame from the next one.
            // Required for parity with Android (FEC on by default there).
            // 10 % PLR hint lets the encoder calibrate FEC overhead (~+5 %
            // effective bitrate) without exceeding the CBR budget.
            opus_helper_set_inband_fec(enc, Int32(1))
            // W523: PLR raised 10→30 % to match Android. The crackling
            // heard on iPad↔iPhone v1.0.521 was the encoder under-budgeting
            // FEC redundancy on WiFi micro-bursts of loss.
            opus_helper_set_packet_loss_perc(enc, Int32(30))
            // W528: align iOS encoder with Android byte-for-byte.
            // Android logs show OpusConfig(signalType=3001,
            // maxBandwidth=1105). 3001 = OPUS_SIGNAL_VOICE (tells the
            // encoder to bias toward SILK at low bitrates — important
            // for voice intelligibility), 1105 = OPUS_BANDWIDTH_FULLBAND.
            // Without these, iOS lets libopus auto-detect signal type
            // (occasionally picking music branch on noisy mic input) and
            // auto-bandwidth (narrower at 32 kbps), which is the
            // audible quality gap user reported on Android→iOS audio.
            opus_helper_set_signal(enc, Int32(OPUS_SIGNAL_VOICE))
            opus_helper_set_max_bandwidth(enc, Int32(OPUS_BANDWIDTH_FULLBAND))
            // W537: complete the Android-parity surface.
            //   - LSB_DEPTH=16: matches Android's `lsbDepth = 16` so the
            //     encoder's noise-shaping doesn't waste bits modelling
            //     quantization noise below bit-16 of our Int16 input.
            //   - DTX=0: explicit. User-reported quality issue from
            //     iPad→Android was an envelope-pumping artefact —
            //     making absolutely sure we're not silently triggering
            //     DTX at low input levels (which would chop the speech
            //     tail and the Android decoder would replay PLC noise).
            opus_helper_set_lsb_depth(enc, Int32(16))
            opus_helper_set_dtx(enc, Int32(0))
            // W-LONGAUDIO (2026-08-10) — state the frame duration instead of
            // letting libopus infer it from whatever `frame_size` we happen to
            // pass. The inference is what sizes a CBR packet, so leaving it
            // implicit means the encoder and the block-size arithmetic in
            // `AudioConstants` agree only by coincidence. At 20 ms this sets
            // OPUS_FRAMESIZE_20_MS, which is exactly what the inference already
            // produced — today's wire is unchanged, byte for byte.
            Self.applyExpertFrameDuration(enc, frameDurationMs: config.frameDurationMs)
        }


        decoder = opus_decoder_create(Int32(AudioConstants.sampleRate),
            Int32(AudioConstants.channels), &error)
    }

    deinit {
        if let enc = encoder { opus_encoder_destroy(enc) }
        if let dec = decoder { opus_decoder_destroy(dec) }
    }

    /// Encode PCM Int16 frame to Opus. Returns nil if the frame is the wrong
    /// size for the configured profile.
    ///
    /// W-LONGAUDIO — the expected size comes from `config.frameDurationMs`, not
    /// from the module-level `AudioConstants.bytesPerFrame`. At the default 20 ms
    /// the two are the same number and nothing changes; on a call that negotiated
    /// the long profile the encoder is fed 5760-byte frames and the constant
    /// would have rejected every one of them.
    public func encode(_ pcmFrame: Data) -> Data? {
        guard let enc = encoder else { return fallbackEncode(pcmFrame) }
        guard pcmFrame.count == config.bytesPerFrame else { return nil }

        var encoded = Data(count: Int(maxEncodedSize))
        // force-unwraps below are safe: pcmFrame.count == config.bytesPerFrame
        // (checked above, always > 0) and encoded was just allocated with
        // maxEncodedSize (fixed non-zero constant) — baseAddress is only nil for
        // an empty buffer.
        let result = pcmFrame.withUnsafeBytes { pcmBuf in
            encoded.withUnsafeMutableBytes { outBuf in
                opus_encode(enc,
                    // swiftlint:disable:next force_unwrapping
                    pcmBuf.baseAddress!.assumingMemoryBound(to: Int16.self),
                    Int32(config.samplesPerFrame),
                    // swiftlint:disable:next force_unwrapping
                    outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    maxEncodedSize)
            }
        }

        guard result > 0 else { return fallbackEncode(pcmFrame) }
        framesEncoded += 1
        return encoded.prefix(Int(result))
    }

    /// Decode Opus frame to PCM Int16. Returns nil if decoder unavailable or data empty.
    public func decode(_ opusFrame: Data) -> Data? {
        guard let dec = decoder else { return fallbackDecode(opusFrame) }
        guard !opusFrame.isEmpty else { return nil }

        // W-FRAMEAGNOSTIC (2026-08-10) — size the output for the LONGEST frame a
        // peer may send, not for the one we encode. `frame_size` here is opus.h's
        // "number of samples per channel of AVAILABLE SPACE in pcm", and the same
        // header states that when it is less than the packet's duration the
        // function "will not be capable of decoding some packets" — it returns
        // OPUS_BUFFER_TOO_SMALL. With 960 that is every 40/60 ms packet, on every
        // frame, for the whole call: `fallbackDecode` below then returns a
        // zero-filled buffer, so a peer on another profile or mid-rollout would
        // be rendered as perfect silence with nothing in any log.
        var pcm = Data(count: AudioConstants.maxBytesPerFrame)
        // force-unwraps below are safe: opusFrame is checked non-empty above,
        // pcm was just allocated with maxBytesPerFrame (fixed non-zero constant).
        let result = opusFrame.withUnsafeBytes { inBuf in
            pcm.withUnsafeMutableBytes { outBuf in
                opus_decode(dec,
                    // swiftlint:disable:next force_unwrapping
                    inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    Int32(opusFrame.count),
                    // swiftlint:disable:next force_unwrapping
                    outBuf.baseAddress!.assumingMemoryBound(to: Int16.self),
                    Int32(AudioConstants.maxSamplesPerFrame),
                    // W-IOSFECFLAG (2026-07-25) — MUST be 0. This is libopus'
                    // `decode_fec`, and it does NOT mean "use FEC if the frame
                    // happens to carry it". Set to 1 it decodes the packet's LBRR
                    // redundancy layer — a low-bitrate copy of the PREVIOUS frame —
                    // and does not decode the current primary frame at all; the
                    // CELT high band comes back as concealment because
                    // opus_decode_frame passes NULL for the payload. opus.h is
                    // explicit: "If no such data is available, the frame is decoded
                    // as if it were lost."
                    //
                    // So with 1, EVERY frame iOS rendered was the loss-recovery
                    // layer plus concealment instead of the transmitted signal:
                    // band-limited, quieter, one frame (20 ms) late, and degrading
                    // to pure PLC on any frame the sender did not protect. The
                    // decoder's SILK/CELT history never tracked the real signal
                    // either, so it compounded.
                    //
                    // Introduced by 8def381, "fix(compat): align iOS wire format
                    // and audio quality with Android" — which changed `0) // no FEC`
                    // to `1)` for parity, while Android passes 0 on both of its
                    // decode paths (opus_jni.c:408 and :424) and Desktop passes no
                    // FEC argument at all. It was a misreading of the opus.h
                    // contract, and it is the likeliest cause of the long-running
                    // "Android -> iOS audio sounds muffled/wrong" reports that were
                    // chased into the AGC and route layers instead.
                    //
                    // Real FEC recovery is a DIFFERENT operation: on a detected gap,
                    // recover frame N from packet N+1 with decode_fec=1, then decode
                    // N+1 normally with 0. That needs sequence-gap detection, which
                    // arrives with the playout jitter buffer (W-IOSJITTER).
                    0)
            }
        }

        guard result > 0 else { return fallbackDecode(opusFrame) }
        framesDecoded += 1
        // W-LONGAUDIO (2026-08-10) — remember how long this packet was. This is
        // the second-priority input to concealment (see `concealmentSamples`),
        // used when libopus's own last-packet-duration CTL is unavailable.
        // `result` is samples per channel; at 48 kHz, ms = samples / 48.
        lastDecodedDurationMs = Int(result) / (AudioConstants.sampleRate / 1000)
        // W-FRAMEAGNOSTIC — `opus_decode` returns the number of decoded samples
        // PER CHANNEL (opus.h: "@returns Number of decoded samples per
        // channel"), not bytes, so the length has to be reconstructed rather
        // than assumed. Returning the whole buffer unconditionally is invisible
        // while every packet is 20 ms — the trim below is then a no-op, 960
        // samples = 1920 bytes = the old constant — but the moment durations
        // differ it would staple 3840 zero bytes onto every frame.
        return pcm.prefix(Int(result) * AudioConstants.channels * (AudioConstants.bitsPerSample / 8))
    }

    /// Packet Loss Concealment — generate an interpolated frame for a lost packet.
    ///
    /// W-LONGAUDIO (2026-08-10) — the length is DERIVED, never assumed, and
    /// never taken from the negotiated profile.
    ///
    /// libopus gives `frame_size` two incompatible meanings. On a normal decode
    /// it is the CAPACITY of the output buffer, and passing more than the packet
    /// carries is harmless. In the PLC case (`data == NULL`) it is the DURATION
    /// to conceal — opus.h: "frame_size needs to be exactly the duration of
    /// audio that is missing, otherwise the decoder will not be in the optimal
    /// state to decode the next incoming packet." Those two readings pull in
    /// opposite directions, and getting the second one wrong is silent: conceal
    /// 60 ms into a 20 ms stream and playout runs 40 ms ahead of the sender on
    /// every concealed frame with every counter still green.
    ///
    /// The duration comes from the DECODER'S OWN STATE, in this order:
    ///   1. `OPUS_GET_LAST_PACKET_DURATION` — libopus's own record;
    ///   2. the decoded length of the last good frame we saw;
    ///   3. 20 ms.
    ///
    /// Deliberately NOT from the negotiated profile: block size and frame
    /// duration are independent axes, and this rule is correct on an endpoint
    /// that holds no negotiation state at all — which is every receiver, since
    /// receive is unconditional.
    public func decodePLC() -> Data {
        let samples = concealmentSamples()
        let bytes = samples * (AudioConstants.bitsPerSample / 8) * AudioConstants.channels
        guard let dec = decoder else { return Data(count: bytes) }
        var pcm = Data(count: bytes)
        pcm.withUnsafeMutableBytes { outBuf in
            // force-unwrap safe: `concealmentSamples()` never returns 0, so pcm
            // was allocated non-empty — baseAddress is only nil when empty.
            _ = opus_decode(dec, nil, 0,
                // swiftlint:disable:next force_unwrapping
                outBuf.baseAddress!.assumingMemoryBound(to: Int16.self),
                Int32(samples), 0)
        }
        return pcm
    }

    /// Samples of concealment to generate — the §2.5 priority order above.
    /// Never returns 0, and clamped to what a legal Opus frame can be so a
    /// nonsensical CTL result cannot size an allocation.
    private func concealmentSamples() -> Int {
        if let dec = decoder {
            var last: opus_int32 = 0
            let rc = opus_helper_get_last_packet_duration(dec, &last)
            if rc == OPUS_OK, last > 0, Int(last) <= AudioConstants.maxSamplesPerFrame {
                return Int(last)
            }
        }
        if lastDecodedDurationMs > 0, lastDecodedDurationMs <= AudioConstants.maxFrameDurationMs {
            return AudioConstants.sampleRate / 1000 * lastDecodedDurationMs
        }
        return AudioConstants.samplesPerFrame
    }

    /// Set `OPUS_SET_EXPERT_FRAME_DURATION` from a duration in ms. Only the
    /// durations this fleet can actually produce are mapped; anything else is
    /// left alone rather than guessed at, so an unexpected value degrades to
    /// libopus's inference (today's behaviour) instead of a wrong pin.
    private static func applyExpertFrameDuration(_ enc: OpaquePointer, frameDurationMs: Int) {
        let request: Int32?
        switch frameDurationMs {
        case 20: request = OPUS_FRAMESIZE_20_MS
        case 40: request = OPUS_FRAMESIZE_40_MS
        case 60: request = OPUS_FRAMESIZE_60_MS
        default: request = nil
        }
        if let request { _ = opus_helper_set_expert_frame_duration(enc, request) }
    }

    public func getStats() -> (encoded: Int64, decoded: Int64) { (framesEncoded, framesDecoded) }

    /// Apply a new operating point.
    ///
    /// W-LONGAUDIO (2026-08-10) — the bitrate is clamped to what the config's
    /// own block can carry BEFORE it reaches libopus. This is the last gate in
    /// front of the encoder and it is unconditional: a bitrate that overflows
    /// the block does not produce a bigger packet (that would be a
    /// content-correlated size channel), it produces a constant-size SILENT
    /// packet — the call connects, holds its rate, and transmits nothing. That
    /// failure is invisible from the outside, so the clamp is the only place it
    /// can be stopped.
    ///
    /// At the shipped operating point (32 kbps, 120 B, 20 ms → ceiling 41 kbps)
    /// this changes nothing. It does now clamp `Config.highQuality()`'s 64 kbps,
    /// which at 20 ms encodes 160 bytes into a 118-byte budget — that preset was
    /// already producing pure silence on the sealed path and is unused in
    /// production; clamping makes it merely quiet instead of mute.
    public func reconfigure(_ newConfig: Config) {
        var applied = newConfig
        applied.bitrate = min(newConfig.bitrate, newConfig.maxBitrateBps)
        config = applied
        if let enc = encoder {
            opus_helper_set_bitrate(enc, Int32(applied.bitrate))
            opus_helper_set_complexity(enc, Int32(applied.complexity))
            // FEC stays on across reconfigures — preserving Android parity.
            opus_helper_set_inband_fec(enc, Int32(1))
            // W-LONGAUDIO — a reconfigure may change the frame duration
            // (STANDARD <-> LONG is latched before capture starts, but the
            // encoder object outlives the latch), so re-pin it here too.
            Self.applyExpertFrameDuration(enc, frameDurationMs: applied.frameDurationMs)
        }
    }

    /// Update the expected packet-loss hint used by the FEC budget calculation.
    /// Safe to call at any time; no-op if the encoder was not created.
    public func setPacketLossPct(_ plp: Int) {
        guard let enc = encoder else { return }
        opus_helper_set_packet_loss_perc(enc, Int32(plp))
    }

    // MARK: - Fallback (if C library returns errors)

    /// W-PADOVERFLOW (2026-08-10) — the encoder produced nothing usable. Emit a
    /// SILENT FRAME: a zero-length body, which the wire layer turns into a
    /// normal-size packet with a true-length header of zero.
    ///
    /// What this replaces, and why it was worse than nothing: this returned
    /// `pcmFrame.prefix(100)` — one hundred bytes of RAW LITTLE-ENDIAN PCM,
    /// labelled as an Opus packet and handed to the seal. It fit under the block
    /// budget, so no counter fired and no log line appeared; the frame went out
    /// looking exactly like a healthy one. On the far end libopus read byte 0 of
    /// a PCM sample as a TOC byte, which decides mode, bandwidth, frame count and
    /// duration for the whole packet, and then parsed 99 bytes of audio samples
    /// as a range-coded bitstream. The outcomes are all bad and none of them are
    /// reported: a decode error swallowed into concealment, or — worse — a
    /// "successful" decode of noise at whatever duration the accidental TOC
    /// claimed, which also poisons `OPUS_GET_LAST_PACKET_DURATION` and therefore
    /// the concealment length of every frame after it.
    ///
    /// It is reached when the encoder failed to allocate (`encoder == nil`) or
    /// returned <= 0 — rare, but it is precisely the path that runs when
    /// something is already wrong, so it must degrade honestly.
    ///
    /// A zero-length body is the convention the rest of this stack already
    /// speaks: `QAudionEngine.processOutgoingAudio` pads it to the full constant
    /// block with a length header of 0, and `processIncomingAudio` treats a
    /// zero-length body as a lost frame and conceals it. Constant size,
    /// constant rate, one frame of missing audio, and a counter that says so.
    ///
    /// Returns non-nil deliberately: `nil` propagates through
    /// `QAudionAudioProcessor.processOutgoing` into the `?? pcmFrame` fallback in
    /// `processOutgoingAudio`, which would seal the FULL raw PCM frame — the same
    /// defect, one layer up.
    private func fallbackEncode(_ pcmFrame: Data) -> Data? {
        framesEncoded += 1
        encoderFallbackFrames &+= 1
        return Data()
    }

    /// Frames that went out silent because `fallbackEncode` ran. Must stay at
    /// zero on a healthy call; non-zero means the encoder is not working and the
    /// peer is hearing nothing, which is otherwise indistinguishable from a
    /// quiet room.
    public private(set) var encoderFallbackFrames: Int64 = 0

    /// The decoder could not produce audio for a packet that DOES exist —
    /// `decoder == nil`, or `opus_decode` returned <= 0 (a corrupt packet, or
    /// one longer than the 2880-sample capacity). Emit one frame of silence.
    ///
    /// W-LONGAUDIO (2026-08-10) — the LENGTH is derived, exactly as in
    /// `decodePLC`, and for exactly the same reason. This used to return
    /// `AudioConstants.bytesPerFrame` — a hardcoded 1920 bytes / 20 ms —
    /// whatever the inbound stream's duration was. On a 60 ms stream a single
    /// bad packet then produced a 20 ms buffer, and the receive path believes
    /// what it is handed: `AudioCapture.noteInboundFrameDuration` reads the
    /// buffer length as a genuine duration CHANGE and re-derives all eleven
    /// playout watermarks to the 20 ms set while the queue still holds 60 ms
    /// frames, then flips them all back on the next good frame. One corrupt
    /// packet, a 40 ms hole in playout and a full watermark re-derivation.
    ///
    /// `concealmentSamples()` is the §2.5 priority order —
    /// `OPUS_GET_LAST_PACKET_DURATION`, then the last decoded PCM length, then
    /// 20 ms — and never the negotiated profile, so this stays correct on a
    /// receiver that holds no negotiation state at all. On a 20 ms stream every
    /// branch of it yields 960 samples, so this returns the same 1920 bytes it
    /// always did: the default path is unchanged, byte for byte.
    private func fallbackDecode(_ opusFrame: Data) -> Data? {
        guard !opusFrame.isEmpty else { return nil }
        framesDecoded += 1
        let samples = concealmentSamples()
        return Data(count: samples * (AudioConstants.bitsPerSample / 8) * AudioConstants.channels)
    }
}
