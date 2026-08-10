import XCTest
@testable import QAudionEngine

/// W-LONGAUDIO (2026-08-10) — R0: the RECEIVE path.
///
/// Receive is unconditional and holds no negotiation state: from this release
/// onward every endpoint decodes whatever arrives, regardless of what it
/// latched, forever. That is what makes the rollout survivable — in particular
/// it is why the asymmetric-strip case (a relay removing the send tag in one
/// direction only) still carries audio in both directions.
///
/// So everything here is tested WITHOUT any negotiation: a receiver that has
/// never heard of the long profile must still handle it correctly.
final class LongAudioReceiveTests: XCTestCase {

    private func pcm(ms: Int, amplitude: Int16) -> Data {
        let samples = AudioConstants.sampleRate / 1000 * ms
        var d = Data(count: samples * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { p[i] = (i % 2 == 0) ? amplitude : -amplitude }
        }
        return d
    }

    // MARK: - The decoder

    /// A 60 ms frame decodes to 2880 samples, not to a truncated 960 and not to
    /// a zero-padded 2880.
    ///
    /// The failure mode this covers is total silence on an otherwise valid call:
    /// a decode buffer sized from the ENCODE constant makes every 60 ms packet
    /// fail `OPUS_BUFFER_TOO_SMALL`, once per frame, for the whole call, and the
    /// fallback returns a zero-filled buffer so nothing anywhere reports it.
    func test_aSixtyMsFrameDecodesToItsFullLength() throws {
        let enc = OpusCodec(config: OpusCodec.Config(profile: .long60x256))
        let dec = OpusCodec()  // a DEFAULT receiver: 20 ms encode, no negotiation
        guard let packet = enc.encode(pcm(ms: 60, amplitude: 6000)) else {
            return XCTFail("60 ms encode failed")
        }
        XCTAssertFalse(packet.isEmpty)
        guard let out = dec.decode(packet) else { return XCTFail("60 ms decode returned nil") }
        XCTAssertEqual(out.count, 5760, "expected 2880 samples (5760 B), got \(out.count) B")
        XCTAssertEqual(dec.observedInboundFrameMs, 60)
    }

    /// ...and the same build still decodes a 20 ms frame in the same session.
    /// Both must work on one decoder, because both will arrive on one call.
    func test_theSameDecoderHandlesBothDurations() throws {
        let enc20 = OpusCodec()
        let enc60 = OpusCodec(config: OpusCodec.Config(profile: .long60x256))
        let dec = OpusCodec()
        guard let p20 = enc20.encode(pcm(ms: 20, amplitude: 6000)),
              let p60 = enc60.encode(pcm(ms: 60, amplitude: 6000)) else {
            return XCTFail("encode failed")
        }
        XCTAssertEqual(dec.decode(p20)?.count, 1920)
        XCTAssertEqual(dec.decode(p60)?.count, 5760)
        XCTAssertEqual(dec.decode(p20)?.count, 1920, "a 20 ms frame after a 60 ms one")
    }

    // MARK: - Concealment length (the silent drift bug)

    /// A fresh decoder conceals 20 ms. This is the third-priority fallback and
    /// it must be today's value, so a decoder that has seen nothing behaves
    /// exactly as it always did.
    func test_freshDecoder_conceals20ms() {
        XCTAssertEqual(OpusCodec().decodePLC().count, AudioConstants.bytesPerFrame)
    }

    /// After decoding a 20 ms stream, concealment is 20 ms.
    func test_afterA20msStream_concealmentIs20ms() throws {
        let enc = OpusCodec()
        let dec = OpusCodec()
        for _ in 0..<4 {
            guard let p = enc.encode(pcm(ms: 20, amplitude: 4000)) else { return XCTFail("encode") }
            _ = dec.decode(p)
        }
        XCTAssertEqual(dec.decodePLC().count, 1920)
    }

    /// After decoding a 60 ms stream, concealment is 60 ms — derived from the
    /// DECODER'S OWN last-packet duration, never from a negotiated profile.
    ///
    /// Concealing 20 ms into a 60 ms stream loses 40 ms of playout on every
    /// concealed frame; concealing 60 ms into a 20 ms stream runs 40 ms AHEAD of
    /// the sender on every concealed frame. Both are silent: no counter moves,
    /// and the call simply drifts.
    func test_afterA60msStream_concealmentIs60ms() throws {
        let enc = OpusCodec(config: OpusCodec.Config(profile: .long60x256))
        let dec = OpusCodec()
        for _ in 0..<4 {
            guard let p = enc.encode(pcm(ms: 60, amplitude: 4000)) else { return XCTFail("encode") }
            _ = dec.decode(p)
        }
        XCTAssertEqual(dec.decodePLC().count, 5760,
                       "concealment must follow the observed stream, not the local encode constant")
    }

    /// The interleave regression detector: a stream that switches duration
    /// mid-capture must decode both and conceal at whatever it last saw.
    func test_concealmentFollowsTheStreamAcrossADurationChange() throws {
        let enc20 = OpusCodec()
        let enc60 = OpusCodec(config: OpusCodec.Config(profile: .long60x256))
        let dec = OpusCodec()

        guard let p20 = enc20.encode(pcm(ms: 20, amplitude: 4000)) else { return XCTFail("encode 20") }
        _ = dec.decode(p20)
        XCTAssertEqual(dec.decodePLC().count, 1920)

        guard let p60 = enc60.encode(pcm(ms: 60, amplitude: 4000)) else { return XCTFail("encode 60") }
        _ = dec.decode(p60)
        XCTAssertEqual(dec.decodePLC().count, 5760)

        _ = dec.decode(p20)
        XCTAssertEqual(dec.decodePLC().count, 1920, "and back again")
    }

    // MARK: - The playout jitter buffer

    /// Default geometry is byte-for-byte the numbers that shipped.
    func test_playoutWatermarks_areUnchangedAt20ms() {
        XCTAssertEqual(PlayoutJitterBuffer.capacityFrames, 30)
        XCTAssertEqual(PlayoutJitterBuffer.nominalWatermark, 4)
        XCTAssertEqual(PlayoutJitterBuffer.trimWatermark, 7)
        XCTAssertEqual(PlayoutJitterBuffer.highWatermark, 8)
        XCTAssertEqual(PlayoutJitterBuffer.emergencyWatermark, 15)
        XCTAssertEqual(PlayoutJitterBuffer.emergencyDrainTarget, 2)
        XCTAssertEqual(PlayoutJitterBuffer.emergencyMaxDropsPerPop, 3)
        XCTAssertEqual(PlayoutJitterBuffer.silenceScanLimit, 3)
        XCTAssertEqual(PlayoutJitterBuffer.highTierScanLimit, 8)
        XCTAssertEqual(PlayoutJitterBuffer.highTierDropBudget, 3)
    }

    /// A buffer told it is receiving 60 ms frames re-derives every watermark and
    /// keeps the tier ORDERING intact. Ordering is the property that matters: a
    /// tier whose entry threshold has collapsed into the one below it does not
    /// announce itself, it just stops being a tier.
    func test_playoutWatermarks_stayOrderedAt60ms() {
        let jb = PlayoutJitterBuffer()
        jb.setInboundFrameDurationMs(60)
        XCTAssertEqual(jb.inboundFrameDurationMs, 60)
        // Capacity still bounds 600 ms of audio, not 600 ms worth of 20 ms frames.
        XCTAssertEqual(AudioConstants.framesForMs(600, frameDurationMs: 60), 10)
        // Ordering, from the derived values.
        let nominal = AudioConstants.framesForMs(80, frameDurationMs: 60)
        let trim = AudioConstants.framesForMs(140, frameDurationMs: 60)
        let high = AudioConstants.framesForMs(160, frameDurationMs: 60)
        let emergency = AudioConstants.framesForMs(300, frameDurationMs: 60)
        let capacity = AudioConstants.framesForMs(600, frameDurationMs: 60)
        XCTAssertLessThan(nominal, trim)
        XCTAssertLessThan(trim, high)
        XCTAssertLessThan(high, emergency)
        XCTAssertLessThan(emergency, capacity)
    }

    /// The overrun bound follows the duration: a 60 ms buffer caps at 10 frames,
    /// which is the same 600 ms. Held as a frame count it would have been 1.8
    /// seconds of standing latency.
    func test_capacityBoundsDurationNotFrameCount() {
        let jb = PlayoutJitterBuffer()
        jb.setInboundFrameDurationMs(60)
        let f = Data(count: 5760)
        for _ in 0..<40 { jb.push(f) }
        XCTAssertEqual(jb.depth, 10, "600 ms at 60 ms/frame is 10 frames")
    }

    /// An out-of-range duration is ignored rather than acted on: a corrupt or
    /// partial frame must not be able to resize a buffer holding good audio.
    func test_absurdInboundDurationIsIgnored() {
        let jb = PlayoutJitterBuffer()
        jb.setInboundFrameDurationMs(0)
        XCTAssertEqual(jb.inboundFrameDurationMs, 20)
        jb.setInboundFrameDurationMs(5000)
        XCTAssertEqual(jb.inboundFrameDurationMs, 20)
        jb.setInboundFrameDurationMs(-20)
        XCTAssertEqual(jb.inboundFrameDurationMs, 20)
    }

    // MARK: - Silence classification (sub-block, not retuned)

    /// At 20 ms there is exactly one sub-block, so the decision is bit-identical
    /// to the whole-frame RMS test it replaces.
    func test_silenceClassification_isUnchangedAt20ms() {
        XCTAssertTrue(PlayoutJitterBuffer.isSilent(pcm(ms: 20, amplitude: 10)))
        XCTAssertFalse(PlayoutJitterBuffer.isSilent(pcm(ms: 20, amplitude: 8000)))
        XCTAssertTrue(PlayoutJitterBuffer.isSilent(Data()))
    }

    /// A 60 ms frame that is two thirds silence and one third SPEECH must not be
    /// droppable.
    ///
    /// This is the case whole-frame RMS gets wrong, and it gets it wrong quietly:
    /// a syllable at RMS 8000 in one of three sub-blocks averages to about 4619
    /// — still loud here — but the same construction at a conversational 700
    /// averages to 404, under the 500 threshold, and the tier deletes the
    /// syllable while reporting it as a silence drop. Both amplitudes are
    /// asserted so the test fails for the right reason.
    func test_aFrameContainingSpeechIsNeverSilent_evenWhenMostlyQuiet() {
        for amplitude in [Int16(8000), Int16(700)] {
            var frame = pcm(ms: 20, amplitude: 5)     // quiet
            frame.append(pcm(ms: 20, amplitude: amplitude))  // speech
            frame.append(pcm(ms: 20, amplitude: 5))   // quiet
            XCTAssertEqual(frame.count, 5760)
            XCTAssertFalse(PlayoutJitterBuffer.isSilent(frame),
                           "a 60 ms frame with a \(amplitude)-amplitude sub-block is not silence")
        }
    }

    /// The number itself is NOT retuned — it keeps its calibrated value and its
    /// 20 ms detection resolution.
    func test_silenceThresholdIsUnchanged() {
        XCTAssertEqual(PlayoutJitterBuffer.silenceRmsThreshold, 500)
        XCTAssertEqual(PlayoutJitterBuffer.silenceSubBlockMs, 20)
    }

    /// A genuinely silent 60 ms frame IS still droppable — the sub-block rule
    /// must not make the tier unable to fire at all.
    func test_aFullySilentLongFrameIsStillDroppable() {
        XCTAssertTrue(PlayoutJitterBuffer.isSilent(pcm(ms: 60, amplitude: 10)))
    }

    // MARK: - Comfort noise

    func test_comfortNoiseFollowsTheFrameDuration() {
        XCTAssertEqual(JitterBuffer(capacity: 4).generateComfortNoise().count, 1920)
        XCTAssertEqual(JitterBuffer(capacity: 4, frameDurationMs: 60).generateComfortNoise().count, 5760)
    }

    // MARK: - The silent-frame convention

    /// A zero-length body means "this packet carries no audio" — the sender's
    /// encoder overflowed or failed, and it sent a normal-size packet with
    /// nothing in it rather than a differently-sized one.
    ///
    /// The receiver must CONCEAL it, not hand an empty buffer up the stack as if
    /// it were PCM.
    func test_anEmptyOpusBodyIsConcealed_notPassedThroughEmpty() {
        let proc = QAudionAudioProcessor()
        let out = proc.processIncoming(opusFrame: Data())
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.count, AudioConstants.bytesPerFrame,
                       "an empty body must produce one frame of concealment")
    }
}
