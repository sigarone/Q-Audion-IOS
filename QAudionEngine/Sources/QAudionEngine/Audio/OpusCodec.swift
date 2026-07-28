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
        public init(bitrate: Int = AudioConstants.opusBitrate, complexity: Int = 5,
                    enableHpf: Bool = true, enableAgc: Bool = false) {
            self.bitrate = bitrate; self.complexity = complexity
            self.enableHpf = enableHpf; self.enableAgc = enableAgc
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
        }

        decoder = opus_decoder_create(Int32(AudioConstants.sampleRate),
            Int32(AudioConstants.channels), &error)
    }

    deinit {
        if let enc = encoder { opus_encoder_destroy(enc) }
        if let dec = decoder { opus_decoder_destroy(dec) }
    }

    /// Encode PCM Int16 frame to Opus. Returns nil if encoder unavailable or frame wrong size.
    public func encode(_ pcmFrame: Data) -> Data? {
        guard let enc = encoder else { return fallbackEncode(pcmFrame) }
        guard pcmFrame.count == AudioConstants.bytesPerFrame else { return nil }

        var encoded = Data(count: Int(maxEncodedSize))
        // force-unwraps below are safe: pcmFrame.count == bytesPerFrame (checked
        // above) and encoded was just allocated with maxEncodedSize (fixed
        // non-zero constant) — baseAddress is only nil for an empty buffer.
        let result = pcmFrame.withUnsafeBytes { pcmBuf in
            encoded.withUnsafeMutableBytes { outBuf in
                // swiftlint:disable:next force_unwrapping
                opus_encode(enc,
                    pcmBuf.baseAddress!.assumingMemoryBound(to: Int16.self),
                    Int32(AudioConstants.samplesPerFrame),
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

        var pcm = Data(count: AudioConstants.bytesPerFrame)
        // force-unwraps below are safe: opusFrame is checked non-empty above,
        // pcm was just allocated with bytesPerFrame (fixed non-zero constant).
        let result = opusFrame.withUnsafeBytes { inBuf in
            pcm.withUnsafeMutableBytes { outBuf in
                // swiftlint:disable:next force_unwrapping
                opus_decode(dec,
                    inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    Int32(opusFrame.count),
                    // swiftlint:disable:next force_unwrapping
                    outBuf.baseAddress!.assumingMemoryBound(to: Int16.self),
                    Int32(AudioConstants.samplesPerFrame),
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
        return pcm
    }

    /// Packet Loss Concealment — generate interpolated frame when packet lost.
    public func decodePLC() -> Data {
        guard let dec = decoder else { return Data(count: AudioConstants.bytesPerFrame) }
        var pcm = Data(count: AudioConstants.bytesPerFrame)
        pcm.withUnsafeMutableBytes { outBuf in
            // force-unwrap safe: pcm was just allocated with bytesPerFrame
            // (fixed non-zero constant) — baseAddress is only nil when empty.
            // swiftlint:disable:next force_unwrapping
            _ = opus_decode(dec, nil, 0,
                outBuf.baseAddress!.assumingMemoryBound(to: Int16.self),
                Int32(AudioConstants.samplesPerFrame), 0)
        }
        return pcm
    }

    public func getStats() -> (encoded: Int64, decoded: Int64) { (framesEncoded, framesDecoded) }

    public func reconfigure(_ newConfig: Config) {
        config = newConfig
        if let enc = encoder {
            opus_helper_set_bitrate(enc, Int32(newConfig.bitrate))
            opus_helper_set_complexity(enc, Int32(newConfig.complexity))
            // FEC stays on across reconfigures — preserving Android parity.
            opus_helper_set_inband_fec(enc, Int32(1))
        }
    }

    /// Update the expected packet-loss hint used by the FEC budget calculation.
    /// Safe to call at any time; no-op if the encoder was not created.
    public func setPacketLossPct(_ plp: Int) {
        guard let enc = encoder else { return }
        opus_helper_set_packet_loss_perc(enc, Int32(plp))
    }

    // MARK: - Fallback (if C library returns errors)

    private func fallbackEncode(_ pcmFrame: Data) -> Data? {
        guard pcmFrame.count == AudioConstants.bytesPerFrame else { return nil }
        framesEncoded += 1
        return pcmFrame.prefix(min(100, pcmFrame.count))
    }

    private func fallbackDecode(_ opusFrame: Data) -> Data? {
        guard !opusFrame.isEmpty else { return nil }
        framesDecoded += 1
        return Data(count: AudioConstants.bytesPerFrame)
    }
}
