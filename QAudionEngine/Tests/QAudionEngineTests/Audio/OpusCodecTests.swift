import XCTest
@testable import QAudionEngine

final class OpusCodecTests: XCTestCase {
    func testEncodeReturnsData() {
        let codec = OpusCodec()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let encoded = codec.encode(pcm)
        XCTAssertNotNil(encoded)
        // Safe: pcm is fixed-size (bytesPerFrame), so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        XCTAssertFalse(encoded!.isEmpty)
    }

    func testEncodeWrongSizeReturnsNil() {
        let codec = OpusCodec()
        XCTAssertNil(codec.encode(Data(repeating: 0, count: 100)))
    }

    func testDecodeReturnsData() {
        let codec = OpusCodec()
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
        let codec = OpusCodec()
        let plc = codec.decodePLC()
        XCTAssertEqual(plc.count, AudioConstants.bytesPerFrame)
    }

    func testStats() {
        let codec = OpusCodec()
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
        let codec = OpusCodec()
        codec.reconfigure(.highQuality())
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
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
        let codec = OpusCodec()
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
        let codec = OpusCodec()
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
        let codec = OpusCodec()
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

        // Step 2: decode B itself normally — must land as silence, not a
        // repeat of the just-recovered loud frame.
        guard let decodedB = codec.decode(packetB) else { return XCTFail("decode B") }
        XCTAssertLessThan(rms(decodedB), inputRms * 0.2,
                          "frame B decoded loud (\(rms(decodedB))) — it should be silence")
    }

    /// The failure path: no successor packet at all (nil-equivalent — an
    /// empty frame) must degrade to silence of the requested duration and
    /// count as a FAILED recovery, never a crash or a bogus non-silent
    /// result.
    func testDecodeFECOnEmptyFrameReturnsSilenceAndCountsAsFailed() {
        let codec = OpusCodec()
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
        let codec = OpusCodec()
        let result = codec.decodeFEC(Data(), lostMs: 60)
        XCTAssertEqual(result.count, 5760)
    }

    // MARK: - TEMPORARY DIAGNOSTIC (debug/opus-fec-instrumentation, remove before merge)
    //
    // Source reading of the vendored silk/decode_frame.c + silk/decode_core.c
    // shows the state-mutation tail of silk_decode_frame (outBuf write,
    // silk_PLC(...,lost:0), lossCnt=0, prevSignalType, first_frame_after_reset,
    // lagPrev) and decode_core's sLPC_Q14_buf save/restore run IDENTICALLY
    // whether lostFlag is FLAG_DECODE_NORMAL or FLAG_DECODE_LBRR (as long as
    // the LBRR flag is set) — nothing in decode_frame.c or decode_core.c
    // distinguishes "this was a genuine primary-payload decode" from "this
    // was an LBRR/FEC recovery" once it decides to actually run silk_decode_core.
    // That means decodeFEC(B) leaves the LPC synthesis filter's persistent
    // memory (sLPC_Q14_buf), prev_gain_Q16, outBuf and lagPrev set from the
    // recovered LOUD content, and the immediately-following decode(B) inherits
    // that filter memory as its initial state even though B's own bits are
    // genuinely silent.
    //
    // Open question static reading can't answer: is this ORDINARY LPC/LTP
    // filter-memory continuity (the same mechanism the PASSING sibling test
    // `testASilentFrameDecodesQuiet` explicitly grants 4 frames of decay
    // margin for, checking only the LAST one) that just needs a decay grace
    // period the failing test never gives it — or genuine unbounded state
    // corruption that never converges. This prints/fails with real numbers
    // from an actual simulator run to answer that with evidence, not guesswork.
    func testDIAGNOSTIC_FecStateContinuity() {
        let silence = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let loud = tone()

        // Scenario 1: exact repro of testDecodeFECRecoversAKnownSingleFrameLoss,
        // extended with 6 more normal-decoded silence frames to see the decay curve.
        let codec1 = OpusCodec()
        for _ in 0..<2 {
            guard let enc = codec1.encode(silence) else { return XCTFail("DIAG warmup1 encode failed") }
            _ = codec1.decode(enc)
        }
        guard let packetA = codec1.encode(loud) else { return XCTFail("DIAG encA failed") }
        guard let packetB = codec1.encode(silence) else { return XCTFail("DIAG encB failed") }
        _ = packetA
        var scenario1: [Double] = [rms(codec1.decodeFEC(packetB))]
        guard let decodedB = codec1.decode(packetB) else { return XCTFail("DIAG decB failed") }
        scenario1.append(rms(decodedB))
        for _ in 0..<6 {
            guard let enc = codec1.encode(silence), let dec = codec1.decode(enc) else {
                return XCTFail("DIAG scenario1 continuation failed")
            }
            scenario1.append(rms(dec))
        }

        // Scenario 2 (control): identical packet stream, but decodeFEC is
        // NEVER called — decode(packetB) runs directly. Isolates whether
        // decodeFEC's state write is what makes B loud, vs. something that
        // would happen anyway from the undecoded-loss transition alone.
        let codec2 = OpusCodec()
        for _ in 0..<2 {
            guard let enc = codec2.encode(silence) else { return XCTFail("DIAG warmup2 encode failed") }
            _ = codec2.decode(enc)
        }
        guard let packetA2 = codec2.encode(loud) else { return XCTFail("DIAG encA2 failed") }
        guard let packetB2 = codec2.encode(silence) else { return XCTFail("DIAG encB2 failed") }
        _ = packetA2
        guard let decodedB2 = codec2.decode(packetB2) else { return XCTFail("DIAG decB2 failed") }
        var scenario2: [Double] = [rms(decodedB2)]
        for _ in 0..<6 {
            guard let enc = codec2.encode(silence), let dec = codec2.decode(enc) else {
                return XCTFail("DIAG scenario2 continuation failed")
            }
            scenario2.append(rms(dec))
        }

        // Scenario 3: the PASSING sibling's own pattern (4x loud then silence
        // via plain NORMAL decode only, never touching FEC), but tracking
        // EVERY frame instead of only the 4th/last — the known-good decay curve.
        let codec3 = OpusCodec()
        for _ in 0..<4 {
            guard let enc = codec3.encode(loud) else { return XCTFail("DIAG warmup3 encode failed") }
            _ = codec3.decode(enc)
        }
        var scenario3: [Double] = []
        for _ in 0..<6 {
            guard let enc = codec3.encode(silence), let dec = codec3.decode(enc) else {
                return XCTFail("DIAG scenario3 continuation failed")
            }
            scenario3.append(rms(dec))
        }

        XCTFail("""
        DIAGNOSTIC-OPUS-FEC scenario1(decodeFEC-recovered, then decode(B), then 6x normal silence)=\(scenario1)
        DIAGNOSTIC-OPUS-FEC scenario2(NO decodeFEC call, decode(B) direct, then 6x normal silence)=\(scenario2)
        DIAGNOSTIC-OPUS-FEC scenario3(sibling pattern: 4x loud normal-decode then 6x silence, all frames)=\(scenario3)
        """)
    }
}
