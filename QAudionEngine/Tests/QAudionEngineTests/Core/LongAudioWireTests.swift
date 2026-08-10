import XCTest
@testable import QAudionEngine

/// W-LONGAUDIO (2026-08-10) — the wire properties the profile must not break.
///
/// The single security property this design can prove is that an observer
/// learns nothing from packet sizes or timing: every packet is the same size,
/// at the same rate, regardless of what was said. Everything here exists to
/// make a regression in that property fail a test rather than ship.
final class LongAudioWireTests: XCTestCase {

    private let secret = Data(repeating: 0x5A, count: 32)

    private func engine(adaptive: Bool = true) throws -> QAudionEngine {
        let e = QAudionEngine(config: .development())
        try e.initialize()
        try e.initSession(sharedSecret: secret, adaptivePadding: adaptive)
        return e
    }

    private func pcm(ms: Int, amplitude: Int16 = 4000) -> Data {
        let samples = AudioConstants.sampleRate / 1000 * ms
        var d = Data(count: samples * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { p[i] = (i % 2 == 0) ? amplitude : -amplitude }
        }
        return d
    }

    // MARK: - I1: default OFF

    /// A build that has not negotiated anything seals into a 120-byte block and
    /// stays there. This is the invariant the whole feature is allowed to exist
    /// under, so it is asserted directly rather than inferred.
    func test_anUnlatchedCall_usesTheStandardBlock() throws {
        let e = try engine()
        XCTAssertEqual(e.activeAudioProfile, .standard)
        XCTAssertEqual(e.activeAudioProfile.blockBytes, 120)
    }

    /// The size of every outgoing frame is identical, whatever the audio.
    ///
    /// The frames are deliberately as different as PCM can be — silence, a loud
    /// alternating signal, and pseudo-random noise — because a size that depends
    /// on the content is exactly the channel the constant block closes, and it
    /// shows up only when the content varies.
    func test_frameSizeIsConstantAcrossWildlyDifferentAudio() throws {
        let e = try engine()
        var sizes = Set<Int>()
        let silence = Data(count: AudioConstants.bytesPerFrame)
        let loud = pcm(ms: 20, amplitude: 30000)
        var noise = Data(count: AudioConstants.bytesPerFrame)
        for i in 0..<noise.count { noise[i] = UInt8.random(in: .min ... .max) }
        for frame in [silence, loud, noise, silence, loud] {
            sizes.insert(try e.processOutgoingAudio(pcmFrame: frame).count)
        }
        XCTAssertEqual(sizes.count, 1, "packet size varied with content: \(sizes.sorted())")
        XCTAssertEqual(e.getStats().padOverflowFrames, 0,
                       "the shipped operating point must never overflow the block")
    }

    /// And no packet is ever OMITTED. Presence must not depend on content
    /// either — a dropped silent frame is the same leak as a smaller one.
    func test_everyFrameProducesExactlyOnePacket() throws {
        let e = try engine()
        for _ in 0..<10 {
            let out = try e.processOutgoingAudio(pcmFrame: Data(count: AudioConstants.bytesPerFrame))
            XCTAssertFalse(out.isEmpty)
        }
        XCTAssertEqual(e.getStats().framesTx, 10)
    }

    // MARK: - The latch

    /// Latching the long profile changes the block, and the packet grows by
    /// exactly the block difference — nothing else on the wire moves.
    func test_latchingTheLongProfileChangesOnlyTheBlock() throws {
        let std = try engine()
        let long = try engine()
        XCTAssertTrue(long.latchAudioProfile(.long60x256))
        XCTAssertEqual(long.activeAudioProfile, .long60x256)

        let stdPacket = try std.processOutgoingAudio(pcmFrame: pcm(ms: 20))
        let longPacket = try long.processOutgoingAudio(pcmFrame: pcm(ms: 60))
        XCTAssertEqual(longPacket.count - stdPacket.count,
                       AudioProfile.long60x256.blockBytes - AudioProfile.standard.blockBytes,
                       "the packet must grow by the block delta and by nothing else")
        XCTAssertEqual(long.getStats().padOverflowFrames, 0,
                       "32 kbps at 60 ms is an exact fit; any overflow is a clamp bug")
    }

    /// The latch is TERMINAL. A second call is refused, not applied.
    ///
    /// Mid-call switching is the one thing that would make the block depend on
    /// something other than the profile, so it is prevented structurally rather
    /// than by nobody calling it twice.
    func test_theLatchIsTerminal() throws {
        let e = try engine()
        XCTAssertTrue(e.latchAudioProfile(.long60x256))
        XCTAssertFalse(e.latchAudioProfile(.standard), "a second latch must be refused")
        XCTAssertEqual(e.activeAudioProfile, .long60x256)
        XCTAssertFalse(e.latchAudioProfile(.long60x256), "even to the same value")
    }

    /// Latching STANDARD explicitly is still a latch: it consumes the one
    /// opportunity, so a later resolution cannot upgrade the call mid-flight.
    func test_latchingStandardAlsoCloses() throws {
        let e = try engine()
        XCTAssertTrue(e.latchAudioProfile(.standard))
        XCTAssertFalse(e.latchAudioProfile(.long60x256))
        XCTAssertEqual(e.activeAudioProfile, .standard)
    }

    /// A freshly initialised engine is unlatched at STANDARD, and `initialize()`
    /// is what resets both — so no profile can leak from one call into the next.
    ///
    /// The reset lives in `initialize()` rather than in `destroySession()`
    /// deliberately: `initialize()` is the start of a call's life, and a latch
    /// cleared at teardown would leave a window where a late-firing handshake
    /// callback could re-latch an engine that is no longer on a call.
    func test_aFreshEngineIsUnlatchedAtStandard() throws {
        let fresh = QAudionEngine(config: .development())
        try fresh.initialize()
        XCTAssertEqual(fresh.activeAudioProfile, .standard)
        XCTAssertTrue(fresh.latchAudioProfile(.long60x256), "the latch is available on a fresh engine")
        XCTAssertEqual(fresh.activeAudioProfile, .long60x256)
    }

    /// Latching before a session exists is allowed (the engine is `.initialized`),
    /// because the handshake and the capability negotiation do not complete in a
    /// guaranteed order.
    func test_latchingBeforeTheSessionIsAllowed() throws {
        let e = QAudionEngine(config: .development())
        try e.initialize()
        XCTAssertTrue(e.latchAudioProfile(.long60x256))
        try e.initSession(sharedSecret: secret, adaptivePadding: true)
        XCTAssertEqual(e.activeAudioProfile, .long60x256, "initSession must not clear the latch")
    }

    // MARK: - Round trip

    /// A 256-byte block round-trips between two engines, and the payload comes
    /// back at full 60 ms length.
    func test_longProfileRoundTrip() throws {
        let tx = try engine()
        let rx = try engine()
        XCTAssertTrue(tx.latchAudioProfile(.long60x256))
        // The RECEIVER is deliberately left unlatched: receive is unconditional
        // and holds no negotiation state, so a standard-profile endpoint must
        // decode a long-profile frame with no configuration at all.
        let sealed = try tx.processOutgoingAudio(pcmFrame: pcm(ms: 60))
        let out = try rx.processIncomingAudio(serializedFrame: sealed)
        XCTAssertEqual(out.count, 5760, "expected a full 60 ms of PCM, got \(out.count) B")
    }

    /// ...and a standard frame still round-trips on the same pair of builds.
    func test_standardRoundTripStillWorks() throws {
        let tx = try engine()
        let rx = try engine()
        let sealed = try tx.processOutgoingAudio(pcmFrame: pcm(ms: 20))
        XCTAssertEqual(try rx.processIncomingAudio(serializedFrame: sealed).count, 1920)
    }

    // MARK: - The silent-frame convention

    /// An oversized body degrades to a constant-size SILENT packet — never to a
    /// bigger packet, and never to a dropped one.
    ///
    /// Driven through the real seal by asking a LONG-latched engine to encode
    /// a frame it cannot: the codec rejects the wrong-size PCM, the processor
    /// returns nil, and the `?? pcmFrame` fallback hands the raw 1920-byte
    /// buffer to the pad logic — which is far past the budget. The packet must
    /// still be exactly one block, with the overflow counted.
    func test_anOversizedBodyBecomesAConstantSizeSilentPacket() throws {
        let e = try engine()
        XCTAssertTrue(e.latchAudioProfile(.long60x256))
        let good = try e.processOutgoingAudio(pcmFrame: pcm(ms: 60))
        // A 20 ms buffer is the wrong size for a 60 ms encoder.
        let bad = try e.processOutgoingAudio(pcmFrame: pcm(ms: 20))
        XCTAssertEqual(bad.count, good.count, "an overflow must not change the packet size")
        XCTAssertEqual(e.getStats().padOverflowFrames, 1, "and it must be counted, not silent")
    }

    /// The receiver treats that packet as a lost frame and conceals it, rather
    /// than passing an empty buffer up to the playout path as if it were PCM.
    func test_aSilentPacketIsConcealedByTheReceiver() throws {
        let tx = try engine()
        let rx = try engine()
        XCTAssertTrue(tx.latchAudioProfile(.long60x256))
        let sealed = try tx.processOutgoingAudio(pcmFrame: pcm(ms: 20))  // overflows
        XCTAssertEqual(tx.getStats().padOverflowFrames, 1)
        let out = try rx.processIncomingAudio(serializedFrame: sealed)
        XCTAssertFalse(out.isEmpty, "a zero-length body must produce concealment, not an empty buffer")
        XCTAssertEqual(rx.getStats().framesRx, 1)
    }

    // MARK: - §2.4, at the engine boundary

    /// The mid-call bitrate path clamps against the LATCHED profile.
    ///
    /// Both halves were wrong before: the clamp used the standard defaults (so
    /// 40 kbps sailed through a 41 kbps ceiling and then overflowed a 240-byte
    /// budget with 300 bytes), and the rebuilt codec config used the default
    /// 20 ms (so a retune silently reset a latched 60 ms encoder — a mid-call
    /// profile switch arriving through the auto-tuner).
    func test_midCallRetuneRespectsTheLatchedProfile() throws {
        let e = try engine()
        XCTAssertTrue(e.latchAudioProfile(.long60x256))
        // The highest value the settings slider offers.
        e.reconfigureAudioCodec(bitrateKbps: 44, plp: 10)
        for _ in 0..<20 {
            _ = try e.processOutgoingAudio(pcmFrame: pcm(ms: 60))
        }
        XCTAssertEqual(e.getStats().padOverflowFrames, 0,
                       "a 44 kbps preference must be clamped to 32, not overflow every frame")
    }

    /// The same call on a standard-profile engine is unaffected: 44 clamps to
    /// 41, which fits the 118-byte budget, exactly as it did before.
    func test_midCallRetuneOnStandardIsUnchanged() throws {
        let e = try engine()
        e.reconfigureAudioCodec(bitrateKbps: 44, plp: 10)
        for _ in 0..<20 {
            _ = try e.processOutgoingAudio(pcmFrame: pcm(ms: 20))
        }
        XCTAssertEqual(e.getStats().padOverflowFrames, 0)
    }
}
