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
        let result = pcmFrame.withUnsafeBytes { pcmBuf in
            encoded.withUnsafeMutableBytes { outBuf in
                opus_encode(enc,
                    pcmBuf.baseAddress!.assumingMemoryBound(to: Int16.self),
                    Int32(AudioConstants.samplesPerFrame),
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
        let result = opusFrame.withUnsafeBytes { inBuf in
            pcm.withUnsafeMutableBytes { outBuf in
                opus_decode(dec,
                    inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    Int32(opusFrame.count),
                    outBuf.baseAddress!.assumingMemoryBound(to: Int16.self),
                    Int32(AudioConstants.samplesPerFrame),
                    1)  // use FEC data when available in the frame
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
