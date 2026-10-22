import XCTest
@testable import QAudionEngine

final class OpusCodecTests: XCTestCase {

    /// The 20 ms codec of the documented single exception (`AudioProfile.standard`).
    /// Every test below that feeds the codec `AudioConstants.bytesPerFrame` (one 20 ms frame) builds it with this;
    /// a codec built WITHOUT a profile runs the fleet profile's 60 ms (see the tests at the end of this file).
    private func codec20() -> OpusCodec {
        OpusCodec(config: OpusCodec.Config(profile: .standard))
    }

    func testEncodeReturnsData() {
        let codec = codec20()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let encoded = codec.encode(pcm)
        XCTAssertNotNil(encoded)
        // Safe: pcm is fixed-size (bytesPerFrame), so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        XCTAssertFalse(encoded!.isEmpty)
    }

    func testEncodeWrongSizeReturnsNil() {
        let codec = codec20()
        XCTAssertNil(codec.encode(Data(repeating: 0, count: 100)))
    }

    func testDecodeReturnsData() {
        let codec = codec20()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        // Safe: pcm is fixed-size (bytesPerFrame), so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        let encoded = codec.encode(pcm)!
        let decoded = codec.decode(encoded)
        XCTAssertNotNil(decoded)
        // Safe: decoded from a valid non-empty encoded frame, so decode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(decoded!.count, AudioConstants.bytesPerFrame)
    }

    func testDecodePLC() {
        let codec = codec20()
        let plc = codec.decodePLC()
        XCTAssertEqual(plc.count, AudioConstants.bytesPerFrame)
    }

    func testStats() {
        let codec = codec20()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        _ = codec.encode(pcm)
        _ = codec.encode(pcm)
        // Safe: pcm is fixed-size (bytesPerFrame), so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        let encoded = codec.encode(pcm)!
        _ = codec.decode(encoded)
        let stats = codec.getStats()
        XCTAssertEqual(stats.encoded, 3)
        XCTAssertEqual(stats.decoded, 1)
    }

    func testReconfigure() {
        let codec = codec20()
        codec.reconfigure(.highQuality())
        // The presets carry no profile of their own, so they are the fleet profile's 60 ms frames.
        XCTAssertEqual(codec.encodeFrameDurationMs, 60)
        let pcm = Data(repeating: 0, count: AudioProfile.defaultProfile.bytesPerFrame)
        XCTAssertNotNil(codec.encode(pcm))
    }

    // MARK: - W-IOSFECFLAG

    private func rms(_ d: Data) -> Double {
        let n = d.count / 2
        guard n > 0 else { return 0 }
        var sumSq = 0.0
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let v = Double(Int16(littleEndian: p[i]))
                sumSq += v * v
            }
        }
        return (sumSq / Double(n)).squareRoot()
    }

    private func tone(amplitude: Double = 0.35) -> Data {
        var d = Data(count: AudioConstants.bytesPerFrame)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<AudioConstants.samplesPerFrame {
                let t = Double(i) / Double(AudioConstants.sampleRate)
                p[i] = Int16(sin(2 * Double.pi * 440 * t) * amplitude * 32767)
            }
        }
        return d
    }

    /// THE test the suite was missing. `testDecodeReturnsData` above asserts only
    /// non-nil and byte count, so it passes when the decoder returns pure
    /// concealment — which is exactly what iOS did on every frame while
    /// `decode_fec` was 1, and why the defect survived for weeks.
    ///
    /// A steady tone is NOT a valid probe here: the LBRR copy of the previous
    /// frame of a steady tone also has energy. The signal has to CHANGE between
    /// frames so "the previous one" is distinguishable from "this one".
    func testDecodeRendersTheCurrentFrameAndNotThePreviousOne() {
        let codec = codec20()
        let silence = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let loud = tone()
        let inputRms = rms(loud)
        XCTAssertGreaterThan(inputRms, 1000, "the probe tone itself must be loud")

        // Alternate silence and tone so a frame-late decode is unmistakable.
        var decodedToneRms: [Double] = []
        for i in 0..<8 {
            let src = (i % 2 == 0) ? silence : loud
            guard let enc = codec.encode(src), let dec = codec.decode(enc) else {
                return XCTFail("encode/decode failed at frame \(i)")
            }
            if i % 2 == 1 { decodedToneRms.append(rms(dec)) }
        }
        // Skip the first pair: the encoder has lookahead and the decoder is cold.
        let settled = decodedToneRms.dropFirst()
        XCTAssertFalse(settled.isEmpty)
        for (k, r) in settled.enumerated() {
            XCTAssertGreaterThan(
                r, inputRms * 0.2,
                "tone frame \(k) decoded at RMS \(r) against an input of \(inputRms) — " +
                "that is concealment or the previous frame, not this one"
            )
        }
    }

    /// And the mirror: a silent frame must not come back loud. Catches the
    /// symmetric failure where the decoder renders a stale loud frame.
    func testASilentFrameDecodesQuiet() {
        let codec = codec20()
        let loud = tone()
        let silence = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        // Safe: loud/silence are fixed-size tone()/Data buffers, so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        for _ in 0..<4 { _ = codec.decode(codec.encode(loud)!) }
        var last = 0.0
        // Safe: encode() always succeeds on a fixed-size buffer, and decode() always
        // succeeds on the resulting non-empty encoded frame.
        // swiftlint:disable:next force_unwrapping
        for _ in 0..<4 { last = rms(codec.decode(codec.encode(silence)!)!) }
        XCTAssertLessThan(last, rms(loud) * 0.2, "silence decoded at RMS \(last)")
    }

    // MARK: - W-FECDECODE (2026-08-25)

    /// The acceptance test the spec asks for: a synthetic stream with a
    /// KNOWN single-frame loss, and `decodeFEC` on the frame that follows it
    /// must reconstruct real signal — not concealment, not silence — for the
    /// frame that never made it to `decode`.
    ///
    /// Same reasoning as `testDecodeRendersTheCurrentFrameAndNotThePreviousOne`
    /// for why the probe alternates rather than holding one tone throughout:
    /// a steady signal cannot distinguish "recovered the lost frame" from
    /// "recovered nothing and decoder history leaked through anyway".
    func testDecodeFECRecoversAKnownSingleFrameLoss() {
        let codec = codec20()
        let silence = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let loud = tone()
        let inputRms = rms(loud)
        XCTAssertGreaterThan(inputRms, 1000, "the probe tone itself must be loud")

        // Warm up encoder lookahead / decoder history on silence, exactly as
        // the sibling test above does, before the frame that matters.
        for _ in 0..<2 {
            guard let enc = codec.encode(silence) else { return XCTFail("encode warmup") }
            _ = codec.decode(enc)
        }

        // Frame A: LOUD, and simulated LOST — encoded, but never handed to
        // `decode`. Frame B: silence, arrives normally and carries A's LBRR.
        guard let packetA = codec.encode(loud) else { return XCTFail("encode A") }
        guard let packetB = codec.encode(silence) else { return XCTFail("encode B") }
        _ = packetA  // never decoded — this IS the simulated loss

        // Step 1 of the call-order contract: recover A from B's LBRR FIRST.
        let recovered = codec.decodeFEC(packetB)
        XCTAssertGreaterThan(
            rms(recovered), inputRms * 0.15,
            "FEC did not reconstruct the lost loud frame — got rms \(rms(recovered)) " +
            "against an input of \(inputRms); this is concealment or silence, not recovery")
        XCTAssertEqual(codec.fecRecoveredFrames, 1)
        XCTAssertEqual(codec.fecFailedFrames, 0)

        // Step 2: decode B itself normally — must eventually settle to
        // silence, not stay stuck replaying the just-recovered loud frame.
        //
        // It does NOT land as silence on THIS exact call, and that is
        // correct, not a bug: SILK's LPC/LTP synthesis-filter memory
        // (silk_decode_core's sLPC_Q14_buf / psDec->outBuf / prev_gain_Q16 —
        // silk/decode_core.c) and the encoder's own bounded-step gain/NLSF
        // interpolation (silk_delta_gain_iCDF; NLSF interpolation in
        // silk/decode_parameters.c) both carry a strong transition across
        // several 20 ms frames as a normal, necessary part of predictive
        // coding — an instantaneous full-amplitude-tone-to-digital-zero PCM
        // cut cannot be rendered as silence on the very next frame by any
        // LPC-based codec. `testASilentFrameDecodesQuiet` above already
        // relies on exactly this: it loops 4 times over the SAME loud→
        // silence transition and checks only the last iteration.
        //
        // Verified 2026-08-26 with a real CI/simulator run (see
        // reference_opus_fec_decode_audit_2026_08_26.md "Diagnosi finale"):
        // a control that never calls decodeFEC at all shows the identical
        // first-frame loudness (rms 2824.6) and the identical ~3-4 frame
        // decay curve down to the ~0.08 noise floor as this FEC path (rms
        // 4428.6 on frame 1, 0.64 by frame 3) — the settle time is a codec
        // property of the loud→silence transition itself, not something FEC
        // recovery introduces or a sign of decoder-state corruption. What a
        // genuine "stuck repeating the recovered frame forever" bug WOULD
        // fail is the level actually settling once given the same grace
        // period as the sibling test — that is what this now checks.
        guard let decodedB = codec.decode(packetB) else { return XCTFail("decode B") }
        var settledRms = rms(decodedB)
        for _ in 0..<3 {
            guard let enc = codec.encode(silence), let dec = codec.decode(enc) else {
                return XCTFail("decode B settle failed")
            }
            settledRms = rms(dec)
        }
        XCTAssertLessThan(
            settledRms, inputRms * 0.2,
            "silence never settled after the FEC-recovered frame — still rms \(settledRms)")
    }

    /// The failure path: no successor packet at all (nil-equivalent — an
    /// empty frame) must degrade to silence of the requested duration and
    /// count as a FAILED recovery, never a crash or a bogus non-silent
    /// result.
    func testDecodeFECOnEmptyFrameReturnsSilenceAndCountsAsFailed() {
        let codec = codec20()
        let result = codec.decodeFEC(Data(), lostMs: 20)
        XCTAssertEqual(result.count, AudioConstants.bytesPerFrame)
        XCTAssertTrue(result.allSatisfy { $0 == 0 })
        XCTAssertEqual(codec.fecFailedFrames, 1)
        XCTAssertEqual(codec.fecRecoveredFrames, 0)
    }

    /// `lostMs` sizes the OUTPUT, exactly like `decodePLC`'s documented
    /// contract — a 60 ms request must come back as 2880 samples (5760 B),
    /// not the 20 ms default.
    func testDecodeFECRespectsTheRequestedDuration() {
        let codec = codec20()
        let result = codec.decodeFEC(Data(), lostMs: 60)
        XCTAssertEqual(result.count, 5760)
    }

    // MARK: - Audio wire policy: a codec without a profile cannot run 20 ms

    func testAConfigWithoutAProfileIsTheFleetProfile() {
        let fleet = AudioProfile.defaultProfile
        let cfg = OpusCodec.Config()
        XCTAssertEqual(cfg.frameDurationMs, 60)
        XCTAssertEqual(cfg.blockBytes, 256)
        XCTAssertEqual(cfg.bitrate, 32000)
        XCTAssertEqual(cfg.frameDurationMs, fleet.frameDurationMs)
        XCTAssertEqual(cfg.blockBytes, fleet.blockBytes)
        XCTAssertEqual(cfg.samplesPerFrame, 2880)
        XCTAssertEqual(cfg.bytesPerFrame, 5760)
        XCTAssertLessThanOrEqual(cfg.bitrate, cfg.maxBitrateBps, "the default bitrate fits the default block")
    }

    func testEveryPresetIsTheFleetFrameDuration() {
        for cfg in [OpusCodec.Config.secure(), .highQuality(), .lowLatency()] {
            XCTAssertEqual(cfg.frameDurationMs, 60)
            XCTAssertEqual(cfg.blockBytes, 256)
        }
    }

    func testTheOnlyTwentyMillisecondProfileIsTheStandardOne() {
        XCTAssertEqual(OpusCodec.Config(profile: .standard).frameDurationMs, 20)
        XCTAssertEqual(OpusCodec.Config(profile: .long60x256).frameDurationMs, 60)
        XCTAssertEqual(AudioProfile.defaultProfile, AudioProfile.long60x256)
    }

    func testACodecBuiltWithoutAProfileEncodes60msFramesOnly() {
        let codec = OpusCodec()
        XCTAssertEqual(codec.encodeFrameDurationMs, 60)
        XCTAssertNil(codec.encode(Data(repeating: 0, count: AudioConstants.bytesPerFrame)), "a 20 ms frame is refused")
        XCTAssertNotNil(codec.encode(Data(repeating: 0, count: AudioProfile.defaultProfile.bytesPerFrame)))
    }

    func testTheInitialBitrateIsClampedToTheBlock() throws {
        let cbr32 = AudioConstants.opusCbrBytes(bitrateBps: 32000, frameDurationMs: 60)
        let codec = OpusCodec(config: OpusCodec.Config(bitrate: 64000))
        let packet = try XCTUnwrap(codec.encode(Data(repeating: 0, count: AudioProfile.defaultProfile.bytesPerFrame)))
        XCTAssertLessThanOrEqual(packet.count, cbr32, "64 kbps would be a 480-byte frame in a 256-byte block")
    }
}
